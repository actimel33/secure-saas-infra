################################################
#               Слой приложения                #
################################################
# Инстансы в приватных подсетях: публичных адресов нет, снаружи к ним
# можно попасть только через балансировщик.

################################################
#              aws_instance.app                #
################################################
resource "aws_instance" "app" {
  count = var.app_instance_count

  ami           = data.aws_ssm_parameter.al2023.value
  instance_type = var.instance_type

  # Инстансы раскладываются по зонам доступности по очереди.
  subnet_id              = local.app_subnet_ids[count.index % length(local.app_subnet_ids)]
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile   = aws_iam_instance_profile.app.name

  # Публичного адреса нет: выход наружу — только через NAT.
  associate_public_ip_address = false

  # IMDSv2 обязателен: без токена метаданные не отдаются, и уязвимость
  # вида SSRF не позволит прочитать учётные данные роли.
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
    # 1 означает, что ответ не покинет саму машину
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 20
    encrypted   = true
    kms_key_id  = aws_kms_key.main.arn
  }

  user_data                   = local.app_user_data
  user_data_replace_on_change = true

  # обновление образа должно быть осознанным действием.
  lifecycle {
    ignore_changes = [ami]
  }

  tags = {
    Name = "${local.name_prefix}-app-${count.index + 1}"
    Tier = "application"
  }
}

locals {
  # Заглушка вместо приложения: отвечает на проверку состояния
  # балансировщика и показывает, какой инстанс обслужил запрос.
  # Реквизиты базы приложение читает из Secrets Manager своей ролью,.
  app_user_data = <<-EOT
    #!/bin/bash
    set -euo pipefail
    dnf install -y nginx
    sed -i 's/listen       80;/listen       ${var.app_port};/' /etc/nginx/nginx.conf
    sed -i 's/listen       \[::\]:80;/listen       [::]:${var.app_port};/' /etc/nginx/nginx.conf
    echo "$(hostname -f)" > /usr/share/nginx/html/index.html
    systemctl enable --now nginx
  EOT
}

################################################
#    aws_lb_target_group_attachment.app        #
################################################
# Обе цели регистрируются в одной группе: инстансы взаимозаменяемы,
# любой из них обслуживает любой запрос.
resource "aws_lb_target_group_attachment" "app" {
  count = var.app_instance_count

  target_group_arn = aws_lb_target_group.app.arn
  target_id        = aws_instance.app[count.index].id
  port             = var.app_port
}
