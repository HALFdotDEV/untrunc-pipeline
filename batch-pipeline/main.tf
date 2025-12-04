################################################################################
# Untrunc Video Repair Pipeline - Production Configuration
# 
# Architecture: API Gateway → Lambda → AWS Batch (Fargate Spot)
# 
# Features:
#   - Batch processing of multiple files from S3 prefix
#   - Auto-selection of reference file (smallest working file)
#   - Webhook notifications on completion/error
#   - Cost-optimized with Fargate Spot
#   - Full security hardening (encryption, auth, least privilege)
################################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }

  # Uncomment and configure for production
  # backend "s3" {
  #   bucket         = "your-terraform-state-bucket"
  #   key            = "untrunc/batch-pipeline/terraform.tfstate"
  #   region         = "us-east-1"
  #   encrypt        = true
  #   dynamodb_table = "terraform-state-lock"
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "untrunc-repair"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  name_prefix = "untrunc-${var.environment}"
  account_id  = data.aws_caller_identity.current.account_id
  region      = data.aws_region.current.name
}

################################################################################
# S3 Buckets with Security Hardening
################################################################################

resource "aws_s3_bucket" "raw_video" {
  bucket = var.raw_bucket_name

  tags = {
    Name = "${local.name_prefix}-raw-video"
  }
}

resource "aws_s3_bucket" "processed_video" {
  bucket = var.processed_bucket_name

  tags = {
    Name = "${local.name_prefix}-processed-video"
  }
}

# Encryption
resource "aws_s3_bucket_server_side_encryption_configuration" "raw_video" {
  bucket = aws_s3_bucket.raw_video.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "processed_video" {
  bucket = aws_s3_bucket.processed_video.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# Versioning on processed bucket for recovery
resource "aws_s3_bucket_versioning" "processed_video" {
  bucket = aws_s3_bucket.processed_video.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Block public access
resource "aws_s3_bucket_public_access_block" "raw_video" {
  bucket = aws_s3_bucket.raw_video.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "processed_video" {
  bucket = aws_s3_bucket.processed_video.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Lifecycle policy - clean up raw files after processing
resource "aws_s3_bucket_lifecycle_configuration" "raw_video" {
  bucket = aws_s3_bucket.raw_video.id

  rule {
    id     = "cleanup-processed-raw-files"
    status = "Enabled"

    filter {
      prefix = ""
    }

    expiration {
      days = var.raw_file_retention_days
    }
  }
}

# Lifecycle policy - clean up old versions
resource "aws_s3_bucket_lifecycle_configuration" "processed_video" {
  bucket = aws_s3_bucket.processed_video.id

  rule {
    id     = "cleanup-old-versions"
    status = "Enabled"

    filter {
      prefix = ""
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }
  }
}

################################################################################
# SNS Topic for Webhooks/Notifications
################################################################################

resource "aws_sns_topic" "job_notifications" {
  name = "${local.name_prefix}-job-notifications"
}

# HTTPS subscription for webhook (if configured)
resource "aws_sns_topic_subscription" "webhook" {
  count     = var.webhook_url != "" ? 1 : 0
  topic_arn = aws_sns_topic.job_notifications.arn
  protocol  = "https"
  endpoint  = var.webhook_url

  # Retry policy for reliability
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.notification_dlq.arn
  })
}

# Email subscription for alerts (if configured)
resource "aws_sns_topic_subscription" "email" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.job_notifications.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# DLQ for failed notifications
resource "aws_sqs_queue" "notification_dlq" {
  name                      = "${local.name_prefix}-notification-dlq"
  message_retention_seconds = 1209600 # 14 days
}

################################################################################
# IAM for Batch
################################################################################

resource "aws_iam_role" "batch_service_role" {
  name = "${local.name_prefix}-batch-service-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "batch.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "batch_service_role_policy" {
  role       = aws_iam_role.batch_service_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBatchServiceRole"
}

resource "aws_iam_role" "ecs_task_execution_role" {
  name = "${local.name_prefix}-ecs-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "batch_job_role" {
  name = "${local.name_prefix}-batch-job-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_policy" "batch_job_policy" {
  name        = "${local.name_prefix}-batch-job-policy"
  description = "Allow Batch jobs to access S3 and publish notifications"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3ReadRawBucket"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.raw_video.arn,
          "${aws_s3_bucket.raw_video.arn}/*"
        ]
      },
      {
        Sid    = "S3WriteProcessedBucket"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.processed_video.arn,
          "${aws_s3_bucket.processed_video.arn}/*"
        ]
      },
      {
        Sid    = "SNSPublish"
        Effect = "Allow"
        Action = [
          "sns:Publish"
        ]
        Resource = aws_sns_topic.job_notifications.arn
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "${aws_cloudwatch_log_group.batch_logs.arn}:*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "batch_job_role_attach" {
  role       = aws_iam_role.batch_job_role.name
  policy_arn = aws_iam_policy.batch_job_policy.arn
}

################################################################################
# VPC Networking
################################################################################

resource "aws_vpc" "batch_vpc" {
  cidr_block           = "10.42.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${local.name_prefix}-vpc"
  }
}

resource "aws_subnet" "public_1" {
  vpc_id                  = aws_vpc.batch_vpc.id
  cidr_block              = "10.42.1.0/24"
  availability_zone       = "${local.region}a"
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.name_prefix}-public-1"
  }
}

resource "aws_subnet" "public_2" {
  vpc_id                  = aws_vpc.batch_vpc.id
  cidr_block              = "10.42.2.0/24"
  availability_zone       = "${local.region}b"
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.name_prefix}-public-2"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.batch_vpc.id

  tags = {
    Name = "${local.name_prefix}-igw"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.batch_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "${local.name_prefix}-public-rt"
  }
}

resource "aws_route_table_association" "public_1" {
  subnet_id      = aws_subnet.public_1.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_2" {
  subnet_id      = aws_subnet.public_2.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "batch_sg" {
  name        = "${local.name_prefix}-batch-sg"
  description = "Security group for Batch Fargate jobs"
  vpc_id      = aws_vpc.batch_vpc.id

  # Outbound only - no inbound needed
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-batch-sg"
  }
}

################################################################################
# Batch Compute Environment & Queue
################################################################################

resource "aws_batch_compute_environment" "fargate_spot" {
  compute_environment_name = "${local.name_prefix}-fargate-spot"
  type                     = "MANAGED"
  service_role             = aws_iam_role.batch_service_role.arn

  compute_resources {
    type      = "FARGATE_SPOT"
    max_vcpus = var.batch_max_vcpus

    subnets = [
      aws_subnet.public_1.id,
      aws_subnet.public_2.id
    ]

    security_group_ids = [aws_security_group.batch_sg.id]
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_batch_job_queue" "main" {
  name                 = "${local.name_prefix}-job-queue"
  state                = "ENABLED"
  priority             = 1
  compute_environments = [aws_batch_compute_environment.fargate_spot.arn]
}

resource "aws_cloudwatch_log_group" "batch_logs" {
  name              = "/aws/batch/${local.name_prefix}"
  retention_in_days = var.log_retention_days
}

resource "aws_batch_job_definition" "untrunc" {
  name = "${local.name_prefix}-job"
  type = "container"

  platform_capabilities = ["FARGATE"]

  container_properties = jsonencode({
    image            = var.untrunc_image_uri
    command          = ["/app/run_untrunc.sh"]
    jobRoleArn       = aws_iam_role.batch_job_role.arn
    executionRoleArn = aws_iam_role.ecs_task_execution_role.arn

    resourceRequirements = [
      {
        type  = "VCPU"
        value = tostring(var.job_vcpu)
      },
      {
        type  = "MEMORY"
        value = tostring(var.job_memory_mb)
      }
    ]

    # Ephemeral storage for large video files
    ephemeralStorage = {
      sizeInGiB = var.job_ephemeral_storage_gb
    }

    environment = [
      { name = "INPUT_BUCKET", value = "" },
      { name = "INPUT_PREFIX", value = "" },
      { name = "OUTPUT_BUCKET", value = aws_s3_bucket.processed_video.bucket },
      { name = "SNS_TOPIC_ARN", value = aws_sns_topic.job_notifications.arn },
      { name = "JOB_ID", value = "" },
      { name = "AWS_REGION", value = local.region }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.batch_logs.name
        "awslogs-region"        = local.region
        "awslogs-stream-prefix" = "job"
      }
    }

    networkConfiguration = {
      assignPublicIp = "ENABLED"
    }
  })

  retry_strategy {
    attempts = var.job_retry_attempts
  }

  timeout {
    attempt_duration_seconds = var.job_timeout_seconds
  }
}

################################################################################
# Lambda for Job Submission
################################################################################

resource "aws_iam_role" "lambda_role" {
  name = "${local.name_prefix}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_policy" "lambda_policy" {
  name        = "${local.name_prefix}-lambda-policy"
  description = "Allow Lambda to submit Batch jobs and list S3"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SubmitBatchJobs"
        Effect = "Allow"
        Action = [
          "batch:SubmitJob",
          "batch:DescribeJobs"
        ]
        Resource = "*"
      },
      {
        Sid    = "ListRawBucket"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetObject"
        ]
        Resource = [
          aws_s3_bucket.raw_video.arn,
          "${aws_s3_bucket.raw_video.arn}/*"
        ]
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${local.region}:${local.account_id}:*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_policy_attach" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.lambda_policy.arn
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/lambda.zip"
}

resource "aws_lambda_function" "submit_job" {
  function_name = "${local.name_prefix}-submit-job"
  role          = aws_iam_role.lambda_role.arn
  runtime       = "python3.12"
  handler       = "lambda_function.lambda_handler"
  timeout       = 30

  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  environment {
    variables = {
      BATCH_JOB_QUEUE_ARN      = aws_batch_job_queue.main.arn
      BATCH_JOB_DEFINITION_ARN = aws_batch_job_definition.untrunc.arn
      DEFAULT_INPUT_BUCKET     = aws_s3_bucket.raw_video.bucket
      DEFAULT_OUTPUT_BUCKET    = aws_s3_bucket.processed_video.bucket
      API_KEY_HASH             = var.api_key_hash
    }
  }
}

################################################################################
# API Gateway with Authentication
################################################################################

resource "aws_apigatewayv2_api" "main" {
  name          = "${local.name_prefix}-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["POST", "OPTIONS"]
    allow_headers = ["Content-Type", "X-Api-Key"]
    max_age       = 300
  }
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.submit_job.arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "submit_job" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "POST /submit-batch"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_route" "health" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "GET /health"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_stage" "prod" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = "prod"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_logs.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      responseLength = "$context.responseLength"
    })
  }
}

resource "aws_cloudwatch_log_group" "api_logs" {
  name              = "/aws/apigateway/${local.name_prefix}"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.submit_job.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}

################################################################################
# CloudWatch Alarms
################################################################################

resource "aws_sns_topic" "alerts" {
  name = "${local.name_prefix}-alerts"
}

resource "aws_sns_topic_subscription" "alerts_email" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_metric_alarm" "batch_failed_jobs" {
  alarm_name          = "${local.name_prefix}-failed-jobs"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "FailedJobsCount"
  namespace           = "AWS/Batch"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Batch jobs are failing"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${local.name_prefix}-lambda-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Lambda function errors"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.submit_job.function_name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
}

################################################################################
# Outputs
################################################################################

output "api_endpoint" {
  value       = aws_apigatewayv2_api.main.api_endpoint
  description = "Base API endpoint URL"
}

output "submit_batch_url" {
  value       = "${aws_apigatewayv2_api.main.api_endpoint}/prod/submit-batch"
  description = "URL to submit batch repair jobs"
}

output "raw_bucket_name" {
  value       = aws_s3_bucket.raw_video.bucket
  description = "Upload raw/corrupted video files here"
}

output "processed_bucket_name" {
  value       = aws_s3_bucket.processed_video.bucket
  description = "Repaired video files appear here"
}

output "sns_topic_arn" {
  value       = aws_sns_topic.job_notifications.arn
  description = "SNS topic for job completion notifications"
}

output "job_queue_arn" {
  value       = aws_batch_job_queue.main.arn
  description = "Batch job queue ARN"
}
