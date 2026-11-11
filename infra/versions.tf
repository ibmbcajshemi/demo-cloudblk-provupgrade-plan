terraform {
  required_version = ">= 1.11.0, < 2.0.0"

  cloud {
    hostname     = "app.terraform.io"
    organization = "tce-to-tfe-migration"

    workspaces {
      name = "demo-cloudblk-provupgrade"
    }
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.67.0"
    }
  }
}
