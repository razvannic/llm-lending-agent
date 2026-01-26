terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      App = var.app_name
      Env = var.env
    }
  }
}

locals {
  prefix = "${var.env}-${var.app_name}"
}

# ---- DynamoDB
resource "aws_dynamodb_table" "main" {
  name         = "${local.prefix}-main"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "PK"
  range_key    = "SK"

  attribute {
    name = "PK"
    type = "S"
  }

  attribute {
    name = "SK"
    type = "S"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }
}

# ---- IAM role for lambda
resource "aws_iam_role" "lambda_role" {
  name = "${local.prefix}-agent-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect    = "Allow",
      Principal = { Service = "lambda.amazonaws.com" },
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "basic_exec" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_policy" "ddb_access" {
  name = "${local.prefix}-ddb-access"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Action = [
        "dynamodb:PutItem",
        "dynamodb:GetItem",
        "dynamodb:UpdateItem",
        "dynamodb:Query"
      ],
      Resource = [aws_dynamodb_table.main.arn]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ddb_access_attach" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.ddb_access.arn
}

# ---- Lambda (placeholder zip/jar must exist)
resource "aws_lambda_function" "agent" {
  function_name = "${local.prefix}-agent-gateway"
  role          = aws_iam_role.lambda_role.arn
  runtime       = "java17"
  handler       = "com.yourorg.agent.AgentGatewayHandler::handleRequest"
  timeout       = 15
  memory_size   = 512

  filename         = "${path.module}/artifacts/agent-gateway.jar"
  source_code_hash = filebase64sha256("${path.module}/artifacts/agent-gateway.jar")

  environment {
    variables = {
      ENV            = var.env
      DDB_TABLE_NAME = aws_dynamodb_table.main.name
    }
  }
}

resource "aws_cloudwatch_log_group" "agent" {
  name              = "/aws/lambda/${aws_lambda_function.agent.function_name}"
  retention_in_days = 7
}

# ---- API Gateway HTTP API -> Lambda
resource "aws_apigatewayv2_api" "http" {
  name          = "${local.prefix}-http-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_headers = ["content-type", "authorization"]
    allow_methods = ["POST", "OPTIONS"]
    allow_origins = ["*"] # dev only; tighten later
  }
}

resource "aws_apigatewayv2_integration" "agent" {
  api_id                 = aws_apigatewayv2_api.http.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.agent.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "chat" {
  api_id    = aws_apigatewayv2_api.http.id
  route_key = "POST /api/v1/chat"
  target    = "integrations/${aws_apigatewayv2_integration.agent.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "allow_apigw" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.agent.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http.execution_arn}/*/*"
}

output "lambda_agent_name" {
  value = aws_lambda_function.agent.function_name
}

output "api_base_url" {
  value = aws_apigatewayv2_api.http.api_endpoint
}
