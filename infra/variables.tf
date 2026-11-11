variable "region" {
  description = "AWS region for the demo resources."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Prefix used for resource names and the Project tag."
  type        = string
  default     = "demo-cloudblk-provupgrade"
}

variable "demo_bucket_name" {
  description = "Globally unique name of the (empty) demo S3 bucket."
  type        = string
  default     = "demo-cloudblk-provupgrade-ajs11102026"
}
