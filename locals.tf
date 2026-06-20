locals {
  name_prefix = "tf-${var.environment}"
  bucket_name = "${local.name_prefix}-state-${data.aws_caller_identity.account_id}"
  log_bucket = "${local.name_prefix}-state-logs-${data.aws_caller_identity.current.account_id}"
  lock_table = "${local.name_prefix}-lock"
}
