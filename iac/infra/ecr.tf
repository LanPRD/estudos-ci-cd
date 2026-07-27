resource "aws_ecr_repository" "estudos-ci-cd" {
  name                 = "estudos-ci-cd"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    IaC = "Terraform"
  }
}
