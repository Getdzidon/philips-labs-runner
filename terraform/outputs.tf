output "webhook_endpoint" {
  description = "API Gateway endpoint for the GitHub App webhook"
  value       = module.runners.webhook.endpoint
}

output "webhook_secret" {
  description = "Webhook secret (set this in your GitHub App settings)"
  value       = var.github_app_webhook_secret
  sensitive   = true
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "lambda_syncer_name" {
  description = "Name of the runner binaries syncer Lambda"
  value       = module.runners.binaries_syncer.lambda.function_name
}
