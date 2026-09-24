################################################
#              Версии и провайдер              #
################################################
# Версии провайдеров

terraform {
  # 1.10 — бэкенд S3 умеет use_lockfile и блокировка состояния 
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }

  ################################################
  #               Состояние в S3                 #
  ################################################
  # В состоянии лежат ARN секретов и параметры всех ресурсов, поэтому
  # шифрование обязательно, а доступ к бакету равен доступу к проекту.
  backend "s3" {
    bucket       = "itsyndicate-tfstate-andrew"
    key          = "week5/terraform.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }
}

################################################
#                 provider.aws                 #
################################################
# Теги вешаются на все ресурсы 
provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project            = var.project
      Environment        = var.environment
      ManagedBy          = "terraform"
      Owner              = var.owner
      DataClassification = "confidential"
      ComplianceScope    = "soc2"
    }
  }
}

################################################
#                Данные из AWS                 #
################################################

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

# Аккаунт, от имени которого балансировщик пишет логи доступа.
data "aws_elb_service_account" "main" {}

# Свежая AMI Amazon Linux 2023 из публичного параметра SSM
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

locals {
  name_prefix = "${var.project}-${var.environment}"
  azs         = slice(data.aws_availability_zones.available.names, 0, 2)
  account_id  = data.aws_caller_identity.current.account_id
  partition   = data.aws_partition.current.partition

  # Подсети в стабильном порядке
  public_subnet_ids = [for k in sort(keys(aws_subnet.public)) : aws_subnet.public[k].id]
  app_subnet_ids    = [for k in sort(keys(aws_subnet.app)) : aws_subnet.app[k].id]
  data_subnet_ids   = [for k in sort(keys(aws_subnet.data)) : aws_subnet.data[k].id]
}
