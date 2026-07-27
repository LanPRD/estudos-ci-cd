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
          "Federated" : aws_iam_openid_connect_provider.oidc-git.arn
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
          "Federated" : aws_iam_openid_connect_provider.oidc-git.arn
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
