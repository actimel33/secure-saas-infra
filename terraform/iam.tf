################################################
#                     IAM                      #
################################################
# Роли вместо пользователей: временные учётные данные выдаются
# автоматически, и долгоживущему ключу неоткуда утечь.

################################################
#               aws_iam_role.app               #
################################################
resource "aws_iam_role" "app" {
  name_prefix = "${local.name_prefix}-app-"
  description = "Application instances: Session Manager, database secret, object storage"

  assume_role_policy = data.aws_iam_policy_document.app_assume.json

  tags = { Name = "${local.name_prefix}-app-role" }
}

data "aws_iam_policy_document" "app_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

################################################
#  aws_iam_role_policy_attachment.app_ssm      #
################################################
# Вход на машины без SSH: доступ по IAM, каждая сессия  в CloudTrail.
resource "aws_iam_role_policy_attachment" "app_ssm" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

################################################
#          aws_iam_role_policy.app             #
################################################
# Права на конкретные ресурсы, а не на "*": один секрет, один бакет,
# один ключ.
resource "aws_iam_role_policy" "app" {
  name   = "app-data-access"
  role   = aws_iam_role.app.id
  policy = data.aws_iam_policy_document.app.json
}

data "aws_iam_policy_document" "app" {
  statement {
    sid       = "ReadDatabaseSecret"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [aws_db_instance.main.master_user_secret[0].secret_arn]
  }

  statement {
    sid       = "ListFilesBucket"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.files.arn]
  }

  statement {
    sid       = "ReadWriteFiles"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.files.arn}/*"]
  }

  # Файлы и секрет зашифрованы собственным ключом, поэтому права
  # на него нужны явно — прав IAM на S3 и Secrets Manager недостаточно.
  statement {
    sid       = "UseEncryptionKey"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
    resources = [aws_kms_key.main.arn]
  }
}

################################################
#        aws_iam_instance_profile.app          #
################################################
resource "aws_iam_instance_profile" "app" {
  name_prefix = "${local.name_prefix}-app-"
  role        = aws_iam_role.app.name
}

################################################
#      aws_iam_role.cloudtrail_cloudwatch      #
################################################
# От имени этой роли CloudTrail пишет события в лог-группу.
resource "aws_iam_role" "cloudtrail_cloudwatch" {
  name_prefix        = "${local.name_prefix}-trail-"
  description        = "CloudTrail delivery to CloudWatch Logs"
  assume_role_policy = data.aws_iam_policy_document.cloudtrail_assume.json

  tags = { Name = "${local.name_prefix}-trail-role" }
}

data "aws_iam_policy_document" "cloudtrail_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    # Условие защищает от подстановки чужого журнала в нашу роль.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role_policy" "cloudtrail_cloudwatch" {
  name   = "cloudtrail-delivery"
  role   = aws_iam_role.cloudtrail_cloudwatch.id
  policy = data.aws_iam_policy_document.cloudtrail_cloudwatch.json
}

data "aws_iam_policy_document" "cloudtrail_cloudwatch" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.cloudtrail.arn}:log-stream:*"]
  }
}

################################################
#            aws_iam_role.config               #
################################################
# Роль, от имени которой AWS Config читает конфигурацию ресурсов
# и складывает снимки в бакет логов.
resource "aws_iam_role" "config" {
  count = var.enable_config ? 1 : 0

  name_prefix        = "${local.name_prefix}-config-"
  description        = "AWS Config recorder"
  assume_role_policy = data.aws_iam_policy_document.config_assume.json

  tags = { Name = "${local.name_prefix}-config-role" }
}

data "aws_iam_policy_document" "config_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role_policy_attachment" "config_managed" {
  count = var.enable_config ? 1 : 0

  role       = aws_iam_role.config[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AWS_ConfigRole"
}

resource "aws_iam_role_policy" "config_delivery" {
  count = var.enable_config ? 1 : 0

  name   = "config-delivery"
  role   = aws_iam_role.config[0].id
  policy = data.aws_iam_policy_document.config_delivery.json
}

data "aws_iam_policy_document" "config_delivery" {
  statement {
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.logs.arn}/config/*"]

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }

  statement {
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.logs.arn]
  }
}
