data "aws_iam_role" "ecs-execution-role" {
  name = "ecs-execution-role"
}

data "aws_iam_role" "ecs-express-infrastructure-role" {
  name = "ecs-express-infrastructure-role"
}

data "aws_ecr_repository" "estudos-ci-cd" {
  name = "estudos-ci-cd"
}

data "aws_cloudwatch_log_group" "api" {
  name = "/ecs/estudos-ci-cd"
}
