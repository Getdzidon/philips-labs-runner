module "runners" {
  source  = "philips-labs/github-runner/aws"
  version = "~> 6.1.0"

  aws_region = var.aws_region
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  prefix = var.environment

  github_app = {
    key_base64     = var.github_app_key_base64
    id             = var.github_app_id
    webhook_secret = var.github_app_webhook_secret
  }

  # Runner configuration
  enable_organization_runners = var.enable_organization_runners
  runner_extra_labels         = var.runner_extra_labels
  instance_types              = var.instance_types
  runners_maximum_count       = var.runners_maximum_count

  # Ephemeral runners — fresh instance per job, terminated after use
  enable_ephemeral_runners = true

  # Spot instances for cost savings
  instance_target_capacity_type = "spot"
  create_service_linked_role_spot = true

  # Scale down check every minute
  scale_down_schedule_expression = "cron(*/5 * * * ? *)"

  # Warm pool during business hours (Mon-Fri 8-18 UTC)
  idle_config = [{
    cron      = "* * 8-18 * * 1-5"
    timeZone  = "UTC"
    idleCount = 1
  }]

  # Runner instance settings
  block_device_mappings = [{
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }]

  # Enable SSM for debugging
  enable_ssm_on_runners = true

  # CloudWatch agent for logs
  enable_cloudwatch_agent = true

  # Webhook delay — seconds before scale-up lambda processes the event
  delay_webhook_event = 5

  # Runner naming
  runner_name_prefix = "${var.environment}_"

  # Use EventBridge for event routing
  eventbridge = {
    enable = true
  }

  # AMI housekeeper — clean up old AMIs
  enable_ami_housekeeper = true
  ami_housekeeper_cleanup_config = {
    minimumDaysOld = 14
  }

  # Spot termination watcher
  instance_termination_watcher = {
    enable = true
  }

  # Log retention
  logging_retention_in_days = 30

  tags = {
    Project = "philips-labs-runner"
  }
}

# Configure the GitHub App webhook to point to the API Gateway
module "webhook_github_app" {
  source     = "philips-labs/github-runner/aws//modules/webhook-github-app"
  version    = "~> 6.1.0"
  depends_on = [module.runners]

  github_app = {
    key_base64     = var.github_app_key_base64
    id             = var.github_app_id
    webhook_secret = var.github_app_webhook_secret
  }

  webhook_endpoint = module.runners.webhook.endpoint
}
