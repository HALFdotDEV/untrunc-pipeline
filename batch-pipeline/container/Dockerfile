################################################################################
# Untrunc Batch Job Container
#
# This container runs video repair jobs in AWS Batch.
# 
# Build for x86_64:
#   docker build --platform linux/amd64 -t untrunc:latest .
#
# Build for ARM64:
#   docker build --platform linux/arm64 -t untrunc:latest .
#
# Push to ECR:
#   aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin <account>.dkr.ecr.us-east-1.amazonaws.com
#   docker tag untrunc:latest <account>.dkr.ecr.us-east-1.amazonaws.com/untrunc:latest
#   docker push <account>.dkr.ecr.us-east-1.amazonaws.com/untrunc:latest
################################################################################

FROM debian:bookworm-slim

# Install dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    unzip \
    jq \
    ffmpeg \
    libavcodec-dev \
    libavformat-dev \
    libavutil-dev \
    && rm -rf /var/lib/apt/lists/*

# Install AWS CLI v2
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then \
        curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"; \
    elif [ "$ARCH" = "aarch64" ]; then \
        curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "/tmp/awscliv2.zip"; \
    fi && \
    unzip -q /tmp/awscliv2.zip -d /tmp && \
    /tmp/aws/install && \
    rm -rf /tmp/aws /tmp/awscliv2.zip

# Create app directory
WORKDIR /app

# Copy the untrunc binary
# You need to compile untrunc for your target architecture and place it in the build context
# See: https://github.com/anthwlock/untrunc
#
# For x86_64 Linux:
#   git clone https://github.com/anthwlock/untrunc.git
#   cd untrunc
#   make FF_VER=6.0
#   cp untrunc ../container/bin/untrunc-linux-amd64
#
# For ARM64 Linux:
#   (build on ARM64 machine or cross-compile)
#   cp untrunc ../container/bin/untrunc-linux-arm64
#
# The Dockerfile will select the correct binary based on architecture

COPY bin/untrunc-linux-* /tmp/
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ] && [ -f /tmp/untrunc-linux-amd64 ]; then \
        mv /tmp/untrunc-linux-amd64 /usr/local/bin/untrunc; \
    elif [ "$ARCH" = "aarch64" ] && [ -f /tmp/untrunc-linux-arm64 ]; then \
        mv /tmp/untrunc-linux-arm64 /usr/local/bin/untrunc; \
    elif [ -f /tmp/untrunc-linux-amd64 ]; then \
        mv /tmp/untrunc-linux-amd64 /usr/local/bin/untrunc; \
    else \
        echo "ERROR: No untrunc binary found for architecture $ARCH" && exit 1; \
    fi && \
    chmod +x /usr/local/bin/untrunc && \
    rm -f /tmp/untrunc-linux-*

# Copy the run script
COPY run_untrunc.sh /app/run_untrunc.sh
RUN chmod +x /app/run_untrunc.sh

# Verify installation
RUN untrunc 2>&1 | head -5 || true
RUN aws --version

# Run the repair script
ENTRYPOINT ["/app/run_untrunc.sh"]
