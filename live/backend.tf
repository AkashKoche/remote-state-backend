terraform {
  backend "s3"
    bucket = "tf-shared-state-123456789"
    key = "services/api/terraform.tfstate"
    region = "us-east-1"
    dynamodb_table = "tf-shared-lock"
    kms_key_id  = "alias/tf-shared-state"
    encrypt     = true
}
