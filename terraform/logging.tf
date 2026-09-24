################################################
#                 Логирование                  #
################################################
# Доказательная база аудита: если событие не записано, его не было.

################################################
#          aws_s3_bucket_policy.logs           #
################################################
# Одна политика на все источники: CloudTrail, балансировщик, flow logs
# и AWS Config.
resource "aws_s3_bucket_policy" "logs" {
  bucket = aws_s3_bucket.logs.id
  policy = data.aws_iam_policy_document.logs.json
}

data "aws_iam_policy_document" "logs" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.logs.arn,
      "${aws_s3_bucket.logs.arn}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid       = "CloudTrailAclCheck"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.logs.arn]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }

  statement {
    sid       = "CloudTrailWrite"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.logs.arn}/cloudtrail/AWSLogs/${local.account_id}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }

  # Балансировщик пишет логи от имени сервисной учётной записи, своей
  # в каждом регионе;
  statement {
    sid       = "LoadBalancerWrite"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.logs.arn}/alb/AWSLogs/${local.account_id}/*"]

    principals {
      type        = "AWS"
      identifiers = [data.aws_elb_service_account.main.arn]
    }
  }

  statement {
    sid       = "FlowLogsWrite"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.logs.arn}/flow-logs/AWSLogs/${local.account_id}/*"]

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }

  statement {
    sid       = "FlowLogsAclCheck"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.logs.arn]

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }

  statement {
    sid       = "S3AccessLogsWrite"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.logs.arn}/s3-access/*"]

    principals {
      type        = "Service"
      identifiers = ["logging.s3.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }

  statement {
    sid       = "ConfigAclCheck"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.logs.arn]

    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }

  statement {
    sid       = "ConfigWrite"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.logs.arn}/config/*"]

    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

################################################
#            aws_cloudtrail.main               #
################################################
# Журнал вызовов API аккаунта.

# Проверка подписи файлов позволяет
# доказать, что журнал не правили задним числом
resource "aws_cloudtrail" "main" {
  name           = "${local.name_prefix}-trail"
  s3_bucket_name = aws_s3_bucket.logs.id
  s3_key_prefix  = "cloudtrail"

  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true
  kms_key_id                    = aws_kms_key.main.arn

  # В S3 журнал ради длительного хранения и проверки подписи
  cloud_watch_logs_group_arn = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
  cloud_watch_logs_role_arn  = aws_iam_role.cloudtrail_cloudwatch.arn

  # События чтения и записи объектов в бакете с данными клиентов
  advanced_event_selector {
    name = "S3 data events for the files bucket"

    field_selector {
      field  = "eventCategory"
      equals = ["Data"]
    }

    field_selector {
      field  = "resources.type"
      equals = ["AWS::S3::Object"]
    }

    field_selector {
      field       = "resources.ARN"
      starts_with = ["${aws_s3_bucket.files.arn}/"]
    }
  }

  advanced_event_selector {
    name = "Management events"

    field_selector {
      field  = "eventCategory"
      equals = ["Management"]
    }
  }

  depends_on = [aws_s3_bucket_policy.logs]

  tags = { Name = "${local.name_prefix}-trail" }
}

################################################
#              aws_flow_log.vpc                #
################################################
# Метаданные соединений: кто с кем разговаривал, сколько данных, был ли
# трафик отброшен.
resource "aws_flow_log" "vpc" {
  vpc_id                   = aws_vpc.main.id
  traffic_type             = "ALL"
  log_destination_type     = "s3"
  log_destination          = "${aws_s3_bucket.logs.arn}/flow-logs"
  max_aggregation_interval = 60

  depends_on = [aws_s3_bucket_policy.logs]

  tags = { Name = "${local.name_prefix}-flow-logs" }
}

################################################
#      aws_cloudwatch_log_group.app            #
################################################
# По умолчанию CloudWatch Logs хранит записи
# вечно
################################################
#    aws_cloudwatch_log_group.cloudtrail       #
################################################
# Сюда CloudTrail кладёт копию событий. Срок хранения задаётся явно.
resource "aws_cloudwatch_log_group" "cloudtrail" {
  name              = "/${var.project}/${var.environment}/cloudtrail"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn

  tags = { Name = "${local.name_prefix}-cloudtrail-logs" }
}

################################################
#      aws_cloudwatch_log_group.app            #
################################################
resource "aws_cloudwatch_log_group" "app" {
  name              = "/${var.project}/${var.environment}/app"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn

  tags = { Name = "${local.name_prefix}-app-logs" }
}
