################################################
#           Обнаружение и соответствие         #
################################################
#  происходит ли прямо сейчас что-то плохое (GuardDuty)
# и соответствует ли конфигурация правилам (Config).

################################################
#          aws_guardduty_detector.main         #
################################################
# Анализирует CloudTrail, DNS-запросы и flow logs
resource "aws_guardduty_detector" "main" {
  count = var.enable_guardduty ? 1 : 0

  enable                       = true
  finding_publishing_frequency = "FIFTEEN_MINUTES"

  tags = { Name = "${local.name_prefix}-guardduty" }
}

################################################
#          aws_inspector2_enabler.main         #
################################################
# Контроли Inspector.1–4. Сервис сам находит уязвимости в пакетах на
# инстансах, в образах контейнеров и в коде функций

resource "aws_inspector2_enabler" "main" {
  count = var.enable_inspector ? 1 : 0

  account_ids    = [local.account_id]
  resource_types = ["EC2", "ECR", "LAMBDA", "LAMBDA_CODE"]
}

################################################
#    aws_config_configuration_recorder.main    #
################################################
# Ведёт историю конфигураций ресурсов и прогоняет по ним правила.
resource "aws_config_configuration_recorder" "main" {
  count = var.enable_config ? 1 : 0

  name     = "${local.name_prefix}-recorder"
  role_arn = aws_iam_role.config[0].arn

  # Записываются только типы, из которых состоит эта инфраструктура.
  recording_group {
    all_supported = false
    resource_types = [
      # сеть
      "AWS::EC2::VPC",
      "AWS::EC2::Subnet",
      "AWS::EC2::RouteTable",
      "AWS::EC2::NetworkAcl",
      "AWS::EC2::SecurityGroup",
      "AWS::EC2::InternetGateway",
      "AWS::EC2::NatGateway",
      "AWS::EC2::EIP",
      "AWS::EC2::VPCEndpoint",
      "AWS::EC2::NetworkInterface",
      # вычисления и диски
      "AWS::EC2::Instance",
      "AWS::EC2::Volume",
      "AWS::ElasticLoadBalancingV2::LoadBalancer",
      # данные
      "AWS::RDS::DBInstance",
      "AWS::RDS::DBSubnetGroup",
      "AWS::S3::Bucket",
      # доступ и ключи
      "AWS::IAM::Role",
      "AWS::IAM::Policy",
      "AWS::IAM::User",
      "AWS::IAM::Group",
      "AWS::KMS::Key",
      "AWS::SecretsManager::Secret",
      # журналы и оповещения
      "AWS::CloudTrail::Trail",
      "AWS::Logs::LogGroup",
      "AWS::SNS::Topic",
    ]
  }
}

resource "aws_config_delivery_channel" "main" {
  count = var.enable_config ? 1 : 0

  name           = "${local.name_prefix}-delivery"
  s3_bucket_name = aws_s3_bucket.logs.id
  s3_key_prefix  = "config"

  depends_on = [aws_config_configuration_recorder.main, aws_s3_bucket_policy.logs]
}

resource "aws_config_configuration_recorder_status" "main" {
  count = var.enable_config ? 1 : 0

  name       = aws_config_configuration_recorder.main[0].name
  is_enabled = true

  depends_on = [aws_config_delivery_channel.main]
}

################################################
#           aws_config_config_rule.*           #
################################################
# Правила: всё зашифровано,
# нет публичных бакетов, закрыты порты управления.
resource "aws_config_config_rule" "rules" {
  for_each = var.enable_config ? toset([
    "ENCRYPTED_VOLUMES",
    "RDS_STORAGE_ENCRYPTED",
    "RDS_INSTANCE_PUBLIC_ACCESS_CHECK",
    "S3_BUCKET_PUBLIC_READ_PROHIBITED",
    "S3_BUCKET_SERVER_SIDE_ENCRYPTION_ENABLED",
    "INCOMING_SSH_DISABLED",
    "CLOUD_TRAIL_ENABLED",
    "EC2_IMDSV2_CHECK",
  ]) : toset([])

  name = lower(replace(each.value, "_", "-"))

  source {
    owner             = "AWS"
    source_identifier = each.value
  }

  depends_on = [aws_config_configuration_recorder.main]
}

################################################
#         aws_sns_topic.security_alerts        #
################################################
# Логи без оповещений — архив, который никто не читает.
resource "aws_sns_topic" "security_alerts" {
  name              = "${local.name_prefix}-security-alerts"
  kms_master_key_id = aws_kms_key.main.id

  tags = { Name = "${local.name_prefix}-security-alerts" }
}

# Подписка создаётся, только если адрес задан в локальном tfvars
resource "aws_sns_topic_subscription" "email" {
  count = var.alerts_email == "" ? 0 : 1

  topic_arn = aws_sns_topic.security_alerts.arn
  protocol  = "email"
  endpoint  = var.alerts_email
}

resource "aws_sns_topic_policy" "security_alerts" {
  arn    = aws_sns_topic.security_alerts.arn
  policy = data.aws_iam_policy_document.sns.json
}

data "aws_iam_policy_document" "sns" {
  statement {
    sid       = "AllowEventBridgePublish"
    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.security_alerts.arn]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

################################################
#        aws_cloudwatch_event_rule.*           #
################################################
# События, которые нельзя заметить постфактум: вход под root, изменение
# сетевых правил, попытка выключить журнал аудита. Правила работают
# по событиям CloudTrai.
locals {
  security_events = {
    root-login = {
      description = "Console sign-in as the root user"
      pattern = {
        source        = ["aws.signin"]
        "detail-type" = ["AWS Console Sign In via CloudTrail"]
        detail = {
          userIdentity = { type = ["Root"] }
        }
      }
    }

    security-group-change = {
      description = "Security group rules modified"
      pattern = {
        source        = ["aws.ec2"]
        "detail-type" = ["AWS API Call via CloudTrail"]
        detail = {
          eventSource = ["ec2.amazonaws.com"]
          eventName = [
            "AuthorizeSecurityGroupIngress",
            "AuthorizeSecurityGroupEgress",
            "RevokeSecurityGroupIngress",
            "RevokeSecurityGroupEgress",
          ]
        }
      }
    }

    cloudtrail-tampering = {
      description = "Audit trail stopped, deleted or reconfigured"
      pattern = {
        source        = ["aws.cloudtrail"]
        "detail-type" = ["AWS API Call via CloudTrail"]
        detail = {
          eventSource = ["cloudtrail.amazonaws.com"]
          eventName   = ["StopLogging", "DeleteTrail", "UpdateTrail"]
        }
      }
    }

    iam-user-created = {
      description = "IAM user or access key created in a role-only account"
      pattern = {
        source        = ["aws.iam"]
        "detail-type" = ["AWS API Call via CloudTrail"]
        detail = {
          eventSource = ["iam.amazonaws.com"]
          eventName   = ["CreateUser", "CreateAccessKey"]
        }
      }
    }
  }
}

resource "aws_cloudwatch_event_rule" "security" {
  for_each = local.security_events

  name          = "${local.name_prefix}-${each.key}"
  description   = each.value.description
  event_pattern = jsonencode(each.value.pattern)

  tags = { Name = "${local.name_prefix}-${each.key}" }
}

resource "aws_cloudwatch_event_target" "security" {
  for_each = aws_cloudwatch_event_rule.security

  rule      = each.value.name
  target_id = "sns"
  arn       = aws_sns_topic.security_alerts.arn
}
