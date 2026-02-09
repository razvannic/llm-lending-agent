data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "web" {
  bucket = "${local.prefix}-web-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_website_configuration" "web" {
  bucket = aws_s3_bucket.web.id

  index_document { suffix = "index.html" }
  error_document { key = "index.html" }
}

# Allow public policies (must be permitted by account/org settings)
resource "aws_s3_bucket_public_access_block" "web" {
  bucket = aws_s3_bucket.web.id

  # Keep ACL public access blocked
  block_public_acls  = true
  ignore_public_acls = true

  # Allow public bucket policy (required for website hosting)
  block_public_policy     = false
  restrict_public_buckets = false
}

data "aws_iam_policy_document" "web_public_read" {
  statement {
    sid     = "PublicReadGetObject"
    effect  = "Allow"
    actions = ["s3:GetObject"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    resources = ["${aws_s3_bucket.web.arn}/*"]
  }
}

resource "aws_s3_bucket_policy" "web" {
  bucket = aws_s3_bucket.web.id
  policy = data.aws_iam_policy_document.web_public_read.json
}

output "web_website_url" {
  value = aws_s3_bucket_website_configuration.web.website_endpoint
}

output "web_bucket_name" {
  value = aws_s3_bucket.web.bucket
}
