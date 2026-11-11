output "demo_bucket_name" {
  description = "Name of the demo S3 bucket."
  value       = aws_s3_bucket.demo.id
}

output "demo_topic_arn" {
  description = "ARN of the demo SNS topic."
  value       = aws_sns_topic.demo.arn
}

output "demo_parameter_name" {
  description = "Name of the demo SSM parameter."
  value       = aws_ssm_parameter.demo.name
}
