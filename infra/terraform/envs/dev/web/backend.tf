terraform {
  backend "s3" {
    bucket         = "tf-state-llm-lending-dev-020202772182"
    key            = "dev/web/terraform.tfstate"
    region         = "eu-central-1"
    dynamodb_table = "tf-locks"
    encrypt        = true
  }
}
