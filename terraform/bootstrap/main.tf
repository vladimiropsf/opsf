provider "aws" {
  region = var.region
  default_tags {
    tags = {
      "managed-by"  = "terraform"
      "environment" = var.environment
    }
  }
}

// S3 for state storage
resource "aws_s3_bucket" "bucket" {
  bucket = local.bucket_name
  tags = {
    Name = "S3 Remote Terraform State Bucket"
  }
}

resource "aws_s3_bucket_versioning" "bucket" {
  bucket = aws_s3_bucket.bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}
