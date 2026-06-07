# --- Providers ---
terraform {
  required_providers {
    aws     = { source = "hashicorp/aws",     version = "~> 5.0" }
    archive = { source = "hashicorp/archive", version = "~> 2.4" }
  }
}

provider "aws" {
  region = var.aws_region
}

# --- Zip the lambda/ folder (code + node_modules) for deployment ---
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda"
  output_path = "${path.module}/lambda.zip"
}

# --- DynamoDB table (same shape as your local one) ---
resource "aws_dynamodb_table" "history" {
  name         = "${var.project_name}-history"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"
  attribute {
    name = "id"
    type = "S"
  }
}

# --- IAM role: the Lambda's identity ---
resource "aws_iam_role" "lambda_role" {
  name = "${var.project_name}-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

# Let it write logs to CloudWatch
resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Let it read/write ONLY our table
resource "aws_iam_role_policy" "lambda_dynamodb" {
  name = "${var.project_name}-dynamodb-access"
  role = aws_iam_role.lambda_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:Query", "dynamodb:Scan"]
      Resource = aws_dynamodb_table.history.arn
    }]
  })
}

# --- The Lambda function ---
resource "aws_lambda_function" "calculator" {
  function_name    = "${var.project_name}-fn"
  role             = aws_iam_role.lambda_role.arn
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  handler          = "index.handler"
  runtime          = "nodejs20.x"
  timeout          = 10
  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.history.name
      # Note: no DYNAMODB_ENDPOINT here — so on AWS it uses real DynamoDB
    }
  }
}

# --- API Gateway: the public HTTPS front door ---
resource "aws_apigatewayv2_api" "http_api" {
  name          = "${var.project_name}-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id                 = aws_apigatewayv2_api.http_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.calculator.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "calculate_route" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "POST /calculate"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http_api.id
  name        = "$default"
  auto_deploy = true
}

# Allow API Gateway to invoke the Lambda
resource "aws_lambda_permission" "api_gw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.calculator.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http_api.execution_arn}/*/*"
}
