# network_configuration is intentionally omitted: Express Mode provisions its
# own default-VPC networking (load balancer, security groups) when it's absent.
resource "aws_ecs_express_gateway_service" "api" {
  service_name            = "estudos-ci-cd"
  execution_role_arn      = data.aws_iam_role.ecs-execution-role.arn
  infrastructure_role_arn = data.aws_iam_role.ecs-express-infrastructure-role.arn
  cpu                     = "256"
  memory                  = "512"

  primary_container {
    image          = "${data.aws_ecr_repository.estudos-ci-cd.repository_url}:${var.image_tag}"
    container_port = 3000

    aws_logs_configuration {
      log_group         = data.aws_cloudwatch_log_group.api.name
      log_stream_prefix = "ecs"
    }
  }
}
