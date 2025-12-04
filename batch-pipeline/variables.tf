################################################################################
# Required Variables
################################################################################

variable "raw_bucket_name" {
  type        = string
  description = "Name for the S3 bucket to store raw/corrupted video files"
}

variable "processed_bucket_name" {
  type        = string
  description = "Name for the S3 bucket to store repaired video files"
}

variable "untrunc_image_uri" {
  type        = string
  description = "ECR image URI for the untrunc container (e.g., 123456789.dkr.ecr.us-east-1.amazonaws.com/untrunc:latest)"
}

variable "api_key_hash" {
  type        = string
  description = "SHA256 hash of the API key for authentication. Generate with: echo -n 'your-api-key' | sha256sum"
  sensitive   = true
}

################################################################################
# Optional Variables - General
################################################################################

variable "aws_region" {
  type        = string
  default     = "us-east-1"
  description = "AWS region for deployment"
}

variable "environment" {
  type        = string
  default     = "prod"
  description = "Environment name (prod, staging, dev)"
}

variable "log_retention_days" {
  type        = number
  default     = 30
  description = "CloudWatch log retention in days"
}

variable "raw_file_retention_days" {
  type        = number
  default     = 30
  description = "Days to retain raw files in S3 before automatic deletion"
}

################################################################################
# Optional Variables - Batch Job Configuration
################################################################################

variable "batch_max_vcpus" {
  type        = number
  default     = 16
  description = "Maximum vCPUs for the Batch compute environment"
}

variable "job_vcpu" {
  type        = number
  default     = 4
  description = "vCPUs per Batch job (Fargate: 0.25, 0.5, 1, 2, 4, 8, 16)"
}

variable "job_memory_mb" {
  type        = number
  default     = 8192
  description = "Memory (MB) per Batch job. For large videos, use 16384 or 30720"
}

variable "job_ephemeral_storage_gb" {
  type        = number
  default     = 100
  description = "Ephemeral storage (GB) for temp files. Must fit input + output + reference. Max 200GB"
}

variable "job_timeout_seconds" {
  type        = number
  default     = 7200
  description = "Job timeout in seconds (default 2 hours)"
}

variable "job_retry_attempts" {
  type        = number
  default     = 2
  description = "Number of retry attempts for failed jobs"
}

################################################################################
# Optional Variables - Notifications
################################################################################

variable "webhook_url" {
  type        = string
  default     = ""
  description = "HTTPS webhook URL to receive job completion notifications (optional)"
}

variable "alert_email" {
  type        = string
  default     = ""
  description = "Email address for failure alerts (optional)"
}
