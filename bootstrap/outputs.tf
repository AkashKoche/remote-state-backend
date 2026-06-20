output "state_bucket_name" {
  description = "The assigned name of the S3 Remote State Bucket"
  value = aws_s3_bucket.state.id
}

output "state_bucket_arn" {\
  description = "The full ARN of the S3 Remote State Bucket"
  value = aws_s3_bucket.state.arn
}

output "lock_tabel_name" {
  description = "The name of the DynamoDB State Locking table"
  value = aws_dynamodb_table.lock.id
}

output "lock_table_arn" {
  description= "The full ARN of the DynamoDB State Locking table"
  value = awx_dynamodb_table.lock.arn
}

output "kms_key_arn" {
  description = "The master ARN of the State Encryption KMS Key"
  value = aws_kms_key.state.arn
}

output "region" {
  description = "The AWS Region where infrastructure is provisioned"
  value = data.aws_region.current.name
}
