#!/usr/bin/env bash
################################################################################
# Untrunc Batch Repair Script
# 
# Author: Jeremiah Kroesche | Halfservers LLC
#
# This script runs inside the AWS Batch container and:
# 1. Downloads the reference file from S3
# 2. Downloads each file to repair
# 3. Runs untrunc using the reference file
# 4. Uploads repaired files to S3
# 5. Sends SNS notification with results
#
# untrunc CLI syntax (anthwlock/untrunc):
#   untrunc [options] <reference.mp4> <corrupted.mp4>
#   Output: creates <corrupted>_fixed.mp4 in same directory
#   Use -dst <path> to set custom output destination
#
# Options used:
#   -n    : non-interactive mode (no prompts)
#   -s    : step through unknown sequences (improves recovery)
#   -dst  : set output destination file
#   -q    : quiet mode (only errors)
################################################################################

set -euo pipefail

# Required environment variables
: "${INPUT_BUCKET:?INPUT_BUCKET is required}"
: "${INPUT_PREFIX:?INPUT_PREFIX is required}"
: "${OUTPUT_BUCKET:?OUTPUT_BUCKET is required}"
: "${OUTPUT_PREFIX:?OUTPUT_PREFIX is required}"
: "${REFERENCE_KEY:?REFERENCE_KEY is required}"
: "${FILES_TO_REPAIR:?FILES_TO_REPAIR is required}"
: "${JOB_ID:?JOB_ID is required}"
: "${SNS_TOPIC_ARN:?SNS_TOPIC_ARN is required}"
: "${AWS_REGION:?AWS_REGION is required}"

# Configuration
WORKDIR="/tmp/untrunc-work"
REFERENCE_FILE="${WORKDIR}/reference.mp4"
MIN_DISK_SPACE_MB=500  # Minimum free space required

# Counters for results
TOTAL_FILES=0
SUCCESS_COUNT=0
FAILURE_COUNT=0
declare -a FAILED_FILES=()
declare -a SUCCESS_FILES=()

# Logging helper
log() {
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $*"
}

log_json() {
    local level="$1"
    local message="$2"
    shift 2
    # Simple JSON logging for CloudWatch
    printf '{"timestamp":"%s","level":"%s","job_id":"%s","message":"%s"' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$level" "$JOB_ID" "$message"
    while [[ $# -gt 0 ]]; do
        printf ',"%s":"%s"' "$1" "$2"
        shift 2
    done
    printf '}\n'
}

# Check available disk space
check_disk_space() {
    local path="$1"
    local required_mb="${2:-$MIN_DISK_SPACE_MB}"
    
    local available_kb
    available_kb=$(df -k "$path" | tail -1 | awk '{print $4}')
    local available_mb=$((available_kb / 1024))
    
    if [[ $available_mb -lt $required_mb ]]; then
        log_json "WARN" "Low disk space" "available_mb" "$available_mb" "required_mb" "$required_mb"
        return 1
    fi
    return 0
}

# Cleanup on exit
cleanup() {
    log "Cleaning up work directory..."
    rm -rf "${WORKDIR}"
}
trap cleanup EXIT

# Send SNS notification
send_notification() {
    local status="$1"
    local message="$2"
    
    local payload
    payload=$(cat <<EOF
{
    "job_id": "${JOB_ID}",
    "status": "${status}",
    "message": "${message}",
    "input_bucket": "${INPUT_BUCKET}",
    "input_prefix": "${INPUT_PREFIX}",
    "output_bucket": "${OUTPUT_BUCKET}",
    "output_prefix": "${OUTPUT_PREFIX}",
    "reference_file": "${REFERENCE_KEY}",
    "total_files": ${TOTAL_FILES},
    "success_count": ${SUCCESS_COUNT},
    "failure_count": ${FAILURE_COUNT},
    "failed_files": $(printf '%s\n' "${FAILED_FILES[@]:-}" | jq -R -s -c 'split("\n") | map(select(length > 0))'),
    "success_files": $(printf '%s\n' "${SUCCESS_FILES[@]:-}" | jq -R -s -c 'split("\n") | map(select(length > 0))'),
    "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
EOF
)

    log "Sending SNS notification: status=${status}"
    aws sns publish \
        --region "${AWS_REGION}" \
        --topic-arn "${SNS_TOPIC_ARN}" \
        --message "${payload}" \
        --subject "Untrunc Job ${status}: ${JOB_ID}" \
        || log "WARNING: Failed to send SNS notification"
}

# Main repair function for a single file
repair_file() {
    local input_key="$1"
    local filename
    filename=$(basename "$input_key")
    
    local input_file="${WORKDIR}/input/${filename}"
    local output_file="${WORKDIR}/output/${filename}"
    
    # Derive output key - replace input prefix with output prefix
    local relative_path="${input_key#"$INPUT_PREFIX"}"
    relative_path="${relative_path#/}"
    local output_key="${OUTPUT_PREFIX}/${relative_path}"
    output_key="${output_key#/}"  # Remove leading slash if present

    log_json "INFO" "Starting repair" "file" "$input_key"
    
    # Check disk space before download
    if ! check_disk_space "$WORKDIR" "$MIN_DISK_SPACE_MB"; then
        log_json "ERROR" "Insufficient disk space" "file" "$input_key"
        return 1
    fi
    
    # Create directories
    mkdir -p "$(dirname "$input_file")" "$(dirname "$output_file")"
    
    # Download input file
    log "Downloading s3://${INPUT_BUCKET}/${input_key}..."
    if ! aws s3 cp "s3://${INPUT_BUCKET}/${input_key}" "$input_file" --quiet; then
        log_json "ERROR" "Failed to download input file" "file" "$input_key"
        return 1
    fi
    
    local input_size
    input_size=$(stat -c %s "$input_file" 2>/dev/null || stat -f %z "$input_file" 2>/dev/null || echo "0")
    log "Downloaded ${filename}: ${input_size} bytes"
    
    # Run untrunc with verified CLI syntax
    # Syntax: untrunc [options] <reference.mp4> <corrupted.mp4>
    # -n   : non-interactive (don't prompt for confirmation)
    # -s   : step through unknown sequences (improves recovery)
    # -dst : set output destination file path
    log "Running untrunc on ${filename}..."
    local untrunc_output
    local untrunc_exit=0
    untrunc_output=$(untrunc -n -s -dst "$output_file" "$REFERENCE_FILE" "$input_file" 2>&1) || untrunc_exit=$?
    
    if [[ $untrunc_exit -ne 0 ]]; then
        log_json "ERROR" "untrunc failed" "file" "$input_key" "exit_code" "$untrunc_exit"
        log "untrunc output: ${untrunc_output:0:1000}"
        rm -f "$input_file" "$output_file"
        return 1
    fi
    log "untrunc completed successfully"
    
    # Verify output exists and has reasonable size
    # untrunc with -dst should create the file at our specified path
    # If not, check for auto-generated _fixed file as fallback
    if [[ ! -f "$output_file" ]]; then
        local base="${input_file%.*}"
        local ext="${input_file##*.}"
        local auto_output="${base}_fixed.${ext}"
        
        if [[ -f "$auto_output" ]]; then
            log "Found auto-generated output: $auto_output, moving to $output_file"
            mv "$auto_output" "$output_file"
        else
            log_json "ERROR" "Output file not created" "file" "$input_key"
            log "untrunc output was: ${untrunc_output:0:500}"
            rm -f "$input_file"
            return 1
        fi
    fi
    
    local output_size
    output_size=$(stat -c %s "$output_file" 2>/dev/null || stat -f %z "$output_file" 2>/dev/null || echo "0")
    
    # Verify output size (must be at least 1KB and reasonably sized)
    if [[ "$output_size" -lt 1024 ]]; then
        log_json "ERROR" "Output file too small" "file" "$input_key" "size" "$output_size"
        rm -f "$input_file" "$output_file"
        return 1
    fi
    
    log "Repaired file size: ${output_size} bytes (input was ${input_size} bytes)"
    
    # Upload repaired file
    log "Uploading to s3://${OUTPUT_BUCKET}/${output_key}..."
    if ! aws s3 cp "$output_file" "s3://${OUTPUT_BUCKET}/${output_key}" --quiet; then
        log_json "ERROR" "Failed to upload output file" "file" "$output_key"
        rm -f "$input_file" "$output_file"
        return 1
    fi
    
    # Cleanup input/output files to free space for next file
    rm -f "$input_file" "$output_file"
    
    log_json "INFO" "Repair successful" "file" "$input_key" "output" "$output_key" "size" "$output_size"
    return 0
}

# Main execution
main() {
    log "=========================================="
    log "Untrunc Batch Repair Job: ${JOB_ID}"
    log "=========================================="
    
    # Check untrunc is available and get version
    if ! command -v untrunc &>/dev/null; then
        log_json "ERROR" "untrunc binary not found"
        send_notification "FAILED" "untrunc binary not found in container"
        exit 1
    fi
    
    local untrunc_version
    untrunc_version=$(untrunc -V 2>&1 | head -1 || echo "unknown")
    log "Untrunc version: ${untrunc_version}"
    
    # Log configuration
    log "Input:  s3://${INPUT_BUCKET}/${INPUT_PREFIX}"
    log "Output: s3://${OUTPUT_BUCKET}/${OUTPUT_PREFIX}"
    log "Reference: ${REFERENCE_KEY}"
    
    # Check initial disk space
    local disk_info
    disk_info=$(df -h /tmp | tail -1)
    log "Disk space: ${disk_info}"
    
    # Create work directories
    mkdir -p "${WORKDIR}/input" "${WORKDIR}/output"
    
    # Download reference file
    log "Downloading reference file: s3://${INPUT_BUCKET}/${REFERENCE_KEY}"
    if ! aws s3 cp "s3://${INPUT_BUCKET}/${REFERENCE_KEY}" "$REFERENCE_FILE" --quiet; then
        log_json "ERROR" "Failed to download reference file" "file" "$REFERENCE_KEY"
        send_notification "FAILED" "Failed to download reference file"
        exit 1
    fi
    
    local ref_size
    ref_size=$(stat -c %s "$REFERENCE_FILE" 2>/dev/null || stat -f %z "$REFERENCE_FILE" 2>/dev/null || echo "0")
    log "Reference file downloaded: ${ref_size} bytes"
    
    # Verify reference file is a valid video (basic check)
    if [[ $ref_size -lt 1024 ]]; then
        log_json "ERROR" "Reference file too small - may not be valid" "size" "$ref_size"
        send_notification "FAILED" "Reference file too small (${ref_size} bytes)"
        exit 1
    fi
    
    # Parse files to repair from JSON array
    local files
    files=$(echo "$FILES_TO_REPAIR" | jq -r '.[]')
    
    if [[ -z "$files" ]]; then
        log_json "ERROR" "No files to repair"
        send_notification "FAILED" "No files to repair in job manifest"
        exit 1
    fi
    
    # Count total files
    TOTAL_FILES=$(echo "$files" | wc -l)
    log "Files to repair: ${TOTAL_FILES}"
    log "=========================================="
    
    # Process each file
    local file_num=0
    while IFS= read -r input_key; do
        file_num=$((file_num + 1))
        log ""
        log "[${file_num}/${TOTAL_FILES}] Processing: ${input_key}"
        
        if repair_file "$input_key"; then
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
            SUCCESS_FILES+=("$input_key")
        else
            FAILURE_COUNT=$((FAILURE_COUNT + 1))
            FAILED_FILES+=("$input_key")
        fi
        
        # Log progress
        log "Progress: ${SUCCESS_COUNT} succeeded, ${FAILURE_COUNT} failed"
        
    done <<< "$files"
    
    # Summary
    log ""
    log "=========================================="
    log "JOB COMPLETE"
    log "=========================================="
    log "Total files:  ${TOTAL_FILES}"
    log "Successful:   ${SUCCESS_COUNT}"
    log "Failed:       ${FAILURE_COUNT}"
    
    if [[ ${#FAILED_FILES[@]} -gt 0 ]]; then
        log ""
        log "Failed files:"
        for f in "${FAILED_FILES[@]}"; do
            log "  - $f"
        done
    fi
    
    # Final disk space check
    disk_info=$(df -h /tmp | tail -1)
    log "Final disk space: ${disk_info}"
    
    # Send completion notification
    if [[ $FAILURE_COUNT -eq 0 ]]; then
        send_notification "COMPLETED" "All ${TOTAL_FILES} files repaired successfully"
    elif [[ $SUCCESS_COUNT -eq 0 ]]; then
        send_notification "FAILED" "All ${TOTAL_FILES} files failed to repair"
        exit 1
    else
        send_notification "PARTIAL" "${SUCCESS_COUNT}/${TOTAL_FILES} files repaired, ${FAILURE_COUNT} failed"
        # Exit with error if any files failed
        exit 1
    fi
}

main "$@"
