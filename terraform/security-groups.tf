################################################
#               Security groups                #
################################################
#   интернет ──443──> ALB ──8443 (TLS)──> app ──5432──> data
#
# Правила ссылаются на другую группу, а не на диапазон адресов: новый
# инстанс попадает под правило автоматически.
#
# Правила заданы отдельными ресурсами.

################################################
#            aws_security_group.alb            #
################################################
resource "aws_security_group" "alb" {
  name_prefix = "${local.name_prefix}-alb-"
  description = "Public entry point: HTTPS from the internet"
  vpc_id      = aws_vpc.main.id

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "${local.name_prefix}-alb-sg" }
}

################################################
# aws_vpc_security_group_ingress_rule.alb_https #
################################################
resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from the internet"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

################################################
# aws_vpc_security_group_ingress_rule.alb_http  #
################################################
# Порт 80 открыт ради редиректа на HTTPS. Если сертификата нет,
# он остаётся единственным входом.
resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from the internet, redirected to HTTPS when a certificate is configured"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

################################################
#  aws_vpc_security_group_egress_rule.alb_app  #
################################################
resource "aws_vpc_security_group_egress_rule" "alb_app" {
  security_group_id            = aws_security_group.alb.id
  description                  = "HTTPS to the application tier: traffic is encrypted end to end"
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = var.app_port
  to_port                      = var.app_port
  ip_protocol                  = "tcp"
}

################################################
#            aws_security_group.app            #
################################################
resource "aws_security_group" "app" {
  name_prefix = "${local.name_prefix}-app-"
  description = "Application tier: traffic from the load balancer only"
  vpc_id      = aws_vpc.main.id

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "${local.name_prefix}-app-sg" }
}

################################################
# aws_vpc_security_group_ingress_rule.app_alb  #
################################################
resource "aws_vpc_security_group_ingress_rule" "app_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "HTTPS from the load balancer only"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = var.app_port
  to_port                      = var.app_port
  ip_protocol                  = "tcp"
}

################################################
# aws_vpc_security_group_egress_rule.app_https #
################################################
# Наружу только HTTPS: пакеты, обновления, вызовы API сервисов AWS.
# Порт 80 намеренно закрыт.
resource "aws_vpc_security_group_egress_rule" "app_https" {
  security_group_id = aws_security_group.app.id
  description       = "HTTPS to package repositories and AWS service endpoints"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

################################################
#  aws_vpc_security_group_egress_rule.app_db   #
################################################
resource "aws_vpc_security_group_egress_rule" "app_db" {
  security_group_id            = aws_security_group.app.id
  description                  = "PostgreSQL on the data tier"
  referenced_security_group_id = aws_security_group.db.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

################################################
#            aws_security_group.db             #
################################################
resource "aws_security_group" "db" {
  name_prefix = "${local.name_prefix}-db-"
  description = "Data tier: PostgreSQL from the application tier only"
  vpc_id      = aws_vpc.main.id

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "${local.name_prefix}-db-sg" }
}

################################################
#  aws_vpc_security_group_ingress_rule.db_app  #
################################################
# Единственное входящее правило зоны данных.
resource "aws_vpc_security_group_ingress_rule" "db_app" {
  security_group_id            = aws_security_group.db.id
  description                  = "PostgreSQL from the application tier only"
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

################################################
#      aws_security_group.vpc_endpoints        #
################################################
# Группа для интерфейсных эндпоинтов.
resource "aws_security_group" "vpc_endpoints" {
  name_prefix = "${local.name_prefix}-vpce-"
  description = "Interface VPC endpoints: HTTPS from the application tier"
  vpc_id      = aws_vpc.main.id

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = "${local.name_prefix}-vpce-sg" }
}

################################################
# aws_vpc_security_group_ingress_rule.vpce_app #
################################################
resource "aws_vpc_security_group_ingress_rule" "vpce_app" {
  security_group_id            = aws_security_group.vpc_endpoints.id
  description                  = "HTTPS from the application tier"
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = 443
  to_port                      = 443
  ip_protocol                  = "tcp"
}
