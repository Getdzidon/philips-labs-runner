aws_region                  = "eu-central-1"
environment                 = "gh-runners"
vpc_cidr                    = "10.1.0.0/16"
instance_types              = ["t3.medium", "t3.large"]
runners_maximum_count       = 5
enable_organization_runners = false
runner_extra_labels         = ["ec2", "spot"]

# Sensitive values — pass via TF_VAR_* environment variables or -var flag:
#   TF_VAR_github_app_id
#   TF_VAR_github_app_key_base64
#   TF_VAR_github_app_webhook_secret