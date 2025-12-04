#!/usr/bin/env bash
################################################################################
# Untrunc Pipeline Validation Script
#
# Run this script to validate your setup before deploying to production.
#
# Usage:
#   ./validate.sh [--skip-aws] [--skip-docker]
#
# Requirements:
#   - Docker (for building containers)
#   - AWS CLI (for testing S3 and Batch)
#   - Terraform (for validating configuration)
#   - jq (for JSON parsing)
################################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

SKIP_AWS=false
SKIP_DOCKER=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-aws) SKIP_AWS=true; shift ;;
        --skip-docker) SKIP_DOCKER=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

pass() { echo -e "${GREEN}✓${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
info() { echo -e "  $1"; }

ERRORS=0

echo "========================================"
echo "Untrunc Pipeline Validation"
echo "========================================"
echo ""

# -----------------------------------------------------------------------------
# Check prerequisites
# -----------------------------------------------------------------------------
echo "Checking prerequisites..."

if command -v docker &> /dev/null; then
    pass "Docker installed: $(docker --version | head -1)"
else
    fail "Docker not installed"
    ERRORS=$((ERRORS + 1))
fi

if command -v terraform &> /dev/null; then
    pass "Terraform installed: $(terraform --version | head -1)"
else
    fail "Terraform not installed"
    ERRORS=$((ERRORS + 1))
fi

if command -v jq &> /dev/null; then
    pass "jq installed: $(jq --version)"
else
    warn "jq not installed (recommended for JSON parsing)"
fi

if ! $SKIP_AWS; then
    if command -v aws &> /dev/null; then
        pass "AWS CLI installed: $(aws --version 2>&1 | head -1)"
        
        # Check AWS credentials
        if aws sts get-caller-identity &> /dev/null; then
            ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
            pass "AWS credentials valid (account: $ACCOUNT_ID)"
        else
            fail "AWS credentials not configured or invalid"
            ERRORS=$((ERRORS + 1))
        fi
    else
        fail "AWS CLI not installed"
        ERRORS=$((ERRORS + 1))
    fi
fi

echo ""

# -----------------------------------------------------------------------------
# Check untrunc binaries
# -----------------------------------------------------------------------------
echo "Checking untrunc binaries..."

BATCH_BIN="${SCRIPT_DIR}/batch-pipeline/container/bin/untrunc-linux-amd64"
EDGE_BIN="${SCRIPT_DIR}/edge-service/bin/untrunc-arm64"

if [[ -f "$BATCH_BIN" ]]; then
    pass "Batch binary exists: $BATCH_BIN"
    if [[ -x "$BATCH_BIN" ]]; then
        pass "Batch binary is executable"
    else
        warn "Batch binary is not executable (run: chmod +x $BATCH_BIN)"
    fi
else
    fail "Batch binary missing: $BATCH_BIN"
    info "Run: ./build-untrunc.sh to build binaries"
    ERRORS=$((ERRORS + 1))
fi

if [[ -f "$EDGE_BIN" ]]; then
    pass "Edge binary exists: $EDGE_BIN"
    if [[ -x "$EDGE_BIN" ]]; then
        pass "Edge binary is executable"
    else
        warn "Edge binary is not executable (run: chmod +x $EDGE_BIN)"
    fi
else
    fail "Edge binary missing: $EDGE_BIN"
    info "Run: ./build-untrunc.sh to build binaries"
    ERRORS=$((ERRORS + 1))
fi

echo ""

# -----------------------------------------------------------------------------
# Validate Terraform configuration
# -----------------------------------------------------------------------------
echo "Validating Terraform configuration..."

cd "${SCRIPT_DIR}/batch-pipeline"

if [[ -f "terraform.tfvars" ]]; then
    pass "terraform.tfvars exists"
else
    warn "terraform.tfvars not found - copy from terraform.tfvars.example"
fi

# Initialize Terraform (download providers)
if terraform init -backend=false > /dev/null 2>&1; then
    pass "Terraform init successful"
    
    # Validate configuration
    if terraform validate > /dev/null 2>&1; then
        pass "Terraform configuration valid"
    else
        fail "Terraform validation failed"
        terraform validate
        ERRORS=$((ERRORS + 1))
    fi
else
    fail "Terraform init failed"
    ERRORS=$((ERRORS + 1))
fi

cd "$SCRIPT_DIR"
echo ""

# -----------------------------------------------------------------------------
# Validate Docker builds
# -----------------------------------------------------------------------------
if ! $SKIP_DOCKER; then
    echo "Validating Docker builds..."
    
    # Test batch container build (without actually building - just validate Dockerfile)
    if docker build --file "${SCRIPT_DIR}/batch-pipeline/container/Dockerfile" \
        --target=syntax-check "${SCRIPT_DIR}/batch-pipeline/container" 2>/dev/null || \
        docker build --file "${SCRIPT_DIR}/batch-pipeline/container/Dockerfile" \
        --check "${SCRIPT_DIR}/batch-pipeline/container" 2>/dev/null; then
        pass "Batch Dockerfile syntax valid"
    else
        # Fallback: just check if file exists and has FROM
        if grep -q "^FROM" "${SCRIPT_DIR}/batch-pipeline/container/Dockerfile"; then
            pass "Batch Dockerfile exists and has FROM instruction"
        else
            fail "Batch Dockerfile invalid"
            ERRORS=$((ERRORS + 1))
        fi
    fi
    
    # Test edge container build
    if grep -q "^FROM" "${SCRIPT_DIR}/edge-service/Dockerfile"; then
        pass "Edge Dockerfile exists and has FROM instruction"
    else
        fail "Edge Dockerfile invalid"
        ERRORS=$((ERRORS + 1))
    fi
    
    echo ""
fi

# -----------------------------------------------------------------------------
# Validate Python code (edge service)
# -----------------------------------------------------------------------------
echo "Validating Python code..."

if command -v python3 &> /dev/null; then
    PYTHON=python3
elif command -v python &> /dev/null; then
    PYTHON=python
else
    warn "Python not found - skipping syntax check"
    PYTHON=""
fi

if [[ -n "$PYTHON" ]]; then
    PYTHON_ERRORS=0
    
    for pyfile in "${SCRIPT_DIR}"/edge-service/app/*.py; do
        if $PYTHON -m py_compile "$pyfile" 2>/dev/null; then
            pass "Valid: $(basename "$pyfile")"
        else
            fail "Syntax error: $(basename "$pyfile")"
            PYTHON_ERRORS=$((PYTHON_ERRORS + 1))
        fi
    done
    
    # Check Lambda function
    if $PYTHON -m py_compile "${SCRIPT_DIR}/batch-pipeline/lambda/lambda_function.py" 2>/dev/null; then
        pass "Valid: lambda_function.py"
    else
        fail "Syntax error: lambda_function.py"
        PYTHON_ERRORS=$((PYTHON_ERRORS + 1))
    fi
    
    ERRORS=$((ERRORS + PYTHON_ERRORS))
fi

echo ""

# -----------------------------------------------------------------------------
# Validate shell scripts
# -----------------------------------------------------------------------------
echo "Validating shell scripts..."

if command -v shellcheck &> /dev/null; then
    if shellcheck "${SCRIPT_DIR}/batch-pipeline/container/run_untrunc.sh" 2>/dev/null; then
        pass "run_untrunc.sh passes shellcheck"
    else
        warn "run_untrunc.sh has shellcheck warnings (non-fatal)"
    fi
else
    if bash -n "${SCRIPT_DIR}/batch-pipeline/container/run_untrunc.sh" 2>/dev/null; then
        pass "run_untrunc.sh has valid bash syntax"
    else
        fail "run_untrunc.sh has syntax errors"
        ERRORS=$((ERRORS + 1))
    fi
fi

echo ""

# -----------------------------------------------------------------------------
# Check configuration files
# -----------------------------------------------------------------------------
echo "Checking configuration files..."

if [[ -f "${SCRIPT_DIR}/edge-service/.env.example" ]]; then
    pass "Edge .env.example exists"
else
    fail "Edge .env.example missing"
    ERRORS=$((ERRORS + 1))
fi

if [[ -f "${SCRIPT_DIR}/batch-pipeline/terraform.tfvars.example" ]]; then
    pass "Terraform tfvars.example exists"
else
    fail "Terraform tfvars.example missing"
    ERRORS=$((ERRORS + 1))
fi

echo ""

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo "========================================"
echo "Validation Summary"
echo "========================================"

if [[ $ERRORS -eq 0 ]]; then
    echo -e "${GREEN}All checks passed!${NC}"
    echo ""
    echo "Next steps:"
    echo "  1. Build untrunc binaries (if not done):"
    echo "     ./build-untrunc.sh"
    echo ""
    echo "  2. Configure and deploy AWS infrastructure:"
    echo "     cd batch-pipeline"
    echo "     cp terraform.tfvars.example terraform.tfvars"
    echo "     # Edit terraform.tfvars"
    echo "     terraform apply"
    echo ""
    echo "  3. Build and push batch container to ECR"
    echo ""
    echo "  4. Deploy edge service:"
    echo "     cd edge-service"
    echo "     cp .env.example .env"
    echo "     # Edit .env"
    echo "     docker compose up -d --build"
    exit 0
else
    echo -e "${RED}$ERRORS error(s) found${NC}"
    echo ""
    echo "Please fix the errors above before deploying."
    exit 1
fi
