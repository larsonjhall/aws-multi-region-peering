terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" {
  region = var.aws_region
}

# ── S3: Photos Storage Bucket ──────────────────────────────────────────────────
resource "aws_s3_bucket" "photos" {
  bucket = "${var.project_name}-photos-${random_id.suffix.hex}"
  force_destroy = true
}

resource "aws_s3_bucket_cors_configuration" "photos" {
  bucket = aws_s3_bucket.photos.id
  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "PUT", "POST"]
    allowed_origins = ["*"]
    max_age_seconds = 3000
  }
}

# ── S3: Static Website Bucket ──────────────────────────────────────────────────
resource "aws_s3_bucket" "website" {
  bucket = "${var.project_name}-website-${random_id.suffix.hex}"
  force_destroy = true
}

resource "aws_s3_bucket_website_configuration" "website" {
  bucket = aws_s3_bucket.website.id
  index_document { suffix = "index.html" }
}

resource "aws_s3_bucket_public_access_block" "website" {
  bucket                  = aws_s3_bucket.website.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "website" {
  depends_on = [aws_s3_bucket_public_access_block.website]
  bucket = aws_s3_bucket.website.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.website.arn}/*"
    }]
  })
}

# ── DynamoDB Table ─────────────────────────────────────────────────────────────
resource "aws_dynamodb_table" "labels" {
  name         = "${var.project_name}-labels"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "imageKey"

  attribute {
    name = "imageKey"
    type = "S"
  }
}

# ── Lambda: Upload ─────────────────────────────────────────────────────────────
data "archive_file" "upload" {
  type        = "zip"
  source_dir  = "${path.module}/lambdas/upload"
  output_path = "${path.module}/lambdas/upload.zip"
}

resource "aws_lambda_function" "upload" {
  filename         = data.archive_file.upload.output_path
  function_name    = "${var.project_name}-upload"
  role             = aws_iam_role.lambda_role.arn
  handler          = "index.handler"
  runtime          = "nodejs20.x"
  source_code_hash = data.archive_file.upload.output_base64sha256

  environment {
    variables = { PHOTOS_BUCKET = aws_s3_bucket.photos.bucket }
  }
}

# ── Lambda: Analyze ────────────────────────────────────────────────────────────
data "archive_file" "analyze" {
  type        = "zip"
  source_dir  = "${path.module}/lambdas/analyze"
  output_path = "${path.module}/lambdas/analyze.zip"
}

resource "aws_lambda_function" "analyze" {
  filename         = data.archive_file.analyze.output_path
  function_name    = "${var.project_name}-analyze"
  role             = aws_iam_role.lambda_role.arn
  handler          = "index.handler"
  runtime          = "nodejs20.x"
  source_code_hash = data.archive_file.analyze.output_base64sha256
  timeout          = 30

  environment {
    variables = { DYNAMODB_TABLE = aws_dynamodb_table.labels.name }
  }
}

resource "aws_lambda_permission" "s3_invoke_analyze" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.analyze.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.photos.arn
}

resource "aws_s3_bucket_notification" "photos_trigger" {
  bucket = aws_s3_bucket.photos.id
  lambda_function {
    lambda_function_arn = aws_lambda_function.analyze.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "photos/"
  }
  depends_on = [aws_lambda_permission.s3_invoke_analyze]
}

# ── Lambda: Fetch ──────────────────────────────────────────────────────────────
data "archive_file" "fetch" {
  type        = "zip"
  source_dir  = "${path.module}/lambdas/fetch"
  output_path = "${path.module}/lambdas/fetch.zip"
}

resource "aws_lambda_function" "fetch" {
  filename         = data.archive_file.fetch.output_path
  function_name    = "${var.project_name}-fetch"
  role             = aws_iam_role.lambda_role.arn
  handler          = "index.handler"
  runtime          = "nodejs20.x"
  source_code_hash = data.archive_file.fetch.output_base64sha256

  environment {
    variables = { DYNAMODB_TABLE = aws_dynamodb_table.labels.name }
  }
}

# ── API Gateway ────────────────────────────────────────────────────────────────
resource "aws_apigatewayv2_api" "api" {
  name          = "${var.project_name}-api"
  protocol_type = "HTTP"
  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["GET", "POST", "OPTIONS"]
    allow_headers = ["Content-Type"]
  }
}

resource "aws_apigatewayv2_stage" "api" {
  api_id      = aws_apigatewayv2_api.api.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_apigatewayv2_integration" "upload" {
  api_id             = aws_apigatewayv2_api.api.id
  integration_type   = "AWS_PROXY"
  integration_uri    = aws_lambda_function.upload.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "upload" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "POST /upload"
  target    = "integrations/${aws_apigatewayv2_integration.upload.id}"
}

resource "aws_apigatewayv2_integration" "fetch" {
  api_id             = aws_apigatewayv2_api.api.id
  integration_type   = "AWS_PROXY"
  integration_uri    = aws_lambda_function.fetch.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "fetch" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "GET /labels"
  target    = "integrations/${aws_apigatewayv2_integration.fetch.id}"
}

resource "aws_lambda_permission" "apigw_upload" {
  statement_id  = "AllowAPIGWUpload"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.upload.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api.execution_arn}/*/*"
}

resource "aws_lambda_permission" "apigw_fetch" {
  statement_id  = "AllowAPIGWFetch"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.fetch.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api.execution_arn}/*/*"
}

# ── Random suffix to keep bucket names unique ──────────────────────────────────
resource "random_id" "suffix" {
  byte_length = 4
}