output "api_ingress_paths" {
  description = "Public endpoint(s) ECS Express provisioned for the API"
  value       = aws_ecs_express_gateway_service.api.ingress_paths
}
