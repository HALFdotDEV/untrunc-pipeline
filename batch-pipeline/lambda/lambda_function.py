"""
Lambda function to submit untrunc batch repair jobs.

Features:
- API key authentication
- Lists files in S3 prefix to build job manifest
- Auto-selects reference file (smallest or newest .mp4 in prefix)
- Dynamic resource scaling based on total file size
- Input validation and security hardening
- Submits AWS Batch job with appropriate resource overrides

untrunc requires a working reference video from the same camera to repair corrupted files.
The reference file is auto-selected as the smallest file (likely a complete, working clip).
"""

import hashlib
import json
import logging
import math
import os
import re
import uuid
from typing import Optional

import boto3
from botocore.exceptions import ClientError

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Clients
batch = boto3.client("batch")
s3 = boto3.client("s3")

# Environment variables
JOB_QUEUE_ARN = os.environ["BATCH_JOB_QUEUE_ARN"]
JOB_DEFINITION_ARN = os.environ["BATCH_JOB_DEFINITION_ARN"]
DEFAULT_INPUT_BUCKET = os.environ["DEFAULT_INPUT_BUCKET"]
DEFAULT_OUTPUT_BUCKET = os.environ["DEFAULT_OUTPUT_BUCKET"]
API_KEY_HASH = os.environ.get("API_KEY_HASH", "")

# Validation patterns
BUCKET_PATTERN = re.compile(r"^[a-z0-9][a-z0-9.\-]{1,61}[a-z0-9]$")
KEY_PATTERN = re.compile(r"^[\w\-./]+$")
VIDEO_EXTENSIONS = {".mp4", ".mov", ".mkv", ".avi", ".m4v"}

# Resource scaling thresholds
# These define how resources scale based on total batch size
# Video repair needs:
#   - Memory: ~2x largest file size (reference + working buffers)
#   - Storage: ~3x largest file (input + reference + output)
#   - vCPU: Mostly single-threaded, but more for parallelism
RESOURCE_TIERS = [
    # (max_total_gb, vcpu, memory_mb, storage_gb)
    (5,    1,  2048,   30),   # Small: up to 5GB total
    (20,   2,  4096,   60),   # Medium: up to 20GB total
    (50,   4,  8192,  120),   # Large: up to 50GB total
    (100,  4, 16384,  175),   # XL: up to 100GB total
    (200,  8, 30720,  200),   # XXL: up to 200GB total (max storage)
]

# Fargate valid vCPU/memory combinations
# https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-cpu-memory-error.html
FARGATE_VALID_COMBOS = {
    0.25: [512, 1024, 2048],
    0.5: [1024, 2048, 3072, 4096],
    1: [2048, 3072, 4096, 5120, 6144, 7168, 8192],
    2: [4096, 5120, 6144, 7168, 8192, 9216, 10240, 11264, 12288, 13312, 14336, 15360, 16384],
    4: list(range(8192, 30721, 1024)),
    8: list(range(16384, 61441, 4096)),
    16: list(range(32768, 122881, 8192)),
}


def validate_api_key(event: dict) -> bool:
    """Validate the API key from the X-Api-Key header."""
    if not API_KEY_HASH:
        logger.warning("API_KEY_HASH not configured - authentication disabled")
        return True

    headers = event.get("headers", {}) or {}
    # Headers are lowercased by API Gateway
    api_key = headers.get("x-api-key", "")

    if not api_key:
        return False

    provided_hash = hashlib.sha256(api_key.encode()).hexdigest()
    return provided_hash == API_KEY_HASH


def validate_s3_path(bucket: str, key: str) -> bool:
    """Validate S3 bucket and key format to prevent injection."""
    if not bucket or not BUCKET_PATTERN.match(bucket):
        return False
    if key and not KEY_PATTERN.match(key):
        return False
    if ".." in key:
        return False
    return True


def is_video_file(key: str) -> bool:
    """Check if the S3 key is a video file."""
    lower_key = key.lower()
    return any(lower_key.endswith(ext) for ext in VIDEO_EXTENSIONS)


def list_video_files(bucket: str, prefix: str) -> list[dict]:
    """
    List all video files under the given S3 prefix.
    Returns list of dicts with 'key', 'size', 'last_modified'.
    """
    files = []
    paginator = s3.get_paginator("list_objects_v2")

    try:
        for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
            for obj in page.get("Contents", []):
                key = obj["Key"]
                if is_video_file(key):
                    files.append({
                        "key": key,
                        "size": obj["Size"],
                        "last_modified": obj["LastModified"].isoformat(),
                    })
    except ClientError as e:
        logger.error(f"Failed to list S3 objects: {e}")
        raise

    return files


def select_reference_file(
    files: list[dict],
    strategy: str = "smallest",
    explicit_ref: Optional[str] = None
) -> Optional[str]:
    """
    Select the reference file from the list of video files.

    The reference file must be a WORKING video that untrunc can use
    to understand the codec parameters. By default, we pick the smallest
    file, assuming it's most likely to be a complete, working clip.

    Strategies:
    - 'smallest': Use the smallest file (most likely to be a working clip)
    - 'newest': Use the most recently modified file
    - 'explicit': Use the explicitly provided reference key

    Returns the S3 key of the reference file, or None if no suitable file found.
    """
    if explicit_ref:
        # Verify the explicit reference exists in our file list
        if any(f["key"] == explicit_ref for f in files):
            return explicit_ref
        logger.warning(f"Explicit reference {explicit_ref} not found in file list")

    if not files:
        return None

    if strategy == "smallest":
        # Sort by size ascending, pick smallest
        sorted_files = sorted(files, key=lambda f: f["size"])
        return sorted_files[0]["key"]

    elif strategy == "newest":
        # Sort by last_modified descending, pick newest
        sorted_files = sorted(files, key=lambda f: f["last_modified"], reverse=True)
        return sorted_files[0]["key"]

    else:
        # Default to smallest
        sorted_files = sorted(files, key=lambda f: f["size"])
        return sorted_files[0]["key"]


def calculate_resources(total_bytes: int, largest_file_bytes: int = 0) -> dict:
    """
    Calculate appropriate Batch job resources based on file sizes.
    
    Video repair considerations:
    - Memory: Need ~2x largest file for buffers during repair
    - Storage: Need space for input + reference + output files
    - Files are processed sequentially, so largest file is the bottleneck
    
    Args:
        total_bytes: Total size of all files to process
        largest_file_bytes: Size of the largest single file
    
    Returns dict with 'vcpu', 'memory', 'storage' values.
    """
    total_gb = total_bytes / (1024 ** 3)
    largest_gb = largest_file_bytes / (1024 ** 3) if largest_file_bytes else 0
    
    # Find appropriate tier based on total size
    tier_vcpu, tier_memory, tier_storage = 8, 30720, 200  # defaults
    for max_gb, vcpu, memory, storage in RESOURCE_TIERS:
        if total_gb <= max_gb:
            tier_vcpu = vcpu
            tier_memory = memory
            tier_storage = storage
            break
    
    # Ensure memory is sufficient for largest file (2x rule of thumb)
    min_memory_for_largest = int(largest_gb * 2 * 1024)  # Convert GB to MB
    final_memory = max(tier_memory, min_memory_for_largest)
    
    # Ensure storage can hold at least: reference + 2 * largest file (input + output)
    min_storage_for_largest = int(largest_gb * 3) + 10  # +10GB buffer
    final_storage = max(tier_storage, min_storage_for_largest)
    
    # Cap at Fargate limits
    final_memory = min(final_memory, 122880)  # 120GB max for 16 vCPU
    final_storage = min(final_storage, 200)   # 200GB max ephemeral
    
    return {
        "vcpu": tier_vcpu,
        "memory": final_memory,
        "storage": final_storage,
    }


def validate_fargate_resources(vcpu: int, memory: int) -> tuple[int, int]:
    """
    Ensure vCPU and memory are valid Fargate combinations.
    Returns adjusted (vcpu, memory) if needed.
    """
    # Find closest valid vCPU
    valid_vcpus = sorted(FARGATE_VALID_COMBOS.keys())
    selected_vcpu = vcpu
    for v in valid_vcpus:
        if v >= vcpu:
            selected_vcpu = v
            break
    else:
        selected_vcpu = valid_vcpus[-1]
    
    # Find closest valid memory for that vCPU
    valid_memories = FARGATE_VALID_COMBOS[selected_vcpu]
    selected_memory = memory
    for m in valid_memories:
        if m >= memory:
            selected_memory = m
            break
    else:
        selected_memory = valid_memories[-1]
    
    # Convert fractional vCPU to string format Batch expects
    if selected_vcpu < 1:
        vcpu_str = str(selected_vcpu)
    else:
        vcpu_str = str(int(selected_vcpu))
    
    return vcpu_str, selected_memory


def response(status_code: int, body: dict) -> dict:
    """Build API Gateway response."""
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
        },
        "body": json.dumps(body),
    }


def handle_health(event: dict) -> dict:
    """Handle GET /health requests."""
    return response(200, {
        "status": "healthy",
        "service": "untrunc-batch-api",
        "default_input_bucket": DEFAULT_INPUT_BUCKET,
        "default_output_bucket": DEFAULT_OUTPUT_BUCKET,
    })


def handle_submit_batch(event: dict) -> dict:
    """Handle POST /submit-batch requests."""
    # Parse request body
    try:
        body_str = event.get("body") or "{}"
        body = json.loads(body_str)
    except json.JSONDecodeError:
        return response(400, {"error": "Invalid JSON body"})

    # Extract parameters
    input_bucket = body.get("input_bucket") or DEFAULT_INPUT_BUCKET
    input_prefix = body.get("input_prefix", "").strip("/")
    output_bucket = body.get("output_bucket") or DEFAULT_OUTPUT_BUCKET
    output_prefix = body.get("output_prefix", "").strip("/")
    reference_strategy = body.get("reference_strategy", "smallest")
    explicit_reference = body.get("reference_key")
    
    # Optional resource overrides (for advanced users)
    force_vcpu = body.get("vcpu")
    force_memory = body.get("memory_mb")
    force_storage = body.get("storage_gb")

    # Validate required fields
    if not input_prefix:
        return response(400, {
            "error": "input_prefix is required",
            "hint": "Provide the S3 prefix containing video files to repair",
            "example": {"input_prefix": "session-2024-01-15/camera1"}
        })

    # Validate S3 paths
    if not validate_s3_path(input_bucket, input_prefix):
        return response(400, {"error": "Invalid input_bucket or input_prefix format"})

    if not validate_s3_path(output_bucket, output_prefix or "x"):
        return response(400, {"error": "Invalid output_bucket or output_prefix format"})

    # List video files in the prefix
    try:
        video_files = list_video_files(input_bucket, input_prefix)
    except Exception as e:
        logger.error(f"Failed to list video files: {e}")
        return response(500, {"error": f"Failed to list files in s3://{input_bucket}/{input_prefix}"})

    if not video_files:
        return response(400, {
            "error": "No video files found",
            "searched": f"s3://{input_bucket}/{input_prefix}",
            "supported_extensions": list(VIDEO_EXTENSIONS),
        })

    if len(video_files) < 2:
        return response(400, {
            "error": "Need at least 2 video files (1 working reference + 1 to repair)",
            "found": len(video_files),
            "hint": "Upload a known working video from the same camera to use as reference",
        })

    # Select reference file
    reference_key = select_reference_file(
        video_files,
        strategy=reference_strategy,
        explicit_ref=explicit_reference,
    )

    if not reference_key:
        return response(400, {"error": "Could not determine reference file"})

    # Files to repair = all files except reference
    files_to_repair = [f for f in video_files if f["key"] != reference_key]
    repair_keys = [f["key"] for f in files_to_repair]

    # Calculate total size for resource scaling
    total_size = sum(f["size"] for f in files_to_repair)
    reference_size = next(f["size"] for f in video_files if f["key"] == reference_key)
    largest_file_size = max(f["size"] for f in files_to_repair) if files_to_repair else 0
    
    # Calculate resources based on size (considers both total and largest file)
    auto_resources = calculate_resources(
        total_bytes=total_size + reference_size,
        largest_file_bytes=max(largest_file_size, reference_size)
    )
    
    # Apply any forced overrides
    vcpu = force_vcpu or auto_resources["vcpu"]
    memory = force_memory or auto_resources["memory"]
    storage = force_storage or auto_resources["storage"]
    
    # Validate Fargate resource combinations
    vcpu_str, memory_int = validate_fargate_resources(vcpu, memory)
    
    # Cap storage at 200GB (Fargate max)
    storage = min(storage, 200)

    # Generate job ID
    job_id = f"untrunc-{uuid.uuid4().hex[:12]}"

    # Use output_prefix if provided, otherwise mirror input structure
    if not output_prefix:
        output_prefix = input_prefix

    # Build container overrides with dynamic resources
    container_overrides = {
        "environment": [
            {"name": "INPUT_BUCKET", "value": input_bucket},
            {"name": "INPUT_PREFIX", "value": input_prefix},
            {"name": "OUTPUT_BUCKET", "value": output_bucket},
            {"name": "OUTPUT_PREFIX", "value": output_prefix},
            {"name": "REFERENCE_KEY", "value": reference_key},
            {"name": "FILES_TO_REPAIR", "value": json.dumps(repair_keys)},
            {"name": "JOB_ID", "value": job_id},
        ],
        "resourceRequirements": [
            {"type": "VCPU", "value": vcpu_str},
            {"type": "MEMORY", "value": str(memory_int)},
        ],
    }

    # Submit Batch job
    try:
        submit_params = {
            "jobName": job_id,
            "jobQueue": JOB_QUEUE_ARN,
            "jobDefinition": JOB_DEFINITION_ARN,
            "containerOverrides": container_overrides,
        }
        
        # Add ephemeral storage override if different from default
        # Note: This requires the job definition to support it
        if storage > 20:  # 20GB is the default
            submit_params["containerOverrides"]["ephemeralStorage"] = {
                "sizeInGiB": storage
            }
        
        resp = batch.submit_job(**submit_params)
        
    except Exception as e:
        logger.error(f"Failed to submit Batch job: {e}")
        return response(500, {"error": f"Failed to submit batch job: {str(e)}"})

    logger.info(
        f"Submitted job {job_id}: {len(files_to_repair)} files, "
        f"{total_size / (1024**3):.2f}GB total, "
        f"resources: {vcpu_str} vCPU, {memory_int}MB RAM, {storage}GB storage"
    )

    return response(202, {
        "message": "Batch repair job submitted",
        "job_id": job_id,
        "batch_job_id": resp["jobId"],
        "input_bucket": input_bucket,
        "input_prefix": input_prefix,
        "output_bucket": output_bucket,
        "output_prefix": output_prefix,
        "reference_file": reference_key,
        "reference_size_mb": round(reference_size / (1024**2), 2),
        "reference_strategy": reference_strategy,
        "files_to_repair": repair_keys,
        "file_count": len(repair_keys),
        "total_size_mb": round(total_size / (1024**2), 2),
        "largest_file_mb": round(largest_file_size / (1024**2), 2),
        "resources": {
            "vcpu": vcpu_str,
            "memory_mb": memory_int,
            "storage_gb": storage,
            "auto_scaled": not any([force_vcpu, force_memory, force_storage]),
        },
    })


def lambda_handler(event: dict, context) -> dict:
    """Main Lambda handler."""
    logger.info(f"Received event: {json.dumps(event)}")

    # Route based on path
    route_key = event.get("routeKey", "")
    request_context = event.get("requestContext", {})
    http = request_context.get("http", {})
    method = http.get("method", "")
    path = http.get("path", "")

    # Health check doesn't need auth
    if route_key == "GET /health" or (method == "GET" and "/health" in path):
        return handle_health(event)

    # All other routes require authentication
    if not validate_api_key(event):
        return response(401, {"error": "Unauthorized - invalid or missing API key"})

    if route_key == "POST /submit-batch" or (method == "POST" and "/submit-batch" in path):
        return handle_submit_batch(event)

    return response(404, {"error": "Not found"})
