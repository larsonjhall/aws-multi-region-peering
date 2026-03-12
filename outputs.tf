output "website_url" {
  value = "http://${aws_s3_bucket_website_configuration.website.website_endpoint}"
}

output "api_url" {
  value = aws_apigatewayv2_stage.api.invoke_url
}

output "photos_bucket" {
  value = aws_s3_bucket.photos.bucket
}