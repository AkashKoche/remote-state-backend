resource "aws_iam_role" "developer" {
  name = "terraform-developer"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = { "sts:ExternalId" = "terraform-state-read" }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "developer" {
  role       = aws_iam_role.developer.name
  policy_arn = aws_iam_policy.read.arn
}
