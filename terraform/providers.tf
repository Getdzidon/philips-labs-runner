provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "philips-labs-runner"
      ManagedBy   = "terraform"
      Environment = var.environment
    }
  }
}