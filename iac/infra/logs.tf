resource "aws_cloudwatch_log_group" "api" {
  name              = "/ecs/estudos-ci-cd"
  retention_in_days = 7

  tags = {
    IaC = "Terraform"
  }
}
