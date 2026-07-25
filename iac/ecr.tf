resource "aws_ecr_repository" "estudos-ci-cd" {
  name                 = "estudos-ci-cd"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    IaC = "Terraform"
  }
}