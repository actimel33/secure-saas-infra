################################################
#                   Базовые                    #
################################################

################################################
#               variable.project               #
################################################
variable "project" {
  description = "Префикс имени всех ресурсов"
  type        = string
  default     = "secure-saas"
}

################################################
#             variable.environment             #
################################################
variable "environment" {
  description = "Окружение: попадает в имена и теги"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment должен быть dev, staging или prod."
  }
}

################################################
#               variable.region                #
################################################
variable "region" {
  description = "Регион AWS"
  type        = string
  default     = "eu-central-1"
}

################################################
#                variable.owner                #
################################################
variable "owner" {
  description = "Владелец ресурсов, попадает в теги"
  type        = string
  default     = "andrew"
}

################################################
#                     Сеть                     #
################################################
# Три группы подсетей.

################################################
#              variable.vpc_cidr               #
################################################
variable "vpc_cidr" {
  description = "Диапазон адресов VPC"
  type        = string
  default     = "10.60.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr должен быть валидным CIDR, например 10.60.0.0/16."
  }
}

################################################
#         variable.public_subnet_cidrs         #
################################################
variable "public_subnet_cidrs" {
  description = "Публичные подсети: только балансировщик и NAT-шлюз"
  type        = list(string)
  default     = ["10.60.1.0/24", "10.60.2.0/24"]

  validation {
    condition     = length(var.public_subnet_cidrs) == 2
    error_message = "Нужно ровно две публичные подсети: балансировщик требует две зоны доступности."
  }
}

################################################
#          variable.app_subnet_cidrs           #
################################################
variable "app_subnet_cidrs" {
  description = "Приватные подсети зоны приложения"
  type        = list(string)
  default     = ["10.60.11.0/24", "10.60.12.0/24"]

  validation {
    condition     = length(var.app_subnet_cidrs) == 2
    error_message = "Нужно ровно две подсети приложения."
  }
}

################################################
#          variable.data_subnet_cidrs          #
################################################
variable "data_subnet_cidrs" {
  description = "Приватные подсети зоны данных, без маршрута в интернет"
  type        = list(string)
  default     = ["10.60.21.0/24", "10.60.22.0/24"]

  validation {
    condition     = length(var.data_subnet_cidrs) == 2
    error_message = "Нужно ровно две подсети данных: группа подсетей RDS требует двух зон."
  }
}

################################################
#      variable.enable_interface_endpoints     #
################################################
variable "enable_interface_endpoints" {
  description = <<-EOT
    Создавать интерфейсные VPC-эндпоинты для SSM, KMS и Secrets Manager.
    Зона приложения ходит к этим сервисам через NAT, поэтому по умолчанию
    выключено. Включается, если нужно убрать зависимость от NAT: каждый
    эндпоинт тарифицируется по часам.
  EOT
  type        = bool
  default     = false
}

################################################
#                  Приложение                  #
################################################

################################################
#           variable.instance_type             #
################################################
variable "instance_type" {
  description = "Тип инстансов приложения"
  type        = string
  default     = "t3.micro"
}

################################################
#         variable.app_instance_count          #
################################################
variable "app_instance_count" {
  description = "Число инстансов приложения, по одному на зону доступности"
  type        = number
  default     = 2

  validation {
    condition     = var.app_instance_count >= 1 && var.app_instance_count <= 4
    error_message = "app_instance_count должен быть от 1 до 4."
  }
}

################################################
#           variable.app_port                  #
################################################
variable "app_port" {
  description = <<-EOT
    Порт, на котором приложение принимает TLS-соединения от балансировщика.
  EOT
  type        = number
  default     = 8443
}

################################################
#          variable.certificate_arn            #
################################################
variable "certificate_arn" {
  description = <<-EOT
    ARN сертификата ACM для слушателя HTTPS. Пустая строка означает, что
    домена у проекта нет: тогда создаётся только слушатель HTTP, и это
    зафиксировано в документации как незакрытый пробел.
  EOT
  type        = string
  default     = ""
}

################################################
#                     База                     #
################################################
# Мастер-пароль создаёт и хранит сам RDS
# в Secrets Manager, с возможностью ротации.

################################################
#          variable.db_engine_version          #
################################################
variable "db_engine_version" {
  description = "Версия PostgreSQL"
  type        = string
  default     = "18.3"
}

################################################
#         variable.db_instance_class           #
################################################
variable "db_instance_class" {
  description = "Класс инстанса базы"
  type        = string
  default     = "db.t4g.micro"
}

################################################
#        variable.db_allocated_storage         #
################################################
variable "db_allocated_storage" {
  description = "Размер диска базы в гигабайтах"
  type        = number
  default     = 20
}

################################################
#      variable.db_backup_retention_days       #
################################################
variable "db_backup_retention_days" {
  description = "Сколько дней хранятся автоматические резервные копии"
  type        = number
  default     = 7

  validation {
    condition     = var.db_backup_retention_days >= 1
    error_message = "Ноль отключает автоматические копии — недопустимо для данных клиентов."
  }
}

################################################
#            variable.db_multi_az              #
################################################
variable "db_multi_az" {
  description = "Синхронная реплика во второй зоне доступности. Удваивает стоимость базы"
  type        = bool
  default     = false
}

################################################
#        variable.db_deletion_protection       #
################################################
variable "db_deletion_protection" {
  description = "Защита базы от удаления. Для учебного стенда выключена, чтобы работал destroy"
  type        = bool
  default     = false
}

################################################
#            Наблюдение и защита               #
################################################
# Эти сервисы тарифицируются постоянно. В production работают всегда.

################################################
#            variable.enable_waf               #
################################################
variable "enable_waf" {
  description = "Создавать WAF перед балансировщиком"
  type        = bool
  default     = false
}

################################################
#          variable.enable_guardduty           #
################################################
variable "enable_guardduty" {
  description = "Включать GuardDuty в аккаунте"
  type        = bool
  default     = false
}

################################################
#           variable.enable_config             #
################################################
variable "enable_config" {
  description = "Включать AWS Config с набором правил"
  type        = bool
  default     = false
}

################################################
#           variable.alerts_email              #
################################################
variable "alerts_email" {
  description = <<-EOT
    Адрес для оповещений о событиях безопасности. Пустая строка означает,
    что тема SNS создаётся без подписки. Значение задаётся в локальном
    terraform.tfvars, который не коммитится.
  EOT
  type        = string
  default     = ""
}

################################################
#         variable.log_retention_days          #
################################################
variable "log_retention_days" {
  description = "Срок хранения логов в CloudWatch и версий логов в S3"
  type        = number
  default     = 90
}
