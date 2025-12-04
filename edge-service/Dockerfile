################################################################################
# Edge Untrunc Repair Service
#
# Designed to run on Apple Silicon (M-series) MacBooks.
#
# Build:
#   docker build --platform linux/arm64 -t edge-untrunc:latest .
#
# Run:
#   docker compose up -d
################################################################################

FROM python:3.12-slim-bookworm

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Build tools (for some Python packages)
    build-essential \
    # FFmpeg libraries (required by untrunc)
    ffmpeg \
    libavcodec-dev \
    libavformat-dev \
    libavutil-dev \
    # Utilities
    curl \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user for security
RUN useradd --create-home --shell /bin/bash appuser

# Create app directory
WORKDIR /app

# Copy requirements first for better layer caching
COPY app/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

# Copy the untrunc binary
# You must compile untrunc for arm64 Linux and place it at bin/untrunc-arm64
# 
# Build instructions:
#   git clone https://github.com/anthwlock/untrunc.git
#   cd untrunc
#   # On an arm64 Linux machine or using Docker buildx:
#   make FF_VER=6.0
#   cp untrunc /path/to/edge-service/bin/untrunc-arm64
#
COPY bin/untrunc-arm64 /usr/local/bin/untrunc
RUN chmod +x /usr/local/bin/untrunc

# Copy application code
COPY app/ /app/

# Create data directories (will be overwritten by volume mounts)
RUN mkdir -p /data/ready /data/export /data/quarantine \
    && chown -R appuser:appuser /data /app

# Switch to non-root user
USER appuser

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

# Expose API port
EXPOSE 8080

# Run the service
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
