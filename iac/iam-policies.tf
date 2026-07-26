resource "aws_iam_role_policy" "ecr-app-permission" {
  name = "ecr-app-permission"
  role = aws_iam_role.ecr-role.name

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Sid    = "Statement1"
      Effect = "Allow"
      Action = [
        "ecs:CreateCluster",
        "ecs:RegisterTaskDefinition",
        "ecs:CreateExpressGatewayService",
        "ecs:UpdateExpressGatewayService",
        "ecs:DescribeExpressGatewayService",
        "ecs:DescribeClusters",
        "ecs:DescribeServices",
        "ecs:ListServiceDeployments",
        "ecs:DescribeServiceDeployments",
        "ecs:TagResource",
        "ecs:UntagResource"
      ]
      Resource = "*"
      },
      {
        Sid = "Statement2"
        Action = [
          "iam:PassRole",
          "iam:CreateServiceLinkedRole",
        ]
        Effect   = "Allow"
        Resource = "*"
      },
      {
        Sid    = "Statement3",
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

resource "aws_iam_role_policy_attachment" "ecs-execution-role-policy" {
  role       = aws_iam_role.ecs-execution-role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy_attachment" "ecs-express-infrastructure-role-policy" {
  role       = aws_iam_role.ecs-express-infrastructure-role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSInfrastructureRoleforExpressGatewayServices"
}
