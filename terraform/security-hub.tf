################################################
#        Непрерывная проверка соответствия     #
################################################
# Security Hub сверяет конфигурацию аккаунта с наборами контролей и
# выставляет оценку. Config при этом поставляет ему записи о ресурсах:
# без включённого Config часть контролей остаётся без данных.

################################################
#          aws_securityhub_account.main        #
################################################
# enable_default_standards = false: наборы подключаются явно ниже,
# иначе AWS включит свои и состояние разойдётся с кодом.
resource "aws_securityhub_account" "main" {
  count = var.enable_security_hub ? 1 : 0

  enable_default_standards  = false
  control_finding_generator = "SECURITY_CONTROL"
  auto_enable_controls      = true
}

################################################
#  aws_securityhub_standards_subscription.*    #
################################################
# AWS Foundational Security Best Practices — проверки самого AWS.
# CIS AWS Foundations Benchmark
resource "aws_securityhub_standards_subscription" "standards" {
  for_each = var.enable_security_hub ? var.security_standards : {}

  standards_arn = "arn:${local.partition}:securityhub:${var.region}::${each.value}"

  depends_on = [aws_securityhub_account.main]
}

################################################
#  aws_cloudwatch_event_rule.securityhub       #
################################################
# На CRITICAL или HIGH приходит письмо. Фильтр по состоянию отсекает шум
resource "aws_cloudwatch_event_rule" "securityhub" {
  count = var.enable_security_hub ? 1 : 0

  name        = "${local.name_prefix}-securityhub-findings"
  description = "New CRITICAL or HIGH findings from Security Hub"

  event_pattern = jsonencode({
    source        = ["aws.securityhub"]
    "detail-type" = ["Security Hub Findings - Imported"]
    detail = {
      findings = {
        Severity    = { Label = ["CRITICAL", "HIGH"] }
        RecordState = ["ACTIVE"]
        Workflow    = { Status = ["NEW"] }
      }
    }
  })

  tags = { Name = "${local.name_prefix}-securityhub-findings" }
}

resource "aws_cloudwatch_event_target" "securityhub" {
  count = var.enable_security_hub ? 1 : 0

  rule      = aws_cloudwatch_event_rule.securityhub[0].name
  target_id = "sns"
  arn       = aws_sns_topic.security_alerts.arn

  # Письмо с полным телом находки нечитаемо, поэтому в него
  # попадают только те поля, по которым принимается решение.
  input_transformer {
    input_paths = {
      severity    = "$.detail.findings[0].Severity.Label"
      title       = "$.detail.findings[0].Title"
      resource    = "$.detail.findings[0].Resources[0].Id"
      account     = "$.detail.findings[0].AwsAccountId"
      region      = "$.detail.findings[0].Region"
      description = "$.detail.findings[0].Description"
    }

    input_template = <<-EOT
      "Security Hub: <severity> finding"
      ""
      "Control:  <title>"
      "Resource: <resource>"
      "Account:  <account> (<region>)"
      ""
      "<description>"
    EOT
  }
}
