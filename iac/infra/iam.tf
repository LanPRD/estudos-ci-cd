resource "aws_iam_role" "ecs-execution-role" {
  name        = "ecs-execution-role"
  description = "Lets ECS pull images from ECR and publish container logs to CloudWatch"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          "Service" = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    IaC = "Terraform"
  }
}

resource "aws_iam_role" "ecs-express-infrastructure-role" {
  name        = "ecs-express-infrastructure-role"
  description = "Lets ECS Express Mode manage the load balancer, target groups, security groups and auto scaling for the service"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          "Service" = "ecs.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    IaC = "Terraform"
  }
}
