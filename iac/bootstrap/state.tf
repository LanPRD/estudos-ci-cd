resource "aws_s3_bucket" "terraform-state" {
  bucket        = "estudos-ci-cd"
  force_destroy = true

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    IaC = "Terraform"
  }
}

resource "aws_s3_bucket_versioning" "terraform-state" {
  bucket = aws_s3_bucket.terraform-state.id

  versioning_configuration {
    status = "Enabled"
  }
}
