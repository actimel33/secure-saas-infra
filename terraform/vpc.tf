################################################
#              Сеть и зоны доверия             #
################################################
# Зоны доверия.

################################################
#                 aws_vpc.main                 #
################################################
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${local.name_prefix}-vpc" }
}

################################################
#          aws_internet_gateway.main           #
################################################
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${local.name_prefix}-igw" }
}

################################################
#              aws_subnet.public               #
################################################
# Публичная зона: только балансировщик и NAT-шлюз.
resource "aws_subnet" "public" {
  for_each = { for idx, cidr in var.public_subnet_cidrs : tostring(idx) => cidr }

  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value
  availability_zone       = local.azs[tonumber(each.key)]
  map_public_ip_on_launch = false

  tags = {
    Name = "${local.name_prefix}-public-${local.azs[tonumber(each.key)]}"
    Tier = "public"
  }
}

################################################
#                aws_subnet.app                #
################################################
# Зона приложения: публичных адресов нет, наружу — только через NAT.
resource "aws_subnet" "app" {
  for_each = { for idx, cidr in var.app_subnet_cidrs : tostring(idx) => cidr }

  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value
  availability_zone = local.azs[tonumber(each.key)]

  tags = {
    Name = "${local.name_prefix}-app-${local.azs[tonumber(each.key)]}"
    Tier = "application"
  }
}

################################################
#               aws_subnet.data                #
################################################
# Зона данных: маршрута в интернет нет вообще, см. таблицу ниже.
resource "aws_subnet" "data" {
  for_each = { for idx, cidr in var.data_subnet_cidrs : tostring(idx) => cidr }

  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value
  availability_zone = local.azs[tonumber(each.key)]

  tags = {
    Name = "${local.name_prefix}-data-${local.azs[tonumber(each.key)]}"
    Tier = "data"
  }
}

################################################
#                aws_eip.nat                   #
################################################
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = { Name = "${local.name_prefix}-nat-eip" }
}

################################################
#            aws_nat_gateway.main              #
################################################
# Один шлюз на всю VPC. Отказоустойчивый вариант — по шлюзу на зону
# доступности.
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = local.public_subnet_ids[0]
  depends_on    = [aws_internet_gateway.main]

  tags = { Name = "${local.name_prefix}-nat" }
}

################################################
#           aws_route_table.public             #
################################################
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${local.name_prefix}-public-rt" }
}

################################################
#      aws_route_table_association.public      #
################################################
resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

################################################
#             aws_route_table.app              #
################################################
# Зона приложения выходит наружу только через NAT: входящих соединений
# из интернета к ней нет.
resource "aws_route_table" "app" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = { Name = "${local.name_prefix}-app-rt" }
}

################################################
#       aws_route_table_association.app        #
################################################
resource "aws_route_table_association" "app" {
  for_each = aws_subnet.app

  subnet_id      = each.value.id
  route_table_id = aws_route_table.app.id
}

################################################
#            aws_route_table.data              #
################################################
# У этой таблицы намеренно нет маршрута 0.0.0.0/0. При полной
# компрометации приложения выгрузить базу наружу не получится. 
# Доступ к S3 — через шлюзовой эндпоинт.
resource "aws_route_table" "data" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${local.name_prefix}-data-rt" }
}

################################################
#       aws_route_table_association.data       #
################################################
resource "aws_route_table_association" "data" {
  for_each = aws_subnet.data

  subnet_id      = each.value.id
  route_table_id = aws_route_table.data.id
}

################################################
#             aws_vpc_endpoint.s3              #
################################################
# Шлюзовой эндпоинт
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.app.id, aws_route_table.data.id]

  tags = { Name = "${local.name_prefix}-s3-endpoint" }
}

################################################
#          aws_vpc_endpoint.interface          #
################################################
# Интерфейсные эндпоинты для сервисов управления.
resource "aws_vpc_endpoint" "interface" {
  for_each = var.enable_interface_endpoints ? toset([
    "ssm", "ssmmessages", "ec2messages", "kms", "secretsmanager",
  ]) : toset([])

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.app_subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = { Name = "${local.name_prefix}-${each.value}-endpoint" }
}
