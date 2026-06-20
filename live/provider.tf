provider "aws" {
  region = "us-east-1"

  assume_role {
    role_arn = "arn:aws:iam::123456789:role/terraform-admin"
    external_id = "terraform-state-access"
    session_name = "terraform-${basename(path.cwd)}"
  }

  default_tags {
    tags = {
      ManagedBy = "terraform"
      Project = "my-service"
      Environment = terraform.workspace
    }
  }
}
