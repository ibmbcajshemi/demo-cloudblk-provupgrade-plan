resource "aws_s3_bucket" "demo" {
  bucket = var.demo_bucket_name
}

resource "aws_s3_bucket_public_access_block" "demo" {
  bucket = aws_s3_bucket.demo.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "demo" {
  bucket = aws_s3_bucket.demo.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_ssm_parameter" "demo" {
  name  = "/${var.name_prefix}/message"
  type  = "String"
  tier  = "Standard"
  value = "baseline"
}

resource "aws_sns_topic" "demo" {
  name = "${var.name_prefix}-topic"
}
