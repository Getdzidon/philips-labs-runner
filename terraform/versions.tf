terraform {
  required_version = ">= 1.3.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.38"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }

  backend "s3" {
    bucket  = "deebest-tf-state-bucket"
    key     = "philips-labs-runner/terraform.tfstate"
    region  = "eu-central-1"
    encrypt = true
  }
}
