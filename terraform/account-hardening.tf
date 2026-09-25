################################################
#        Настройки уровня аккаунта             #
################################################
# Находки Security Hub указывают не только на ресурсы, но и на сам аккаунт:
# парольную политику, блокировку публичного доступа, шифрование по умолчанию.
# В коде их держать важнее, чем в консоли: настройка, сделанная кликом,
# не переживает смену владельца аккаунта и нигде не объяснена.

################################################
#   aws_s3_account_public_access_block.main    #
################################################
# Контроль S3.1. Блокировка на уровне аккаунта сильнее, чем на бакете:
# она действует и на бакеты, которые создадут позже и забудут настроить.
resource "aws_s3_account_public_access_block" "main" {
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

################################################
#    aws_ebs_encryption_by_default.main        #
################################################
# Контроль EC2.7. Диски шифруются явно, но настройка закрывает
# случай, когда том создадут мимо этого кода.
resource "aws_ebs_encryption_by_default" "main" {
  enabled = true
}

################################################
#   aws_iam_account_password_policy.main       #
################################################
# Контроли IAM.7, IAM.15, IAM.16. В аккаунте работают роли, а не люди
# с паролями, но требования CIS проверяют саму политику: пустая политика —
# это разрешение завести пользователя с паролем "1234".
resource "aws_iam_account_password_policy" "main" {
  minimum_password_length        = 14
  require_uppercase_characters   = true
  require_lowercase_characters   = true
  require_numbers                = true
  require_symbols                = true
  password_reuse_prevention      = 24
  max_password_age               = 90
  allow_users_to_change_password = true
}

################################################
#      aws_ssm_service_setting.doc_sharing     #
################################################
# Контроль SSM.7, уровень CRITICAL. По умолчанию документ Systems Manager
# можно опубликовать на весь мир — а документы содержат команды, которые
# выполняются на машинах, и имена ресурсов.
resource "aws_ssm_service_setting" "doc_sharing" {
  setting_id    = "arn:${local.partition}:ssm:${var.region}:${local.account_id}:servicesetting/ssm/documents/console/public-sharing-permission"
  setting_value = "Disable"
}

################################################
#      aws_accessanalyzer_analyzer.main        #
################################################
# Контроль IAM.28. Анализатор ищет политики, дающие доступ за пределы
# аккаунта: публичный бакет, роль с доверием чужому аккаунту, ключ KMS,
# доступный снаружи.
resource "aws_accessanalyzer_analyzer" "main" {
  analyzer_name = "${local.name_prefix}-external-access"
  type          = "ACCOUNT"

  tags = { Name = "${local.name_prefix}-access-analyzer" }
}

################################################
#     aws_account_alternate_contact.security   #
################################################
# Контроль Account.1. Адрес, по которому AWS сообщает о проблемах
# безопасности. Значения задаются в локальном terraform.tfvars: в публичном
# репозитории почте и телефону не место.
resource "aws_account_alternate_contact" "security" {
  count = var.security_contact_email == "" ? 0 : 1

  alternate_contact_type = "SECURITY"
  name                   = var.security_contact_name
  title                  = "Security contact"
  email_address          = var.security_contact_email
  phone_number           = var.security_contact_phone
}
