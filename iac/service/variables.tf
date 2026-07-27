variable "image_tag" {
  description = "Tag of the image in ECR that the ECS Express service should run"
  type        = string
  default     = "latest"
}
