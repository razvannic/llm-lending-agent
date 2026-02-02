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

resource "aws_apigatewayv2_integration" "chat" {
  api_id                 = aws_apigatewayv2_api.http.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.agentcore_invoker.invoke_arn
  payload_format_version = "2.0"
}


resource "aws_apigatewayv2_route" "chat" {
  api_id    = aws_apigatewayv2_api.http.id
  route_key = "POST /api/v1/chat"
  target    = "integrations/${aws_apigatewayv2_integration.chat.id}"
  depends_on = [aws_apigatewayv2_integration.chat]
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http.id
  name        = "$default"
  auto_deploy = true
}

output "api_base_url" {
  value = aws_apigatewayv2_api.http.api_endpoint
}

# ==== lambda role for stage handler

resource "aws_iam_role" "stage_handler_role" {
  name = "${local.prefix}-stage-handler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = { Service = "lambda.amazonaws.com" },
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "stage_handler_basic_logs" {
  role       = aws_iam_role.stage_handler_role.name
  policy_arn  = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# ==== python lambda from zip

resource "aws_lambda_function" "stage_handler" {
  function_name = "${local.prefix}-stage-handler"
  role          = aws_iam_role.stage_handler_role.arn

  runtime = "python3.11"
  handler = "handler.handler"

  filename         = "${path.module}/artifacts/stage-handler.zip"
  source_code_hash = filebase64sha256("${path.module}/artifacts/stage-handler.zip")

  timeout = 10
  memory_size = 256
}

# ==== step functions execution role

resource "aws_iam_role" "sfn_role" {
  name = "${local.prefix}-sfn-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = { Service = "states.amazonaws.com" },
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "sfn_invoke_lambda" {
  name = "${local.prefix}-sfn-invoke-lambda"
  role = aws_iam_role.sfn_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Action = ["lambda:InvokeFunction"],
      Resource = aws_lambda_function.stage_handler.arn
    }]
  })
}

# ==== express state machine (sync)

locals {
  lending_sfn_definition = jsonencode({
    Comment = "Lending workflow - one step per interaction",
    StartAt = "HandleStage",
    States = {
      HandleStage = {
        Type = "Task",
        Resource = "arn:aws:states:::lambda:invoke",
        Parameters = {
          FunctionName = aws_lambda_function.stage_handler.arn,
          Payload = {
            "sessionId.$"     = "$.sessionId",
            "currentStage.$"  = "$.currentStage",
            "message.$"       = "$.message",
            "nlu.$"           = "$.nlu"
          }
        },
        OutputPath = "$.Payload",
        End = true
      }
    }
  })
}

resource "aws_sfn_state_machine" "lending_workflow" {
  name     = "${local.prefix}-lending-workflow"
  role_arn = aws_iam_role.sfn_role.arn
  type     = "EXPRESS"

  definition = local.lending_sfn_definition
}

# ==== iam role for agentcore runtime

# resource "aws_iam_role" "agentcore_role" {
#   name = "${local.prefix}-agentcore-role"
#
#   assume_role_policy = jsonencode({
#     Version = "2012-10-17",
#     Statement = [{
#       Effect = "Allow",
#       Principal = { Service = "bedrock-agentcore.amazonaws.com" },
#       Action = "sts:AssumeRole"
#     }]
#   })
# }

# ==== permission for dynamo db, read write, step functions, logs

# resource "aws_iam_role_policy" "agentcore_policy" {
#   name = "${local.prefix}-agentcore-policy"
#   role = aws_iam_role.agentcore_role.id
#
#   policy = jsonencode({
#     Version = "2012-10-17",
#     Statement = [
#       {
#         Effect = "Allow",
#         Action = [
#           "dynamodb:GetItem",
#           "dynamodb:PutItem",
#           "dynamodb:UpdateItem",
#           "dynamodb:Query"
#         ],
#         Resource = [
#           aws_dynamodb_table.main.arn
#         ]
#       },
#       {
#         Effect = "Allow",
#         Action = ["states:StartSyncExecution"],
#         Resource = [aws_sfn_state_machine.lending_workflow.arn]
#       }
#     ]
#   })
# }

# ==== ecr repository for agentcore image

resource "aws_ecr_repository" "agentcore_runtime" {
  name = "${local.prefix}-agentcore-runtime"
}

output "agentcore_ecr_repo_url" {
  value = aws_ecr_repository.agentcore_runtime.repository_url
}

# ==== agentcore runtime resource

# resource "aws_bedrockagentcore_agent_runtime" "runtime" {
#   name = "${local.prefix}-lending-agentcore"
#
#   # This must point to your ECR image
#   agent_runtime_artifact {
#     container_configuration {
#       image_uri = "${aws_ecr_repository.agentcore_runtime.repository_url}:dev"
#     }
#   }
#
#   role_arn = aws_iam_role.agentcore_role.arn
#
#   network_configuration {
#     network_mode = "PUBLIC"
#   }
#
#   environment_variables = {
#     ENV            = "dev"
#     DDB_TABLE_NAME = aws_dynamodb_table.main.name
#     SFN_ARN        = aws_sfn_state_machine.lending_workflow.arn
#   }
# }

# ==== iam and lambda agentcore invoker

resource "aws_iam_role" "agentcore_invoker_role" {
  name = "${local.prefix}-agentcore-invoker-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = { Service = "lambda.amazonaws.com" },
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "agentcore_invoker_logs" {
  role      = aws_iam_role.agentcore_invoker_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# ==== permissions to invoke agentcore

resource "aws_iam_role_policy" "agentcore_invoker_policy" {
  name = "${local.prefix}-agentcore-invoker-policy"
  role = aws_iam_role.agentcore_invoker_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Action = ["bedrock-agentcore:InvokeAgentRuntime"],
      Resource = "*"
      # Later: restrict Resource to your runtime ARN when you have it
    }]
  })
}

# ==== lambda function

resource "aws_lambda_function" "agentcore_invoker" {
  function_name = "${local.prefix}-agentcore-invoker"
  role          = aws_iam_role.agentcore_invoker_role.arn

  runtime = "python3.11"
  handler = "handler.handler"

  filename         = "${path.module}/artifacts/agentcore-invoker.zip"
  source_code_hash = filebase64sha256("${path.module}/artifacts/agentcore-invoker.zip")

  timeout     = 15
  memory_size = 256

  environment {
    variables = {
      AGENTCORE_RUNTIME_ARN = var.agentcore_runtime_arn
      AGENTCORE_QUALIFIER   = "DEFAULT"
    }
  }
}

# ==== lambda permission for api gateway

resource "aws_lambda_permission" "allow_apigw_invoke_invoker" {
  statement_id  = "AllowAPIGatewayInvokeAgentcoreInvoker"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.agentcore_invoker.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http.execution_arn}/*/*"
}
