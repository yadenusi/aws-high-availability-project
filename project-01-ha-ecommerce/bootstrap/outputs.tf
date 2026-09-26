output "state_bucket_name" {
  description = "Name of the S3 bucket that stores the main stack state."
  value       = aws_s3_bucket.state.id
}

output "state_kms_key_arn" {
  description = "ARN of the KMS key that encrypts the state file."
  value       = aws_kms_key.state.arn
}

output "backend_config_file" {
  description = "Path of the generated backend config used by terraform init in the main stack."
  value       = abspath(local_file.backend_config.filename)
}

output "next_step" {
  description = "Command to run next."
  value       = "cd .. && terraform init -backend-config=backend.hcl"
}
