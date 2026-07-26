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

resource "aws_iam_role_policy" "ecr-app-permission" {
  name = "ecr-app-permission"
  role = aws_iam_role.ecr-role.name

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid    = "Statement1",
        Effect = "Allow",
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:CompleteLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:GetAuthorizationToken"
        ],
        Resource = "*"
      }
    ]
  })
}
