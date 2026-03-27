# =============================================================================
# main.tf
# Provisions the full monitoring + auto-remediation infrastructure:
#   - EC2 instance (the web-app server)
#   - SNS topic + email subscription (notifications)
#   - IAM role + least-privilege policy (Lambda permissions)
#   - Lambda function (auto-restart handler, zipped from lambda_function/)
#   - SNS → Lambda wiring (subscription + invoke permission)
# =============================================================================
#
# FOLDER STRUCTURE REQUIRED:
#   web-app-monitoring-remediation/
#       terraform/          <-- run terraform commands from here
#           main.tf
#       lambda_function/    <-- must sit next to terraform/
#           lambda_function.py
#
# The archive_file data source below zips lambda_function.py automatically
# using the relative path ../lambda_function. No manual zipping needed.
#
# DEPLOY:
#   terraform init
#   terraform plan  -var="notification_email=you@example.com"
#   terraform apply -var="notification_email=you@example.com"
# =============================================================================

terraform {
  required_version = ">= 1.3"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ── Variables ──────────────────────────────────────────────────────────────────

variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "notification_email" {
  description = "Email address that receives SNS alert notifications"
  type        = string
  default     = "ops-team@example.com"
}

variable "ec2_instance_type" {
  description = "EC2 instance type for the web-app server"
  type        = string
  default     = "t2.micro"  # free tier eligible
}

variable "ec2_ami" {
  description = "AMI ID for the EC2 instance (Amazon Linux 2023, us-east-1)"
  type        = string
  default     = "ami-0c02fb55956c7d316"  # update if deploying in a different region
}

# ── EC2 Instance ───────────────────────────────────────────────────────────────
# This is the web-app server that the Lambda function will restart.
# It must be created before the Lambda function so its ARN can be
# referenced in the IAM policy.

resource "aws_instance" "web_app" {
  ami           = var.ec2_ami
  instance_type = var.ec2_instance_type

  tags = {
    Name        = "web-app-server"
    Environment = "demo"
    ManagedBy   = "terraform"
  }
}

# ── SNS Topic ──────────────────────────────────────────────────────────────────

resource "aws_sns_topic" "alerts" {
  name = "slow-api-alerts"
}

# Optional: email subscription — confirms after apply via an email link
resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

# ── IAM Role for Lambda (least privilege) ──────────────────────────────────────

resource "aws_iam_role" "lambda_role" {
  name = "lambda-ec2-restart-role"

  # Trust policy: only the Lambda service can assume this role
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "lambda-ec2-restart-policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [

      # 1. Write logs to CloudWatch (required for all Lambda functions)
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },

      # 2. Stop, start, and describe — scoped to this specific EC2 instance only
      {
        Effect = "Allow"
        Action = [
          "ec2:StopInstances",
          "ec2:StartInstances",
          "ec2:DescribeInstances"
        ]
        Resource = aws_instance.web_app.arn
      },

      # 3. Publish to this specific SNS topic only (not all topics)
      {
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = aws_sns_topic.alerts.arn
      }
    ]
  })
}

# ── Lambda Function ────────────────────────────────────────────────────────────

# Automatically zip the Python source at plan time.
# Requires lambda_function/ folder to be next to terraform/ (one level up).
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda_function"
  output_path = "${path.module}/lambda_function.zip"
}

resource "aws_lambda_function" "ec2_restart" {
  function_name    = "ec2-auto-restart"
  description      = "Triggered by Sumo Logic alert; restarts EC2 and sends SNS notification"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.12"
  role             = aws_iam_role.lambda_role.arn
  timeout          = 120  # seconds — enough time for stop + waiter + start + waiter

  # Environment variable names must match exactly what the Python code reads:
  #   os.environ['INSTANCE_ID']   and   os.environ['SNS_TOPIC_ARN']
  environment {
    variables = {
      INSTANCE_ID   = aws_instance.web_app.id
      SNS_TOPIC_ARN = aws_sns_topic.alerts.arn
    }
  }
}

# ── Wire SNS → Lambda ──────────────────────────────────────────────────────────

# Allow SNS to invoke the Lambda function
resource "aws_lambda_permission" "allow_sns" {
  statement_id  = "AllowSNSInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ec2_restart.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.alerts.arn
}

# Subscribe Lambda directly to the SNS topic
resource "aws_sns_topic_subscription" "lambda_trigger" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.ec2_restart.arn
}

# ── Outputs ────────────────────────────────────────────────────────────────────

output "ec2_instance_id" {
  description = "ID of the web-app EC2 instance"
  value       = aws_instance.web_app.id
}

output "lambda_function_name" {
  description = "Name of the auto-restart Lambda function"
  value       = aws_lambda_function.ec2_restart.function_name
}

output "sns_topic_arn" {
  description = "ARN of the SNS alerts topic"
  value       = aws_sns_topic.alerts.arn
}
