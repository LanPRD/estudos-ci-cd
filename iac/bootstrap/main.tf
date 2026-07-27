# Camada aplicada manualmente (terraform apply local) — não via CI.
# A CI só consegue autenticar assumindo o tf-role, que é criado aqui;
# então esta camada não pode depender da própria CI pra existir.
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.56.0"
    }
  }
}

provider "aws" {
  region = "sa-east-1"
}
