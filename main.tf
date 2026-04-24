provider "aws" {
  region = "ap-northeast-1"
}

# Variables
variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
}

variable "project" {
  description = "Project name"
  type        = string
  default     = "data-regen"
}

# S3 Bucket and Versioning
resource "aws_s3_bucket" "aggregated_data_bucket" {
  bucket = "${var.project}-${var.environment}-bucket"
}

resource "aws_s3_bucket_versioning" "aggregated_data_bucket_versioning" {
  bucket = aws_s3_bucket.aggregated_data_bucket.id

  versioning_configuration {
    status = "Enabled"
  }
}

# DynamoDB Table
resource "aws_dynamodb_table" "data_table" {
  name         = "${var.project}-${var.environment}-table"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "userID"
  range_key    = "timestamp"

  attribute {
    name = "userID"
    type = "S"
  }

  attribute {
    name = "timestamp"
    type = "S"
  }

  tags = {
    Environment = var.environment
    Project     = var.project
  }
}

# Install npm dependencies and package Lambda function
resource "null_resource" "lambda_dependencies" {
  triggers = {
    dependencies_versions = filemd5("${path.module}/lambda_handler/package.json")
    source_versions       = filemd5("${path.module}/lambda_handler/index.js")
  }

  provisioner "local-exec" {
    command = "cd ${path.module}/lambda_handler && npm install --production"
  }
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda_handler"
  output_path = "${path.module}/lambda_function.zip"
  depends_on  = [null_resource.lambda_dependencies]
}

# IAM Role for Lambda
resource "aws_iam_role" "lambda_execution_role" {
  name = "${var.project}-${var.environment}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Effect = "Allow",
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Environment = var.environment
    Project     = var.project
  }
}

resource "aws_iam_policy" "lambda_policy" {
  name = "${var.project}-${var.environment}-lambda-policy"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket"
        ],
        Resource = [
          "${aws_s3_bucket.aggregated_data_bucket.arn}",
          "${aws_s3_bucket.aggregated_data_bucket.arn}/*"
        ]
      },
      {
        Effect = "Allow",
        Action = [
          "dynamodb:Query",
          "dynamodb:Scan"
        ],
        Resource = "${aws_dynamodb_table.data_table.arn}"
      },
      {
        Effect = "Allow",
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect = "Allow",
        Action = [
          "events:PutRule",
          "events:DeleteRule",
          "events:PutTargets",
          "events:RemoveTargets"
        ],
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_role_policy_attachment" {
  role       = aws_iam_role.lambda_execution_role.name
  policy_arn = aws_iam_policy.lambda_policy.arn
}

# Lambda Function
resource "aws_lambda_function" "regeneration_function" {
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  function_name    = "${var.project}-${var.environment}-function"
  role             = aws_iam_role.lambda_execution_role.arn
  handler          = "index.handler"
  runtime          = "nodejs18.x"
  timeout          = 10

  environment {
    variables = {
      BUCKET_NAME    = aws_s3_bucket.aggregated_data_bucket.bucket
      DYNAMODB_TABLE = aws_dynamodb_table.data_table.name
      ENV            = var.environment
    }
  }

  tags = {
    Environment = var.environment
    Project     = var.project
  }
}

# Lambda Permission for EventBridge
resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.regeneration_function.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.every_two_hours.arn
}

# EventBridge Rule
resource "aws_cloudwatch_event_rule" "every_two_hours" {
  name                = "${var.project}-${var.environment}-every-two-hours"
  description         = "Triggers every two hours"
  schedule_expression = "rate(2 hours)"

  tags = {
    Environment = var.environment
    Project     = var.project
  }
}

# EventBridge Target
resource "aws_cloudwatch_event_target" "lambda_target" {
  rule      = aws_cloudwatch_event_rule.every_two_hours.name
  target_id = "SendToLambda"
  arn       = aws_lambda_function.regeneration_function.arn
}

# API Gateway
resource "aws_api_gateway_rest_api" "order_api" {
  name = "${var.project}-${var.environment}-api"
}

resource "aws_api_gateway_resource" "order_resource" {
  rest_api_id = aws_api_gateway_rest_api.order_api.id
  parent_id   = aws_api_gateway_rest_api.order_api.root_resource_id
  path_part   = "order"
}

resource "aws_api_gateway_method" "post_method" {
  rest_api_id   = aws_api_gateway_rest_api.order_api.id
  resource_id   = aws_api_gateway_resource.order_resource.id
  http_method   = "POST"
  authorization = "NONE"
}

# ------------------------------
# MAIN FIX HERE:
# ------------------------------
resource "aws_api_gateway_integration" "lambda_integration" {
  rest_api_id             = aws_api_gateway_rest_api.order_api.id
  resource_id             = aws_api_gateway_resource.order_resource.id
  http_method             = aws_api_gateway_method.post_method.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = "arn:aws:apigateway:ap-northeast-1:lambda:path/2015-03-31/functions/${aws_lambda_function.regeneration_function.arn}/invocations"
}

resource "aws_api_gateway_deployment" "order_api_deployment" {
  rest_api_id = aws_api_gateway_rest_api.order_api.id
  depends_on = [
    aws_api_gateway_integration.lambda_integration
  ]
}

resource "aws_api_gateway_stage" "prod_stage" {
  stage_name    = "prod"
  rest_api_id   = aws_api_gateway_rest_api.order_api.id
  deployment_id = aws_api_gateway_deployment.order_api_deployment.id
}

# Outputs
output "api_endpoint" {
  description = "API Gateway endpoint"
  value       = aws_api_gateway_stage.prod_stage.invoke_url
}

output "s3_bucket_name" {
  description = "S3 Bucket Name"
  value       = aws_s3_bucket.aggregated_data_bucket.bucket
}

output "lambda_function_name" {
  description = "Lambda Function Name"
  value       = aws_lambda_function.regeneration_function.function_name
}

output "eventbridge_rule_name" {
  description = "EventBridge Rule Name"
  value       = aws_cloudwatch_event_rule.every_two_hours.name
}
