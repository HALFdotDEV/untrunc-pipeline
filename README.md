# Untrunc Video Repair Pipeline

**Author:** Jeremiah Kroesche | Halfservers LLC

**Version:** 1.0.0  
**License:** MIT  
**Last Updated:** December 2025

---

## Table of Contents

1. [Introduction](#introduction)
2. [The Problem This Solves](#the-problem-this-solves)
3. [Architecture Overview](#architecture-overview)
4. [untrunc CLI Reference](#untrunc-cli-reference)
5. [Prerequisites](#prerequisites)
6. [Building the untrunc Binary](#building-the-untrunc-binary)
7. [AWS Batch Pipeline Deployment](#aws-batch-pipeline-deployment)
8. [Edge Service Deployment](#edge-service-deployment)
9. [API Reference](#api-reference)
10. [Webhook Notifications](#webhook-notifications)
11. [Dynamic Resource Scaling](#dynamic-resource-scaling)
12. [Configuration Reference](#configuration-reference)
13. [Security Features](#security-features)
14. [Monitoring and Observability](#monitoring-and-observability)
15. [Cost Estimation](#cost-estimation)
16. [Troubleshooting Guide](#troubleshooting-guide)
17. [FAQ](#faq)
18. [Development and Testing](#development-and-testing)
19. [Changelog](#changelog)

---

## Introduction

This is a production-ready, automated pipeline for repairing corrupted MP4, MOV, MKV, AVI, and M4V video files using the open-source [untrunc](https://github.com/anthwlock/untrunc) tool.

The pipeline provides two deployment options:

1. **Edge Service** - A Docker-based service that runs on a local Mac (Apple Silicon), watching an SMB share for new files and repairing them automatically
2. **AWS Batch Pipeline** - A serverless, cloud-based solution using AWS Batch with Fargate Spot for cost-effective batch processing

Both components can work independently or together, with the edge service falling back to AWS when local repairs fail.

---

## The Problem This Solves

### Why Videos Get Corrupted

When video recording is interrupted unexpectedly (power loss, battery depletion, SD card removal, application crash, etc.), the resulting file is often unplayable. This happens because:

- MP4/MOV containers store their index structure (the "moov atom") at the **end** of the file
- If recording stops abruptly, this index is never written
- Without the index, video players cannot decode the file, even though the actual video/audio data is intact

### How untrunc Fixes This

untrunc analyzes a **working reference video** from the same camera/software to understand:

- Codec parameters (resolution, frame rate, encoding settings)
- Atom structure and ordering
- Sample-to-chunk mapping patterns

It then reconstructs the missing index for the corrupted file, making it playable again.

### Why This Pipeline Exists

Before this pipeline, repairing videos required:

- Manually running untrunc on each file
- Running a Windows VM 24/7 (~$150-300/month on AWS)
- No automation, no notifications, no batch processing

This pipeline provides:

- **Fully automated** batch processing of multiple files
- **Auto-selection** of reference files (smallest or newest)
- **Cost-effective** processing with Fargate Spot (~$20-50/month)
- **Webhook notifications** for integration with other systems
- **Local + cloud hybrid** deployment options

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              EDGE DEPLOYMENT                                     │
│  (MacBook Air M-series / Apple Silicon)                                          │
│                                                                                  │
│  ┌──────────────────┐                                                            │
│  │   SMB Share      │   The SMB share is mounted from your NAS or file server   │
│  │   /Volumes/...   │   and contains subdirectories for the workflow:           │
│  │                  │                                                            │
│  │   ├── ready/     │◄── Drop corrupted video files here                        │
│  │   ├── export/    │◄── Repaired files are moved here                          │
│  │   └── quarantine/│◄── Failed files go here for manual review                 │
│  └────────┬─────────┘                                                            │
│           │                                                                      │
│           ▼                                                                      │
│  ┌──────────────────────────────────────────────────────────────────────────┐   │
│  │                     Edge Untrunc Service (Docker)                         │   │
│  │                                                                           │   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐  │   │
│  │  │  Scanner    │  │  Reference  │  │  Untrunc    │  │  AWS Fallback   │  │   │
│  │  │  (watches   │─▶│  Selector   │─▶│  Runner     │─▶│  (on failure)   │  │   │
│  │  │  ready/)    │  │  (smallest) │  │  (-n -s)    │  │  (API call)     │  │   │
│  │  └─────────────┘  └─────────────┘  └─────────────┘  └────────┬────────┘  │   │
│  │                                                               │           │   │
│  │  FastAPI Server: http://localhost:8080                        │           │   │
│  │    GET  /health     - Health check                            │           │   │
│  │    POST /scan-now   - Trigger immediate scan                  │           │   │
│  │    POST /repair     - Manual single-file repair               │           │   │
│  │    GET  /stats      - Current scanner status                  │           │   │
│  └───────────────────────────────────────────────────────────────┼───────────┘   │
│                                                                   │               │
└───────────────────────────────────────────────────────────────────┼───────────────┘
                                                                    │
                                                                    │ HTTPS API Call
                                                                    ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              AWS CLOUD                                           │
│                                                                                  │
│  ┌─────────────────┐      ┌──────────────────┐      ┌────────────────────────┐  │
│  │  API Gateway    │      │     Lambda       │      │   AWS Batch            │  │
│  │  (HTTP API)     │─────▶│  (Job Submitter) │─────▶│   (Fargate Spot)       │  │
│  │                 │      │                  │      │                        │  │
│  │  • API Key Auth │      │  • Lists S3 files│      │  • Downloads from S3   │  │
│  │  • Rate limiting│      │  • Selects ref   │      │  • Runs untrunc        │  │
│  │  • HTTPS only   │      │  • Scales resources│    │  • Uploads repaired    │  │
│  │                 │      │  • Submits job   │      │  • Sends notification  │  │
│  └─────────────────┘      └──────────────────┘      └───────────┬────────────┘  │
│                                                                  │               │
│         ┌────────────────────────────────────────────────────────┘               │
│         │                                                                        │
│         ▼                                                                        │
│  ┌─────────────┐         ┌─────────────┐         ┌─────────────┐                │
│  │  S3 Bucket  │         │  Batch Job  │         │  S3 Bucket  │                │
│  │  (Raw)      │────────▶│  Container  │────────▶│ (Processed) │                │
│  │             │         │             │         │             │                │
│  │  Encrypted  │         │  untrunc    │         │  Encrypted  │                │
│  │  Versioned  │         │  -n -s -dst │         │  Versioned  │                │
│  │  Lifecycle  │         │             │         │  Lifecycle  │                │
│  └─────────────┘         └──────┬──────┘         └─────────────┘                │
│                                 │                                                │
│                                 ▼                                                │
│                          ┌─────────────┐         ┌─────────────────────────┐    │
│                          │  SNS Topic  │────────▶│  Notifications          │    │
│                          │             │         │  • HTTPS Webhook        │    │
│                          │             │         │  • Email (optional)     │    │
│                          └─────────────┘         └─────────────────────────┘    │
│                                                                                  │
│  ┌───────────────────────────────────────────────────────────────────────────┐  │
│  │                         Monitoring & Alerting                              │  │
│  │                                                                            │  │
│  │  CloudWatch Logs ──── CloudWatch Alarms ──── SNS Alerts                   │  │
│  │    • Job output         • Failed jobs         • Email notifications       │  │
│  │    • Lambda logs        • Lambda errors       • Webhook delivery          │  │
│  │    • Structured JSON    • Queue depth         • PagerDuty integration     │  │
│  └───────────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### Data Flow

1. **Upload**: Corrupted video files are uploaded to S3 (or dropped in SMB share for edge)
2. **Trigger**: API call (or automatic scan) initiates repair job
3. **Reference Selection**: System automatically picks the smallest file as reference (assumption: smallest = complete/working)
4. **Repair**: untrunc processes each corrupted file using the reference
5. **Output**: Repaired files are uploaded to processed bucket (or export directory)
6. **Notification**: Webhook/email sent with job results

---

## untrunc CLI Reference

This pipeline uses the [anthwlock/untrunc](https://github.com/anthwlock/untrunc) fork, which is actively maintained and includes many bug fixes over the original.

### Basic Syntax

```bash
untrunc [options] <reference.mp4> <corrupted.mp4>
```

**Important**: The reference file comes FIRST, then the corrupted file.

### Options Used by This Pipeline

| Option | Description |
|--------|-------------|
| `-n` | Non-interactive mode. Don't prompt for confirmation. **Required for automation.** |
| `-s` | Step through unknown sequences. **Improves recovery of partially corrupted files.** |
| `-dst <path>` | Set output destination file or directory. Without this, output is `<input>_fixed.<ext>` |

### Example Commands

```bash
# Basic repair (output: corrupted_fixed.mp4)
untrunc reference.mp4 corrupted.mp4

# Non-interactive with stepping (recommended)
untrunc -n -s reference.mp4 corrupted.mp4

# Specify output destination
untrunc -n -s -dst /output/repaired.mp4 reference.mp4 corrupted.mp4

# Quiet mode (errors only)
untrunc -n -s -q reference.mp4 corrupted.mp4
```

### All Available Options

```
Usage: untrunc [options] <ok.mp4> [corrupt.mp4]

general options:
  -V              - version
  -n              - no interactive

repair options:
  -s              - step through unknown sequences
  -st <step_size> - used with '-s'
  -sv             - stretches video to match audio duration (beta)
  -dw             - don't write _fixed.mp4
  -dr             - dump repaired tracks, implies '-dw'
  -k              - keep unknown sequences
  -sm             - search mdat, even if no mp4-structure found
  -dcc            - dont check if chunks are inside mdat
  -dyn            - use dynamic stats
  -range <A:B>    - raw data range
  -dst <dir|file> - set destination
  -skip           - skip existing
  -noctts         - dont restore ctts
  -mp <bytes>     - set max partsize

analyze options:
  -a              - analyze
  -i[t|a|s]       - info [tracks|atoms|stats]
  -d              - dump samples
  -f              - find all atoms and check their lengths
  -lsm            - find all mdat,moov atoms
  -m <offset>     - match/analyze file offset

other options:
  -ms             - make streamable
  -sh             - shorten
  -u <mdat> <moov>- unite fragments

logging options:
  -q              - quiet, only errors
  -w              - show hidden
  -v / -vv        - verbose / very verbose
```

### Requirements for Reference Files

For best results, your reference file should:

1. **Be from the same camera/software** as the corrupted files
2. **Use the same settings** (resolution, frame rate, codec)
3. **Be complete and playable** (verify it plays correctly first)
4. **Be at least a few seconds long** (longer is sometimes better)

---

## Prerequisites

### Required Software

| Software | Minimum Version | Purpose |
|----------|-----------------|---------|
| Docker | 20.10+ | Container runtime |
| Docker Compose | 2.0+ | Multi-container orchestration |
| AWS CLI | 2.0+ | AWS resource management |
| Terraform | 1.5.0+ | Infrastructure as code |
| jq | 1.6+ | JSON processing |
| Git | 2.0+ | Source code management |

### Required AWS Permissions

The IAM user/role deploying this infrastructure needs:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:*",
        "batch:*",
        "ecs:*",
        "ecr:*",
        "iam:*",
        "lambda:*",
        "apigateway:*",
        "logs:*",
        "sns:*",
        "cloudwatch:*",
        "events:*"
      ],
      "Resource": "*"
    }
  ]
}
```

For production, scope these permissions down to specific resources.

### Hardware Requirements

**For Edge Service (Mac):**
- Apple Silicon (M1/M2/M3) recommended
- 8GB RAM minimum
- Fast SSD storage
- Stable network connection to SMB share

**For AWS Batch Jobs:**
- Resources scale automatically based on file sizes
- Maximum: 8 vCPU, 30GB RAM, 200GB storage per job

---

## Building the untrunc Binary

The pipeline includes a helper script to build untrunc for both platforms:

### Automated Build (Recommended)

```bash
# From the project root
./build-untrunc.sh
```

This script:
1. Clones the anthwlock/untrunc repository
2. Builds for linux/amd64 (AWS Batch containers)
3. Builds for linux/arm64 (Apple Silicon edge service)
4. Copies binaries to the correct locations

### Manual Build for Linux (x86_64)

```bash
# On a Linux machine or in Docker
git clone --depth 5 https://github.com/anthwlock/untrunc.git
cd untrunc

# Install dependencies (Debian/Ubuntu)
sudo apt-get install -y build-essential libavformat-dev libavcodec-dev libavutil-dev

# Build
make FF_VER=6.0

# Copy binary
cp untrunc /path/to/batch-pipeline/container/bin/untrunc-linux-amd64
```

### Manual Build for macOS (Apple Silicon)

```bash
# Install Homebrew dependencies
brew install ffmpeg pkg-config

# Clone and build
git clone --depth 5 https://github.com/anthwlock/untrunc.git
cd untrunc

export PKG_CONFIG_PATH="/opt/homebrew/lib/pkgconfig"
export CPPFLAGS="-I/opt/homebrew/include"
export LDFLAGS="-L/opt/homebrew/lib"
make

# Copy binary
cp untrunc /path/to/edge-service/bin/untrunc-arm64
```

### Using Docker for Cross-Compilation

```bash
# Build for AMD64 (AWS)
docker build --platform linux/amd64 -t untrunc-builder .
docker create --name temp-untrunc untrunc-builder
docker cp temp-untrunc:/untrunc ./untrunc-linux-amd64
docker rm temp-untrunc

# Build for ARM64 (Apple Silicon)
docker build --platform linux/arm64 -t untrunc-builder-arm .
docker create --name temp-untrunc-arm untrunc-builder-arm
docker cp temp-untrunc-arm:/untrunc ./untrunc-arm64
docker rm temp-untrunc-arm
```

---

## AWS Batch Pipeline Deployment

### Step 1: Configure Variables

```bash
cd batch-pipeline
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
# Required settings
aws_region            = "us-east-1"
environment           = "prod"
raw_bucket_name       = "mycompany-untrunc-raw-prod"
processed_bucket_name = "mycompany-untrunc-processed-prod"
untrunc_image_uri     = "123456789012.dkr.ecr.us-east-1.amazonaws.com/untrunc:latest"

# Generate API key hash: echo -n 'your-secret-key' | sha256sum | cut -d' ' -f1
api_key_hash          = "5e884898da28047d9f4b6ab7b3b6e6..."

# Notifications (optional but recommended)
webhook_url           = "https://hooks.slack.com/services/T00000000/B00000000/XXXXXXXX"
alert_email           = "ops@mycompany.com"

# Job resource defaults (auto-scaled per job, these are fallbacks)
job_vcpu                  = 4
job_memory_mb             = 8192
job_ephemeral_storage_gb  = 100
job_timeout_seconds       = 7200  # 2 hours
job_retry_attempts        = 2

# Log retention
log_retention_days        = 30
raw_file_retention_days   = 30
```

### Step 2: Initialize Terraform

```bash
terraform init
```

Expected output:
```
Initializing provider plugins...
- Finding hashicorp/aws versions matching "~> 5.0"...
- Installing hashicorp/aws v5.x.x...
Terraform has been successfully initialized!
```

### Step 3: Review the Plan

```bash
terraform plan -out=tfplan
```

Review the resources that will be created:
- 2 S3 buckets (raw and processed)
- API Gateway HTTP API
- Lambda function
- AWS Batch compute environment, job queue, and job definition
- IAM roles and policies
- SNS topic for notifications
- CloudWatch log groups and alarms

### Step 4: Apply the Configuration

```bash
terraform apply tfplan
```

Save the outputs:
```bash
terraform output > outputs.txt
```

Key outputs:
- `api_endpoint` - The URL for submitting jobs
- `raw_bucket_name` - Where to upload corrupted files
- `processed_bucket_name` - Where repaired files appear
- `ecr_repository_url` - Where to push the container image

### Step 5: Create ECR Repository and Push Container

```bash
# Create ECR repository (if not using Terraform-managed one)
aws ecr create-repository --repository-name untrunc --region us-east-1

# Get login credentials
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin 123456789012.dkr.ecr.us-east-1.amazonaws.com

# Build the container
cd container
docker build --platform linux/amd64 -t untrunc:latest .

# Tag and push
docker tag untrunc:latest 123456789012.dkr.ecr.us-east-1.amazonaws.com/untrunc:latest
docker push 123456789012.dkr.ecr.us-east-1.amazonaws.com/untrunc:latest
```

### Step 6: Test the Deployment

```bash
# Upload test files
aws s3 cp test-videos/ s3://mycompany-untrunc-raw-prod/test-batch/ --recursive

# Submit a job
curl -X POST "$(terraform output -raw api_endpoint)/submit-batch" \
  -H "Content-Type: application/json" \
  -H "X-Api-Key: your-secret-key" \
  -d '{"input_prefix": "test-batch"}'

# Check job status in AWS Console or CLI
aws batch describe-jobs --jobs <job-id-from-response>
```

---

## Edge Service Deployment

### Step 1: Prepare the Environment

```bash
cd edge-service

# Copy the untrunc binary for ARM64
mkdir -p bin
cp /path/to/untrunc-arm64 bin/untrunc-arm64
chmod +x bin/untrunc-arm64

# Create configuration
cp .env.example .env
```

### Step 2: Configure the Service

Edit `.env`:

```bash
# SMB share mount point on Mac
HOST_SMB_ROOT=/Volumes/mosaic_share

# Directory structure within the share
READY_DIR=ready
EXPORT_DIR=export
QUARANTINE_DIR=quarantine

# Scanner settings
SCAN_INTERVAL_SECONDS=30
MIN_FILE_AGE_SECONDS=60
MAX_CONCURRENT_JOBS=2
UNTRUNC_TIMEOUT_SECONDS=3600

# Reference file selection: "smallest" or "newest"
REFERENCE_STRATEGY=smallest

# AWS fallback (get these from Terraform outputs)
AWS_REPAIR_API_BASE_URL=https://abc123.execute-api.us-east-1.amazonaws.com/prod
AWS_API_KEY=your-secret-api-key
AWS_FALLBACK_RETRIES=3

# Logging: "json" for production, "text" for debugging
LOG_FORMAT=json
```

### Step 3: Mount the SMB Share

Using Finder:
1. Press Cmd+K
2. Enter: `smb://server/share`
3. Authenticate and mount

Using Terminal:
```bash
mkdir -p /Volumes/mosaic_share
mount_smbfs //user:password@server/share /Volumes/mosaic_share
```

For persistent mounts, add to `/etc/auto_master` or use a login script.

### Step 4: Build and Start the Service

```bash
docker compose up -d --build
```

### Step 5: Verify Operation

```bash
# Check container is running
docker compose ps

# View logs
docker compose logs -f

# Check health endpoint
curl http://localhost:8080/health
```

Expected health response:
```json
{
  "status": "healthy",
  "scanner_running": true,
  "known_files": 0,
  "current_reference": null
}
```

### Step 6: Test with Real Files

1. Drop a known-good video file in the `ready/` directory (this will be the reference)
2. Drop a corrupted video file in the same directory
3. Wait for the scan interval (30 seconds by default)
4. Check the `export/` directory for repaired files
5. Check the `quarantine/` directory for any failures

---

## API Reference

### Base URL

```
https://<api-id>.execute-api.<region>.amazonaws.com/prod
```

Get this from Terraform output: `terraform output api_endpoint`

### Authentication

All endpoints except `/health` require an API key in the `X-Api-Key` header:

```bash
curl -H "X-Api-Key: your-secret-key" https://...
```

### Endpoints

#### GET /health

Health check endpoint. No authentication required.

**Response:**
```json
{
  "status": "healthy",
  "service": "untrunc-batch-api",
  "default_input_bucket": "mycompany-untrunc-raw-prod",
  "default_output_bucket": "mycompany-untrunc-processed-prod"
}
```

#### POST /submit-batch

Submit a batch repair job.

**Request Body:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `input_prefix` | string | Yes | S3 prefix containing video files to repair |
| `input_bucket` | string | No | Override default input bucket |
| `output_bucket` | string | No | Override default output bucket |
| `output_prefix` | string | No | Override output prefix (defaults to input_prefix) |
| `reference_strategy` | string | No | "smallest" (default) or "newest" |
| `reference_key` | string | No | Explicit S3 key for reference file |
| `vcpu` | integer | No | Override auto-scaled vCPU (1-16) |
| `memory_mb` | integer | No | Override auto-scaled memory (512-122880) |
| `storage_gb` | integer | No | Override auto-scaled storage (21-200) |

**Example Request:**

```bash
curl -X POST https://abc123.execute-api.us-east-1.amazonaws.com/prod/submit-batch \
  -H "Content-Type: application/json" \
  -H "X-Api-Key: your-secret-key" \
  -d '{
    "input_prefix": "session-2025-01-15/camera1",
    "reference_strategy": "smallest"
  }'
```

**Success Response (202 Accepted):**

```json
{
  "message": "Batch repair job submitted",
  "job_id": "untrunc-a1b2c3d4e5f6",
  "batch_job_id": "12345678-1234-1234-1234-123456789012",
  "input_bucket": "mycompany-untrunc-raw-prod",
  "input_prefix": "session-2025-01-15/camera1",
  "output_bucket": "mycompany-untrunc-processed-prod",
  "output_prefix": "session-2025-01-15/camera1",
  "reference_file": "session-2025-01-15/camera1/clip001.mp4",
  "reference_size_mb": 45.67,
  "reference_strategy": "smallest",
  "files_to_repair": [
    "session-2025-01-15/camera1/clip002.mp4",
    "session-2025-01-15/camera1/clip003.mp4",
    "session-2025-01-15/camera1/clip004.mp4"
  ],
  "file_count": 3,
  "total_size_mb": 1536.89,
  "largest_file_mb": 678.45,
  "resources": {
    "vcpu": "4",
    "memory_mb": 8192,
    "storage_gb": 120,
    "auto_scaled": true
  }
}
```

**Error Responses:**

| Status | Description |
|--------|-------------|
| 400 | Invalid request (missing prefix, no files found, etc.) |
| 401 | Invalid or missing API key |
| 500 | Internal server error |

---

## Webhook Notifications

When a job completes (success, partial, or failure), a notification is sent to the configured webhook URL.

### Payload Format

```json
{
  "job_id": "untrunc-a1b2c3d4e5f6",
  "status": "COMPLETED",
  "message": "All 3 files repaired successfully",
  "input_bucket": "mycompany-untrunc-raw-prod",
  "input_prefix": "session-2025-01-15/camera1",
  "output_bucket": "mycompany-untrunc-processed-prod",
  "output_prefix": "session-2025-01-15/camera1",
  "reference_file": "session-2025-01-15/camera1/clip001.mp4",
  "total_files": 3,
  "success_count": 3,
  "failure_count": 0,
  "success_files": [
    "session-2025-01-15/camera1/clip002.mp4",
    "session-2025-01-15/camera1/clip003.mp4",
    "session-2025-01-15/camera1/clip004.mp4"
  ],
  "failed_files": [],
  "timestamp": "2025-01-15T14:30:00Z"
}
```

### Status Values

| Status | Description |
|--------|-------------|
| `COMPLETED` | All files repaired successfully |
| `PARTIAL` | Some files repaired, some failed |
| `FAILED` | All files failed to repair |

### Integrating with Slack

Example Slack webhook format:

```json
{
  "text": "Untrunc Job Completed",
  "blocks": [
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "*Job ID:* untrunc-a1b2c3d4e5f6\n*Status:* COMPLETED\n*Files:* 3 repaired, 0 failed"
      }
    }
  ]
}
```

You may need a Lambda or middleware to transform the payload to Slack's format.

---

## Dynamic Resource Scaling

The Lambda function automatically calculates appropriate job resources based on the files being processed.

### Scaling Tiers

| Total Size | vCPU | Memory | Storage | Use Case |
|------------|------|--------|---------|----------|
| ≤ 5 GB | 1 | 2 GB | 30 GB | Small batches (a few short clips) |
| ≤ 20 GB | 2 | 4 GB | 60 GB | Medium batches |
| ≤ 50 GB | 4 | 8 GB | 120 GB | Large batches |
| ≤ 100 GB | 4 | 16 GB | 175 GB | XL batches |
| ≤ 200 GB | 8 | 30 GB | 200 GB | XXL batches |

### Additional Scaling Logic

1. **Largest file consideration**: If the largest single file is very large, memory is bumped to 2x that file's size
2. **Storage buffer**: Storage is calculated as 3x the largest file + 10GB buffer
3. **Fargate limits**: Resources are capped at Fargate maximums (16 vCPU, 120GB RAM, 200GB storage)

### Manual Override

For special cases, you can override the auto-scaling:

```bash
curl -X POST .../submit-batch \
  -d '{
    "input_prefix": "huge-files",
    "vcpu": 8,
    "memory_mb": 30720,
    "storage_gb": 200
  }'
```

---

## Configuration Reference

### AWS Batch Pipeline (Terraform Variables)

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `aws_region` | string | `us-east-1` | AWS region for deployment |
| `environment` | string | `prod` | Environment name (prod, staging, dev) |
| `raw_bucket_name` | string | *required* | S3 bucket for corrupted files |
| `processed_bucket_name` | string | *required* | S3 bucket for repaired files |
| `untrunc_image_uri` | string | *required* | ECR image URI for batch container |
| `api_key_hash` | string | *required* | SHA256 hash of API key |
| `webhook_url` | string | `""` | HTTPS webhook for notifications |
| `alert_email` | string | `""` | Email for CloudWatch alarms |
| `job_vcpu` | number | `4` | Default vCPUs per job |
| `job_memory_mb` | number | `8192` | Default memory per job (MB) |
| `job_ephemeral_storage_gb` | number | `100` | Default ephemeral storage (GB) |
| `job_timeout_seconds` | number | `7200` | Job timeout (2 hours) |
| `job_retry_attempts` | number | `2` | Retry failed jobs |
| `batch_max_vcpus` | number | `16` | Max vCPUs in compute environment |
| `log_retention_days` | number | `30` | CloudWatch log retention |
| `raw_file_retention_days` | number | `30` | S3 lifecycle for raw bucket |

### Edge Service (Environment Variables)

| Variable | Default | Description |
|----------|---------|-------------|
| `HOST_SMB_ROOT` | `/Volumes/mosaic_share` | SMB mount path on Mac |
| `READY_DIR` | `ready` | Subdirectory for input files |
| `EXPORT_DIR` | `export` | Subdirectory for output files |
| `QUARANTINE_DIR` | `quarantine` | Subdirectory for failed files |
| `SCAN_INTERVAL_SECONDS` | `30` | Time between directory scans |
| `MIN_FILE_AGE_SECONDS` | `60` | File stability threshold |
| `MAX_CONCURRENT_JOBS` | `2` | Parallel repair limit |
| `UNTRUNC_TIMEOUT_SECONDS` | `3600` | Single file timeout |
| `REFERENCE_STRATEGY` | `smallest` | Reference selection method |
| `AWS_REPAIR_API_BASE_URL` | `""` | AWS API endpoint for fallback |
| `AWS_API_KEY` | `""` | API key for AWS auth |
| `AWS_FALLBACK_RETRIES` | `3` | Retry count for AWS calls |
| `LOG_FORMAT` | `json` | Log format (json or text) |

---

## Security Features

### API Authentication

- API Gateway uses API key authentication
- Key is stored as SHA256 hash (never plaintext)
- Keys can be rotated by updating Terraform variable

### Network Security

- API Gateway: HTTPS only, TLS 1.2+
- Batch jobs run in VPC with no inbound access
- Outbound only for S3 and SNS

### Data Security

- S3 buckets: AES-256 server-side encryption
- S3 buckets: Public access blocked
- S3 buckets: Versioning enabled for recovery
- CloudWatch logs: Encrypted

### Container Security

- Edge service runs as non-root user
- No shell injection possible (subprocess exec, not shell)
- Minimal base image (Debian slim)
- No unnecessary packages installed

### IAM Least Privilege

- Lambda: Only S3 list/read, Batch submit
- Batch jobs: Only S3 read/write to specific buckets, SNS publish
- No admin permissions

---

## Monitoring and Observability

### CloudWatch Logs

All components log to CloudWatch in structured JSON format:

```json
{
  "timestamp": "2025-01-15T14:30:00Z",
  "level": "INFO",
  "job_id": "untrunc-a1b2c3d4e5f6",
  "message": "Repair successful",
  "file": "clip002.mp4",
  "output": "s3://bucket/path/clip002.mp4",
  "size": 123456789
}
```

Log groups:
- `/aws/lambda/untrunc-prod-submit` - Lambda execution logs
- `/aws/batch/untrunc-prod` - Batch job logs

### CloudWatch Alarms

Pre-configured alarms:

| Alarm | Threshold | Action |
|-------|-----------|--------|
| Batch Job Failures | > 0 in 5 min | SNS notification |
| Lambda Errors | > 0 in 5 min | SNS notification |

### Metrics to Monitor

- `AWS/Batch/JobsFailed` - Failed batch jobs
- `AWS/Batch/JobsSucceeded` - Successful batch jobs  
- `AWS/Lambda/Errors` - Lambda function errors
- `AWS/Lambda/Duration` - Lambda execution time
- `AWS/S3/BucketSizeBytes` - Storage usage

### Setting Up Dashboards

```bash
# Example: Create CloudWatch dashboard
aws cloudwatch put-dashboard \
  --dashboard-name "UntruncPipeline" \
  --dashboard-body file://dashboard.json
```

---

## Cost Estimation

### AWS Batch Pipeline

For a typical workload of 10-20 files (10-50GB each) processed weekly:

| Component | Unit Cost | Monthly Usage | Monthly Cost |
|-----------|-----------|---------------|--------------|
| Fargate Spot (4 vCPU, 8GB) | ~$0.05/hour | ~20 hours | $1-5 |
| S3 Storage (500GB) | $0.023/GB | 500GB | $11.50 |
| S3 Requests | $0.005/1000 | ~10,000 | $0.05 |
| API Gateway | $1.00/million | ~1,000 | <$0.01 |
| Lambda | $0.20/million + duration | ~1,000 | <$0.01 |
| CloudWatch Logs | $0.50/GB | ~1GB | $0.50 |
| SNS | $0.50/million | ~100 | <$0.01 |
| **Total** | | | **~$15-25/month** |

### Comparison: Windows VM Approach

| Component | Monthly Cost |
|-----------|--------------|
| EC2 t3.large (24/7) | $60-80 |
| EBS Storage (200GB) | $20 |
| Windows License | $15 |
| **Total** | **$95-115/month** |

**Savings: 75-85%** with this pipeline vs. always-on VM

### Edge Service

The edge service runs on existing hardware (your Mac), so the only cost is electricity (~$5-10/month for a Mac mini running 24/7).

---

## Troubleshooting Guide

### Job Fails: "Reference file not found"

**Cause**: The auto-selected reference file might be corrupted.

**Solutions**:
1. Specify a known-good reference file explicitly:
   ```bash
   curl -X POST .../submit-batch \
     -d '{"input_prefix": "...", "reference_key": "path/to/known-good.mp4"}'
   ```
2. Use "newest" strategy instead of "smallest":
   ```bash
   -d '{"input_prefix": "...", "reference_strategy": "newest"}'
   ```

### Job Fails: "Output file too small"

**Cause**: untrunc couldn't repair the file, possibly due to:
- Reference file from different camera/settings
- File is too corrupted to recover
- Wrong codec

**Solutions**:
1. Try a different reference file
2. Try the `-dcc` flag (add to container script)
3. Check if the file is actually recoverable with the GUI version

### Batch Job Timeout

**Cause**: Large files taking too long to process.

**Solutions**:
1. Increase timeout in Terraform:
   ```hcl
   job_timeout_seconds = 14400  # 4 hours
   ```
2. Process fewer files per batch
3. Use larger instance (more vCPU)

### Out of Disk Space

**Cause**: Ephemeral storage not large enough for files.

**Solutions**:
1. Let auto-scaling handle it (it considers file sizes)
2. Override storage manually:
   ```bash
   -d '{"storage_gb": 200}'
   ```
3. Maximum is 200GB for Fargate

### Edge Service Can't Access SMB Share

**Causes**:
1. Share not mounted
2. Docker doesn't have file sharing permissions
3. Mac went to sleep and dropped mount

**Solutions**:
1. Verify mount: `ls /Volumes/mosaic_share`
2. Docker Desktop → Settings → Resources → File Sharing → Add `/Volumes`
3. Use `caffeinate` or disable sleep
4. Create a LaunchDaemon to remount on wake

### Edge Service Not Finding Files

**Causes**:
1. Files in wrong directory
2. Files still being written (not stable)
3. Wrong file extensions

**Solutions**:
1. Files must be in the `ready/` subdirectory
2. Wait for `MIN_FILE_AGE_SECONDS` (60s default)
3. Supported extensions: .mp4, .mov, .mkv, .avi, .m4v

### AWS Fallback Not Working

**Causes**:
1. API URL misconfigured
2. API key incorrect
3. Network issues

**Solutions**:
1. Verify URL format: `https://xxx.execute-api.region.amazonaws.com/prod`
2. Test API key with curl directly
3. Check edge service logs: `docker compose logs -f`

---

## FAQ

### Q: Can I use this with cameras other than the one that created the corrupted files?

**A**: Generally no. untrunc needs a reference file from the **same camera/software** with the **same settings**. Different cameras use different codecs, frame rates, and atom structures.

### Q: What video formats are supported?

**A**: MP4, MOV, MKV, AVI, and M4V containers. The actual codec support depends on FFmpeg (H.264, H.265/HEVC, ProRes, etc. are all supported).

### Q: How do I know which file to use as a reference?

**A**: Use any **complete, playable** video file from the same camera with the same settings. The pipeline defaults to using the **smallest** file, assuming it's most likely to be complete.

### Q: Can I process files larger than 200GB?

**A**: Not in a single batch job (Fargate ephemeral storage limit). For very large files:
1. Process one file at a time
2. Use EC2 instead of Fargate (requires code changes)
3. Use the edge service on a machine with enough local storage

### Q: Is my video data secure?

**A**: Yes. All data is encrypted at rest (S3) and in transit (HTTPS/TLS). Access is controlled via IAM and API keys. However, for highly sensitive content, review the security settings and consider using KMS encryption.

### Q: Can I run multiple batch jobs simultaneously?

**A**: Yes. AWS Batch manages a queue and runs jobs based on compute capacity. The default `batch_max_vcpus` is 16, allowing multiple concurrent jobs.

### Q: What happens if the repair fails?

**A**: 
- Batch: Failed files are logged, webhook shows failures, original files remain in raw bucket
- Edge: Files are moved to `quarantine/` directory, AWS fallback is attempted

### Q: Can I customize the untrunc options?

**A**: Yes, but you'll need to modify the shell script (`run_untrunc.sh`) or Python runner. Current options: `-n -s -dst`

---

## Development and Testing

### Running the Validation Script

```bash
./validate.sh
```

This checks:
- Required tools installed
- untrunc binaries present
- Terraform configuration valid
- Python syntax valid
- Shell script syntax valid

### Testing Locally (Edge Service)

```bash
cd edge-service

# Build without Docker Compose
docker build -t untrunc-edge:test .

# Run with local directory instead of SMB
docker run -it --rm \
  -v /tmp/test-videos:/data \
  -e READY_DIR=ready \
  -e EXPORT_DIR=export \
  -e QUARANTINE_DIR=quarantine \
  -p 8080:8080 \
  untrunc-edge:test
```

### Testing Lambda Locally

```bash
cd batch-pipeline/lambda

# Install dependencies
pip install boto3

# Test with mock event
python -c "
import lambda_function
event = {
    'headers': {'x-api-key': 'test'},
    'body': '{\"input_prefix\": \"test\"}'
}
print(lambda_function.lambda_handler(event, None))
"
```

### Integration Testing

1. Deploy to a staging environment
2. Upload test files to S3
3. Submit a job
4. Verify output files
5. Check webhook notification

---

## Changelog

### v1.0.0 (December 2025)

- Initial production release
- AWS Batch pipeline with Fargate Spot
- Edge service for local Mac processing
- Auto-scaling based on file sizes
- Webhook notifications
- Security hardening (encryption, auth, least privilege)
- Verified untrunc CLI syntax

---

## License

MIT License

Copyright (c) 2025 Jeremiah Kroesche | Halfservers LLC

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

---

## Support

For issues and feature requests, please create an issue in the repository.

For commercial support or custom development, contact: **Halfservers LLC**
