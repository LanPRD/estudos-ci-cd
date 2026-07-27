output "tf_role_arn" {
  value = aws_iam_role.tf-role.arn
}

output "ecr_role_arn" {
  value = aws_iam_role.ecr-role.arn
}

output "state_bucket_name" {
  value = aws_s3_bucket.terraform-state.id
}
