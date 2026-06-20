variable "environment" {
  description = "Environment namespace (e.g., shared, prod, staging)"
  type = string
  default = "shared"
}

variable "region" {
  description = "Target AWS region for the state backend"
  type = string
  default = "us-east-1"
}

variable "state_retention_days" {
  description = "Retention period for historical state file versions"
  type = number
  default = 90
}

variable "tags" {
  description = "Global tags applied to all infrastructure resources"
  type = map(string)
  default = {
    ManagedBy = "terraform"
    Project = "state-backend"
    Environment = "shared"
  }
}
