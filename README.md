# Remote State Backend — Production-Grade Setup

> A complete, copy-pasteable Terraform project to set up a production-grade
> remote state backend on AWS with team collaboration, IAM, and CI/CD integration.

---

## 1. The Bootstrap Problem

You can't use Terraform to create the S3 bucket that holds Terraform state —
> not without state already being there. The standard solution:

1. **Bootstrap phase**: Create the backend resources with **local state** in a
   single, well-guarded location (your laptop or a CI runner).
2. **Migrate phase**: Run `terraform init -migrate-state` to push the bootstrap
   state into the bucket it just created.
3. **Steady state**: From now on, every workspace uses this bucket.

> ⚠️ The bootstrap state on your laptop is now a **single point of failure**.
> Back it up: `cp terraform.tfstate terraform.tfstate.backup` (it gets copied
> during migration, but belt-and-suspenders).

---

## 2. Bootstrap Configuration (Local State)

`bootstrap/backend.tf` — intentionally empty:

```hcl
# Bootstrap has NO backend block. State stays local on purpose.
# After `terraform apply` succeeds, you'll migrate state to the bucket
# this code just created. See README step 5.
```

`bootstrap/versions.tf`:

```hcl
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
  }
}
```

`bootstrap/variables.tf`:

```hcl
variable "environment" {
  description = "Environment name (e.g. shared, prod, staging)"
  type        = string
  default     = "shared"
}

variable "region" {
  description = "AWS region for the state bucket"
  type        = string
  default     = "us-east-1"
}

variable "state_retention_days" {
  description = "Days to keep old state versions before deletion"
  type        = number
  default     = 90
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default = {
    ManagedBy   = "terraform"
    Project     = "state-backend"
    Environment = "shared"
  }
}
```

`bootstrap/main.tf`:

```hcl
locals {
  name_prefix = "tf-${var.environment}"
  bucket_name = "${local.name_prefix}-state-${data.aws_caller_identity.current.account_id}"
  log_bucket  = "${local.name_prefix}-state-logs-${data.aws_caller_identity.current.account_id}"
  lock_table  = "${local.name_prefix}-lock"
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ---------------------------------------------------------------------------
# KMS key for state + log bucket encryption
# ---------------------------------------------------------------------------
resource "aws_kms_key" "state" {
  description             = "KMS key for Terraform state encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "RootAccountFullAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "StateBucketAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:Encrypt",
          "kms:DescribeKey",
        ]
        Resource = "*"
      },
    ]
  })
}

resource "aws_kms_alias" "state" {
  name          = "alias/${local.name_prefix}-state"
  target_key_id = aws_kms_key.state.key_id
}

# ---------------------------------------------------------------------------
# Logging bucket — receives S3 access logs for the state bucket
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "logs" {
  bucket = local.log_bucket

  tags = var.tags
}

resource "aws_s3_bucket_ownership_controls" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket = aws_s3_bucket.logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "logs" {
  bucket = aws_s3_bucket.logs.id
  configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    id     = "expire-old-logs"
    status = "Enabled"

    expiration {
      days = 365
    }

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# ---------------------------------------------------------------------------
# State bucket — the actual remote state
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "state" {
  bucket = local.bucket_name

  tags = var.tags
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_logging" "state" {
  bucket        = aws_s3_bucket.state.id
  target_bucket = aws_s3_bucket.logs.id
  target_prefix = "state-access-logs/"
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    noncurrent_version_expiration {
      noncurrent_days = var.state_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Bucket policy — enforce TLS, deny unencrypted uploads, deny deletion
resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyInsecureTransport"
        Effect = "Deny"
        Principal = "*"
        Action = "s3:*"
        Resource = [
          aws_s3_bucket.state.arn,
          "${aws_s3_bucket.state.arn}/*",
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      },
      {
        Sid    = "DenyUnencryptedUploads"
        Effect = "Deny"
        Principal = "*"
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.state.arn}/*"
        Condition = {
          StringNotEquals = {
            "s3:x-amz-server-side-encryption" = "aws:kms"
          }
        }
      },
      {
        Sid    = "DenyDeletionOfState"
        Effect = "Deny"
        Principal = "*"
        Action = [
          "s3:DeleteBucket",
          "s3:DeleteBucketPolicy",
          "s3:PutBucketPolicy",
        ]
        Resource = aws_s3_bucket.state.arn
        Condition = {
          StringNotEquals = {
            "aws:PrincipalArn" = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/terraform-admin"
          }
        }
      },
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.state]
}

# ---------------------------------------------------------------------------
# DynamoDB — state locking
# ---------------------------------------------------------------------------
resource "aws_dynamodb_table" "lock" {
  name         = local.lock_table
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.state.arn
  }

  tags = var.tags
}
```

`bootstrap/outputs.tf`:

```hcl
output "state_bucket_name" {
  description = "Name of the S3 bucket holding Terraform state"
  value       = aws_s3_bucket.state.id
}

output "state_bucket_arn" {
  description = "ARN of the S3 bucket holding Terraform state"
  value       = aws_s3_bucket.state.arn
}

output "lock_table_name" {
  description = "Name of the DynamoDB table used for state locking"
  value       = aws_dynamodb_table.lock.id
}

output "lock_table_arn" {
  description = "ARN of the DynamoDB table used for state locking"
  value       = aws_dynamodb_table.lock.arn
}

output "kms_key_arn" {
  description = "ARN of the KMS key used to encrypt state"
  value       = aws_kms_key.state.arn
}

output "region" {
  description = "Region where the backend lives"
  value       = data.aws_region.current.name
}
```

---

## 3. IAM Roles — Team Collaboration

`iam/policies/terraform-admin.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "StateBucketReadWrite",
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetBucketVersioning",
        "s3:GetBucketLocation"
      ],
      "Resource": "arn:aws:s3:::tf-shared-state-ACCOUNT_ID"
    },
    {
      "Sid": "StateObjectsReadWrite",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject"
      ],
      "Resource": "arn:aws:s3:::tf-shared-state-ACCOUNT_ID/*"
    },
    {
      "Sid": "LockTableRW",
      "Effect": "Allow",
      "Action": [
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:DeleteItem",
        "dynamodb:UpdateItem",
        "dynamodb:DescribeTable"
      ],
      "Resource": "arn:aws:dynamodb:REGION:ACCOUNT_ID:table/tf-shared-lock"
    },
    {
      "Sid": "KMSDecrypt",
      "Effect": "Allow",
      "Action": [
        "kms:Decrypt",
        "kms:GenerateDataKey",
        "kms:DescribeKey"
      ],
      "Resource": "arn:aws:kms:REGION:ACCOUNT_ID:key/KEY_ID"
    }
  ]
}
```

`iam/policies/terraform-read.json` (developers who only run `terraform plan`):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "StateBucketRead",
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetBucketVersioning",
        "s3:GetBucketLocation",
        "s3:GetObject"
      ],
      "Resource": [
        "arn:aws:s3:::tf-shared-state-ACCOUNT_ID",
        "arn:aws:s3:::tf-shared-state-ACCOUNT_ID/*"
      ]
    },
    {
      "Sid": "KMSDecrypt",
      "Effect": "Allow",
      "Action": [
        "kms:Decrypt",
        "kms:DescribeKey"
      ],
      "Resource": "arn:aws:kms:REGION:ACCOUNT_ID:key/KEY_ID"
    }
  ]
}
```

> **Why no DynamoDB access for read-only devs?** They don't need locks —
> they're not applying anything. This is least-privilege done right.

`iam/admin-role.tf`:

```hcl
resource "aws_iam_role" "admin" {
  name = "terraform-admin"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "sts:ExternalId" = "terraform-state-access"
          }
        }
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "admin" {
  role       = aws_iam_role.admin.name
  policy_arn = aws_iam_policy.admin.arn
}
```

`iam/developer-role.tf`:

```hcl
resource "aws_iam_role" "developer" {
  name = "terraform-developer"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "sts:ExternalId" = "terraform-state-read"
          }
        }
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "developer" {
  role       = aws_iam_role.developer.name
  policy_arn = aws_iam_policy.read.arn
}
```

`iam/ci-role.tf` — **OIDC for GitHub Actions (no long-lived keys!)**:

```hcl
data "aws_caller_identity" "current" {}

resource "aws_iam_role" "ci" {
  name = "github-actions-terraform"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            # ⚠️ Lock this to YOUR org/repo and only `main`
            "token.actions.githubusercontent.com:sub" = "repo:YOUR_ORG/YOUR_REPO:ref:refs/heads/main"
          }
        }
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ci" {
  role       = aws_iam_role.ci.name
  policy_arn = aws_iam_policy.admin.arn
}
```

> **Why OIDC beats access keys:** No secrets to leak. GitHub hands AWS a
> short-lived token; AWS validates the repo + branch. Rotate by deleting the
> role, not chasing 50 leaked keys.

---

## 4. Consumer Config — What Other Projects Use

`live/backend.tf`:

```hcl
terraform {
  backend "s3" {
    # Run `terraform init -backend-config=...` or pass via CLI/CI
    # bucket         = "tf-shared-state-123456789012"
    # key            = "services/api/terraform.tfstate"
    # region         = "us-east-1"
    # dynamodb_table = "tf-shared-lock"
    # kms_key_id     = "alias/tf-shared-state"
    # encrypt        = true
  }
}
```

`live/providers.tf` (assume role pattern):

```hcl
provider "aws" {
  region = "us-east-1"

  # When running as a developer / from CI
  assume_role {
    role_arn     = "arn:aws:iam::123456789012:role/terraform-admin"
    external_id  = "terraform-state-access"
    session_name = "terraform-${basename(path.cwd)}"
  }

  default_tags {
    tags = {
      ManagedBy   = "terraform"
      Project     = "my-service"
      Environment = terraform.workspace
    }
  }
}
```

---

## 5. GitHub Actions

`.github/workflows/terraform-plan.yml`:

```yaml
name: terraform-plan
on:
  pull_request:
    paths:
      - "**.tf"
      - ".github/workflows/terraform-*.yml"

permissions:
  id-token: write   # required for OIDC
  contents: read
  pull-requests: write

jobs:
  plan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::123456789012:role/github-actions-terraform
          aws-region: us-east-1

      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: 1.6.0

      - name: terraform fmt
        run: terraform fmt -check -recursive
        working-directory: live

      - name: terraform init
        run: |
          terraform init \
            -backend-config="bucket=tf-shared-state-123456789012" \
            -backend-config="key=${{ github.event.repository.name }}/terraform.tfstate" \
            -backend-config="region=us-east-1" \
            -backend-config="dynamodb_table=tf-shared-lock" \
            -backend-config="encrypt=true"
        working-directory: live

      - name: terraform validate
        run: terraform validate -no-color
        working-directory: live

      - name: tflint
        uses: terraform-linters/setup-tflint@v4
        with:
          tflint_version: latest
      - run: tflint --init && tflint --recursive
        working-directory: live

      - name: checkov
        uses: bridgecrewio/checkov-action@v12
        with:
          directory: live
          framework: terraform

      - name: terraform plan
        id: plan
        run: terraform plan -no-color -input=false -out=tfplan
        working-directory: live

      - name: Post plan to PR
        uses: actions/github-script@v7
        with:
          script: |
            const output = `#### Terraform Plan 📋
            \`\`\`
            ${{ steps.plan.outputs.stdout }}
            \`\`\`
            `;
            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: output
            });
```

`.github/workflows/terraform-apply.yml` (manual trigger):

```yaml
name: terraform-apply
on:
  workflow_dispatch:
    inputs:
      workspace:
        description: "Terraform workspace"
        required: true
        default: "default"

permissions:
  id-token: write
  contents: read

jobs:
  apply:
    runs-on: ubuntu-latest
    environment: production   # requires manual approval in GH Settings
    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::123456789012:role/github-actions-terraform
          aws-region: us-east-1

      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: 1.6.0

      - name: terraform init
        run: |
          terraform init \
            -backend-config="bucket=tf-shared-state-123456789012" \
            -backend-config="key=${{ github.event.repository.name }}/terraform.tfstate" \
            -backend-config="region=us-east-1" \
            -backend-config="dynamodb_table=tf-shared-lock" \
            -backend-config="encrypt=true"
        working-directory: live

      - name: terraform apply
        run: terraform apply -input=false -auto-approve
        working-directory: live
        env:
          TF_WORKSPACE: ${{ inputs.workspace }}
```

---

## 6. Migration From Local State

After the bootstrap `apply` succeeds:

```bash
cd bootstrap

# Verify what's about to happen
terraform init -migrate-state

# Answer "yes" to copy existing state to the new backend
# Terraform will write to:
#   s3://tf-shared-state-ACCOUNT_ID/bootstrap/terraform.tfstate

# Verify
aws s3 ls s3://tf-shared-state-ACCOUNT_ID/bootstrap/
terraform state list   # should still show all resources
```

From now on, **never** commit `terraform.tfstate` to git. Add to `.gitignore`:

```
.terraform/
*.tfstate
*.tfstate.*
*.tfvars
!*.tfvars.example
crash.log
crash.*.log
```

---

## 7. Team Workflow (Day-to-Day)

| Action | Developer | Platform | CI |
|---|---|---|---|
| `terraform plan` | ✅ (read role) | ✅ | ✅ |
| `terraform apply` dev | ❌ | ✅ | ✅ |
| `terraform apply` prod | ❌ | ✅ (manual approval) | ✅ (manual approval) |
| `terraform state` commands | ❌ | ✅ | ⚠️ via CI only |
| `terraform destroy` | ❌ | ✅ | ❌ (block in CI) |

**Local dev setup** (so devs don't have to manage AWS keys):

```bash
# 1. AWS CLI profile that uses SSO or short-lived creds
aws configure sso   # or use aws-vault / Granted / Leapp

# 2. Set the env var for Terraform to assume the read role
export AWS_PROFILE=dev
# Or use aws-vault:
aws-vault exec dev -- terraform plan
```

---

## 8. Production Hardening Checklist

- [x] **Versioning on** — accidental `rm` is recoverable
- [x] **SSE-KMS** with `enable_key_rotation = true`
- [x] **Public access blocked** on all 4 settings
- [x] **Bucket policy denies** `aws:SecureTransport=false`
- [x] **Bucket policy denies** unencrypted uploads
- [x] **Bucket policy denies** bucket deletion (allowlist admin role)
- [x] **Access logging** to a separate bucket
- [x] **Lifecycle rule** for old versions (90 days typical)
- [x] **DynamoDB PITR** enabled (recover from accidental lock corruption)
- [x] **DynamoDB encrypted** with same KMS key
- [x] **External ID** on assume role (defense in depth)
- [x] **OIDC for CI** — no long-lived secrets
- [x] **IAM scoped per role** — admin vs read vs CI
- [x] **`.gitignore`** excludes state files
- [x] **PR-based plans**, manual approval for apply
- [x] **`prevent_destroy`** on the bucket and lock table in **other** projects that use this backend

### Add `prevent_destroy` to anything important

In any other Terraform project that uses this backend:

```hcl
resource "aws_s3_bucket" "critical_data" {
  # ...
  lifecycle {
    prevent_destroy = true
  }
}
```

---

## 9. Common Pitfalls (I see these in every code review)

| Pitfall | What breaks | Fix |
|---|---|---|
| Forgot `dynamodb_table` in backend | Concurrent applies corrupt state | Always include lock table |
| Bucket not versioned | `terraform apply` that deletes a resource = gone forever | Enable versioning + check it on every PR |
| Used `SSE-S3` instead of `SSE-KMS` | Compliance fails; no key rotation | Use `aws:kms` with rotation |
| Public access block missing | One typo leaks the bucket to the world | All 4 settings = true |
| No `prevent_destroy` on data buckets | `terraform destroy` in a wrong env wipes prod | Add to every stateful resource |
| DynamoDB PITR off | Corrupted lock table blocks everyone | Enable it, costs pennies |
| Assume role without `external_id` | Confused-deputy risk if AWS account IDs overlap | Always set external_id |
| Long-lived IAM keys in CI | Leaks in logs, repos, screenshots | Use OIDC; rotate by deleting the role |
| Same state file for prod and non-prod | `apply` in staging breaks prod | Use workspaces OR separate state keys |
| `force-unlock` without thinking | Two applies can clobber each other | Only use when you KNOW no apply is running |

---

## 10. State Recovery Cheatsheet

### "I need to see what was in state 3 days ago"
```bash
aws s3api list-object-versions --bucket tf-shared-state-ACCOUNT_ID --prefix services/api/
# Find old version ID, then:
aws s3api get-object --bucket ... --version-id OLD_VERSION_ID tfstate-backup.json
terraform state push tfstate-backup.json   # CAREFUL — only when truly needed
```

### "Lock is stuck, no apply is running"
```bash
# 1. Verify no apply is running:
aws dynamodb scan --table-name tf-shared-lock
# Look at LockID entries. If an apply is running, you'll see one.
# 2. If truly orphaned:
terraform force-unlock <LOCK_ID>
```

### "I accidentally applied to the wrong workspace"
```bash
# DON'T PANIC. State is versioned in S3.
# 1. Find the previous version
aws s3api list-object-versions --bucket tf-shared-state-ACCOUNT_ID --prefix services/api/terraform.tfstate
# 2. Download it
aws s3api get-object --bucket ... --version-id PREVIOUS_ID old.tfstate
# 3. Restore
terraform state push old.tfstate
# 4. Run plan to see what state thinks the world is
terraform plan
```

---

## 11. Bonus: One-Command Bootstrap Script

`bootstrap.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=${AWS_REGION:-us-east-1}

echo "🚀 Bootstrapping Terraform state backend in $ACCOUNT_ID / $REGION"

# Make sure AWS creds are valid
aws sts get-caller-identity > /dev/null

cd bootstrap
terraform init
terraform apply -auto-approve \
  -var="region=$REGION"

BUCKET=$(terraform output -raw state_bucket_name)
TABLE=$(terraform output -raw lock_table_name)
KMS=$(terraform output -raw kms_key_arn)

echo ""
echo "✅ Backend ready!"
echo "   bucket:   $BUCKET"
echo "   lock:     $TABLE"
echo "   kms:      $KMS"
echo ""
echo "👉 Now migrate local state to the bucket:"
echo "   terraform init -migrate-state"
echo ""
echo "👉 Then in other projects, configure the backend like this:"
cat <<EOF

terraform {
  backend "s3" {
    bucket         = "$BUCKET"
    key            = "services/<NAME>/terraform.tfstate"
    region         = "$REGION"
    dynamodb_table = "$TABLE"
    encrypt        = true
  }
}

EOF
```

Run once, get all the values you need to wire up the rest of the org.

---

## TL;DR — The 5 things to remember

1. **Bootstrap with local state, then migrate.** Chicken-and-egg, one-time pain.
2. **Versioning + SSE-KMS + public-access-block = non-negotiable.** Every audit asks.
3. **Lock table in DynamoDB.** `PAY_PER_REQUEST`, PITR on, encrypted.
4. **OIDC for CI.** Long-lived IAM keys are a resume-generating event waiting to happen.
5. **Read vs admin roles.** Least privilege saves you when (not if) someone runs the wrong command in the wrong terminal.
