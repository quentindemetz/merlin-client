# Backup of the Mac app's library (macOS/ › Library › Back Up Now) to S3:
# a private, versioned bucket and an IAM user that can only use that bucket.
#
#   cd infra/backup
#   eval "$(aws configure export-credentials --profile merlin --format env)"
#   terraform init && terraform apply
#
# The app's access key is made outside Terraform so its secret never lands
# in the state (see README.md › Backup).

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

variable "region" {
  type    = string
  default = "eu-west-1"
}

variable "noncurrent_days" {
  description = "Days a replaced or deleted file stays recoverable (bucket versioning)."
  type        = number
  default     = 90
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = "merlin-client" }
  }
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "backup" {
  bucket = "merlin-library-backup-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "backup" {
  bucket                  = aws_s3_bucket.backup.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "backup" {
  bucket = aws_s3_bucket.backup.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Each backup replaces Library.sqlite and prunes files the library no longer
# has: versioning keeps what was replaced or deleted for noncurrent_days.
resource "aws_s3_bucket_versioning" "backup" {
  bucket = aws_s3_bucket.backup.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "backup" {
  bucket     = aws_s3_bucket.backup.id
  depends_on = [aws_s3_bucket_versioning.backup]

  rule {
    id     = "expire-old-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_days
    }
    expiration {
      expired_object_delete_marker = true
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Deny anything not over TLS.
resource "aws_s3_bucket_policy" "backup" {
  bucket     = aws_s3_bucket.backup.id
  depends_on = [aws_s3_bucket_public_access_block.backup]
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "TLSOnly"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.backup.arn, "${aws_s3_bucket.backup.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

# The Mac app's identity: list, read, write and delete in this bucket only.
resource "aws_iam_user" "app" {
  name = "merlin-mac-app"
}

resource "aws_iam_user_policy" "app" {
  name = "library-backup"
  user = aws_iam_user.app.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "List"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.backup.arn
      },
      {
        Sid      = "Objects"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.backup.arn}/*"
      },
    ]
  })
}

output "bucket" {
  value = aws_s3_bucket.backup.id
}

output "region" {
  value = var.region
}

output "iam_user" {
  value = aws_iam_user.app.name
}
