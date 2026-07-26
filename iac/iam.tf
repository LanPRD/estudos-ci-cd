resource "aws_iam_role" "tf-role" {
  name        = "tf-role"
  description = "IAM role for GitHub Actions to access Terraform state"

  assume_role_policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Action" : "sts:AssumeRoleWithWebIdentity",
        "Principal" : {
          "Federated" : "arn:aws:iam::958157975241:oidc-provider/token.actions.githubusercontent.com"
        },
        "Condition" : {
          "StringEquals" : {
            "token.actions.githubusercontent.com:aud" : [
              "sts.amazonaws.com"
            ]
          },
          "StringLike" : {
            "token.actions.githubusercontent.com:sub" : [
              "repo:LanPRD@76744839/estudos-ci-cd@1311551142:ref:refs/heads/master"
            ]
          }
        }
      }
    ]
  })

  tags = {
    IaC = "Terraform"
  }
}

resource "aws_iam_role" "ecr-role" {
  name        = "ecr-role"
  description = "IAM role for GitHub Actions to access ECR"

  assume_role_policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Action" : "sts:AssumeRoleWithWebIdentity",
        "Principal" : {
          "Federated" : "arn:aws:iam::958157975241:oidc-provider/token.actions.githubusercontent.com"
        },
        "Condition" : {
          "StringEquals" : {
            "token.actions.githubusercontent.com:aud" : [
              "sts.amazonaws.com"
            ]
          },
          "StringLike" : {
            "token.actions.githubusercontent.com:sub" : [
              "repo:LanPRD@76744839/estudos-ci-cd@1311551142:ref:refs/heads/master"
            ]
          }
        }
      }
    ]
  })

  tags = {
    IaC = "Terraform"
  }
}

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
