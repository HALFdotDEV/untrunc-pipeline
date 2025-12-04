#!/usr/bin/env bash
################################################################################
# Build untrunc binaries for the pipeline
#
# This script builds untrunc for both x86_64 (AWS Batch) and arm64 (Edge Mac).
#
# Prerequisites:
#   - Docker with buildx support
#   - Git
#
# Usage:
#   ./build-untrunc.sh
#
# Output:
#   - batch-pipeline/container/bin/untrunc-linux-amd64
#   - edge-service/bin/untrunc-arm64
################################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/.untrunc-build"

echo "========================================"
echo "Building untrunc binaries"
echo "========================================"

# Clone untrunc if not present
if [[ ! -d "${BUILD_DIR}/untrunc" ]]; then
    echo "Cloning untrunc repository..."
    mkdir -p "${BUILD_DIR}"
    git clone https://github.com/anthwlock/untrunc.git "${BUILD_DIR}/untrunc"
fi

cd "${BUILD_DIR}/untrunc"
git pull origin master || true

# Build for x86_64 (AWS Batch)
echo ""
echo "Building for x86_64 (AWS Batch)..."
echo "========================================"

docker buildx build --platform linux/amd64 -t untrunc-builder-amd64 -f - . <<'DOCKERFILE'
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y \
    build-essential \
    git \
    libavcodec-dev \
    libavformat-dev \
    libavutil-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /build
COPY . .
RUN make clean || true
RUN make FF_VER=6.0
DOCKERFILE

# Extract binary
docker create --name untrunc-extract-amd64 untrunc-builder-amd64
docker cp untrunc-extract-amd64:/build/untrunc "${SCRIPT_DIR}/batch-pipeline/container/bin/untrunc-linux-amd64"
docker rm untrunc-extract-amd64
chmod +x "${SCRIPT_DIR}/batch-pipeline/container/bin/untrunc-linux-amd64"

echo "✓ Built: batch-pipeline/container/bin/untrunc-linux-amd64"

# Build for arm64 (Edge Mac)
echo ""
echo "Building for arm64 (Edge Mac)..."
echo "========================================"

docker buildx build --platform linux/arm64 -t untrunc-builder-arm64 -f - . <<'DOCKERFILE'
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y \
    build-essential \
    git \
    libavcodec-dev \
    libavformat-dev \
    libavutil-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /build
COPY . .
RUN make clean || true
RUN make FF_VER=6.0
DOCKERFILE

# Extract binary
docker create --name untrunc-extract-arm64 untrunc-builder-arm64
docker cp untrunc-extract-arm64:/build/untrunc "${SCRIPT_DIR}/edge-service/bin/untrunc-arm64"
docker rm untrunc-extract-arm64
chmod +x "${SCRIPT_DIR}/edge-service/bin/untrunc-arm64"

echo "✓ Built: edge-service/bin/untrunc-arm64"

echo ""
echo "========================================"
echo "Build complete!"
echo "========================================"
echo ""
echo "Next steps:"
echo "  1. Deploy AWS Batch pipeline:"
echo "     cd batch-pipeline && terraform init && terraform apply"
echo ""
echo "  2. Build and push the batch container:"
echo "     cd batch-pipeline/container"
echo "     docker build --platform linux/amd64 -t untrunc:latest ."
echo "     docker tag untrunc:latest <ecr-uri>:latest"
echo "     docker push <ecr-uri>:latest"
echo ""
echo "  3. Deploy edge service:"
echo "     cd edge-service"
echo "     cp .env.example .env"
echo "     # Edit .env with your settings"
echo "     docker compose up -d --build"
