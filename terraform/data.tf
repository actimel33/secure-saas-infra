################################################
#       Зона данных: KMS, RDS, S3, секреты     #
################################################
# Данные клиентов, ради защиты которых построено всё остальное.

################################################
#           aws_kms_key.main + alias           #
################################################
# Собственный ключ вместо ключа AWS по умолчанию: политику пишем сами,
# ключ можно отключить как аварийный рубильник, а зашифрованный им
# ресурс можно передать в другой аккаунт.
resource "aws_kms_key" "main" {
  description             = "${local.name_prefix}: data at rest"
  enable_key_rotation     = true
  rotation_period_in_days = 365
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.kms.json

  tags = { Name = "${local.name_prefix}-kms" }
}

resource "aws_kms_alias" "main" {
  name          = "alias/${local.name_prefix}"
  target_key_id = aws_kms_key.main.key_id
}

################################################
#    data.aws_iam_policy_document.kms          #
################################################
# Политика ключа — второй рубеж рядом с IAM: роль с разрешением
# kms:Decrypt ничего не расшифрует, если её нет здесь.
data "aws_iam_policy_document" "kms" {
  # Без этого блока ключом нельзя управлять: администрирование ключа
  # делегируется политикам IAM аккаунта.
  statement {
    sid       = "AccountAdministration"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }

  # Сервисы шифруют данные от имени аккаунта: условие kms:ViaService
  # ограничивает использование ключа конкретными сервисами.
  statement {
    sid = "ServiceUsage"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:CreateGrant",
      "kms:DescribeKey",
    ]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values = [
        "s3.${var.region}.amazonaws.com",
        "rds.${var.region}.amazonaws.com",
        "secretsmanager.${var.region}.amazonaws.com",
        "ec2.${var.region}.amazonaws.com",
      ]
    }
  }

  # CloudTrail шифрует файлы журнала этим же ключом.
  statement {
    sid       = "CloudTrailEncryption"
    actions   = ["kms:GenerateDataKey*", "kms:DescribeKey"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "kms:EncryptionContext:aws:cloudtrail:arn"
      values   = ["arn:${local.partition}:cloudtrail:*:${local.account_id}:trail/*"]
    }
  }
}

################################################
#         aws_db_subnet_group.main             #
################################################
resource "aws_db_subnet_group" "main" {
  name_prefix = "${local.name_prefix}-db-"
  subnet_ids  = local.data_subnet_ids

  tags = { Name = "${local.name_prefix}-db-subnets" }
}

################################################
#            aws_db_instance.main              #
################################################
# Управляемый PostgreSQL
#
# Мастер-пароль создаёт и хранит сам RDS в Secrets Manager
# (manage_master_user_password), поэтому пароль не появляется ни
# в переменных, ни в состоянии Terraform.
resource "aws_db_instance" "main" {
  identifier_prefix = "${local.name_prefix}-"
  engine            = "postgres"
  engine_version    = var.db_engine_version
  instance_class    = var.db_instance_class

  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_allocated_storage * 2
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.main.arn

  db_name  = "app"
  username = "appadmin"

  manage_master_user_password   = true
  master_user_secret_kms_key_id = aws_kms_key.main.arn

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  multi_az               = var.db_multi_az

  backup_retention_period = var.db_backup_retention_days
  copy_tags_to_snapshot   = true
  deletion_protection     = var.db_deletion_protection

  # Обновления безопасности движка
  auto_minor_version_upgrade = true

  # Журналы базы уезжают в CloudWatch
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  # Учебный стенд поднимается и сносится многократно, поэтому финальный
  # снимок не делается. Для production здесь false и осмысленное имя снимка
  skip_final_snapshot = true

  tags = { Name = "${local.name_prefix}-postgres" }
}

################################################
#           random_id.bucket_suffix            #
################################################
# Имена бакетов глобально уникальны
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

################################################
#            aws_s3_bucket.files               #
################################################
# Файлы клиентов.
resource "aws_s3_bucket" "files" {
  bucket        = "${local.name_prefix}-files-${random_id.bucket_suffix.hex}"
  force_destroy = true

  tags = { Name = "${local.name_prefix}-files" }
}

resource "aws_s3_bucket_public_access_block" "files" {
  bucket = aws_s3_bucket.files.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "files" {
  bucket = aws_s3_bucket.files.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "files" {
  bucket = aws_s3_bucket.files.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.main.arn
    }
    # Ключ бакета сокращает число обращений к KMS
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "files" {
  bucket = aws_s3_bucket.files.id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.log_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Доступ к файлам только по TLS: запрос без шифрования отклоняется
# независимо от прав обращающегося.
resource "aws_s3_bucket_policy" "files" {
  bucket = aws_s3_bucket.files.id
  policy = data.aws_iam_policy_document.files.json
}

data "aws_iam_policy_document" "files" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.files.arn,
      "${aws_s3_bucket.files.arn}/*",
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
}

################################################
#             aws_s3_bucket.logs               #
################################################
# Сюда пишут CloudTrail, балансировщик и flow logs.
#
# Шифрование — ключом S3
resource "aws_s3_bucket" "logs" {
  bucket        = "${local.name_prefix}-logs-${random_id.bucket_suffix.hex}"
  force_destroy = true

  tags = { Name = "${local.name_prefix}-logs" }
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket = aws_s3_bucket.logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "logs" {
  bucket = aws_s3_bucket.logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    id     = "retention"
    status = "Enabled"

    filter {}

    expiration {
      days = var.log_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

# Логирование обращений к самому бакету с файлами
resource "aws_s3_bucket_logging" "files" {
  bucket = aws_s3_bucket.files.id

  target_bucket = aws_s3_bucket.logs.id
  target_prefix = "s3-access/"
}
