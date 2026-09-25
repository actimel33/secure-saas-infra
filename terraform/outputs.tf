################################################
#                    Выходы                    #
################################################
# Значений секретов здесь нет — только идентификаторы. Выходы попадают в состояние.

################################################
#            output.alb_dns_name               #
################################################
output "alb_dns_name" {
  description = "Адрес приложения"
  value       = aws_lb.public.dns_name
}

################################################
#              output.app_url                  #
################################################
output "app_url" {
  description = "Ссылка на приложение: HTTPS, если задан сертификат, иначе HTTP"
  value       = var.certificate_arn == "" ? "http://${aws_lb.public.dns_name}" : "https://${aws_lb.public.dns_name}"
}

################################################
#           output.app_instance_ids            #
################################################
output "app_instance_ids" {
  description = "Инстансы приложения — цели для Session Manager"
  value       = aws_instance.app[*].id
}

################################################
#          output.session_manager_hint         #
################################################
# Команда входа инстансов.
output "session_manager_hint" {
  description = "Как зайти на первый инстанс приложения"
  value       = "aws ssm start-session --target ${try(aws_instance.app[0].id, "")}"
}

################################################
#             output.db_endpoint               #
################################################
output "db_endpoint" {
  description = "Адрес базы внутри VPC"
  value       = aws_db_instance.main.endpoint
}

################################################
#          output.db_secret_arn                #
################################################
# ARN, а не значение: пароль создаёт и хранит RDS в Secrets Manager.
output "db_secret_arn" {
  description = "Секрет с мастер-паролем базы"
  value       = aws_db_instance.main.master_user_secret[0].secret_arn
}

################################################
#            output.files_bucket               #
################################################
output "files_bucket" {
  description = "Бакет с файлами клиентов"
  value       = aws_s3_bucket.files.id
}

################################################
#             output.logs_bucket               #
################################################
output "logs_bucket" {
  description = "Бакет с журналами: CloudTrail, балансировщик, flow logs"
  value       = aws_s3_bucket.logs.id
}

################################################
#              output.kms_key_arn              #
################################################
output "kms_key_arn" {
  description = "Ключ шифрования данных"
  value       = aws_kms_key.main.arn
}

################################################
#        output.security_alerts_topic          #
################################################
output "security_alerts_topic" {
  description = "Тема SNS с оповещениями о событиях безопасности"
  value       = aws_sns_topic.security_alerts.arn
}

################################################
#        output.security_hub_console           #
################################################
# Ссылка на сводку соответствия: оценка и проваленные контроли.
output "security_hub_console" {
  description = "Где смотреть оценку соответствия"
  value = var.enable_security_hub ? (
    "https://${var.region}.console.aws.amazon.com/securityhub/home?region=${var.region}#/summary"
  ) : "Security Hub выключен: enable_security_hub = false"
}

################################################
#          output.enabled_guardrails           #
################################################
# Какие платные механизмы включены в этом развёртывании
output "enabled_guardrails" {
  description = "Состояние переключаемых механизмов защиты"
  value = {
    waf                 = var.enable_waf
    guardduty           = var.enable_guardduty
    config              = var.enable_config
    security_hub        = var.enable_security_hub
    interface_endpoints = var.enable_interface_endpoints
    https_listener      = var.certificate_arn != ""
    multi_az_database   = var.db_multi_az
  }
}
