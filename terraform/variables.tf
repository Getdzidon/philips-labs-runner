variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "eu-central-1"
}

variable "environment" {
  description = "Environment name, used as prefix for all resources"
  type        = string
  default     = "gh-runners"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.1.0.0/16"
}

variable "github_app_id" {
  description = "GitHub App ID"
  type        = string
  sensitive   = true
}

variable "github_app_key_base64" {
  description = "Base64-encoded GitHub App private key (.pem)"
  type        = string
  sensitive   = true
}

variable "github_app_webhook_secret" {
  description = "GitHub App webhook secret"
  type        = string
  sensitive   = true
}

variable "instance_types" {
  description = "EC2 instance types for runners (multiple for spot diversity)"
  type        = list(string)
  default     = ["t3.medium", "t3.large"]
}

variable "runners_maximum_count" {
  description = "Maximum number of concurrent runners"
  type        = number
  default     = 5
}

variable "enable_organization_runners" {
  description = "Register runners at org level (true) or repo level (false)"
  type        = bool
  default     = false
}

variable "runner_extra_labels" {
  description = "Extra labels for the runners"
  type        = list(string)
  default     = ["ec2", "spot"]
}
