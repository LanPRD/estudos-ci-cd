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
