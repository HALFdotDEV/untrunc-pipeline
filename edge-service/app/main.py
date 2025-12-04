"""
Edge Untrunc Repair Service - FastAPI Application

HTTP API for health checks, manual repairs, and on-demand scanning.
Runs a background scanner that watches for new video files.
"""

import asyncio
import json
import logging
import sys
from contextlib import asynccontextmanager
from datetime import datetime
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from .config import settings
from .scanner import scanner
from .untrunc_runner import run_untrunc, UntruncRepairError


# ============================================================================
# Structured JSON Logging
# ============================================================================

class JSONFormatter(logging.Formatter):
    """JSON log formatter for structured logging."""

    def format(self, record: logging.LogRecord) -> str:
        log_obj = {
            "timestamp": datetime.utcnow().isoformat() + "Z",
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
        }

        # Add extra fields
        if hasattr(record, "__dict__"):
            for key, value in record.__dict__.items():
                if key not in {
                    "name", "msg", "args", "created", "filename",
                    "funcName", "levelname", "levelno", "lineno",
                    "module", "msecs", "pathname", "process",
                    "processName", "relativeCreated", "stack_info",
                    "exc_info", "exc_text", "thread", "threadName",
                    "taskName", "message",
                }:
                    log_obj[key] = value

        # Add exception info
        if record.exc_info:
            log_obj["exception"] = self.formatException(record.exc_info)

        return json.dumps(log_obj)


class TextFormatter(logging.Formatter):
    """Human-readable text formatter."""

    def __init__(self):
        super().__init__(
            fmt="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
            datefmt="%Y-%m-%d %H:%M:%S",
        )


def setup_logging():
    """Configure logging based on settings."""
    root_logger = logging.getLogger()
    root_logger.setLevel(getattr(logging, settings.log_level.upper(), logging.INFO))

    # Remove existing handlers
    for handler in root_logger.handlers[:]:
        root_logger.removeHandler(handler)

    # Add new handler
    handler = logging.StreamHandler(sys.stdout)

    if settings.log_format == "json":
        handler.setFormatter(JSONFormatter())
    else:
        handler.setFormatter(TextFormatter())

    root_logger.addHandler(handler)

    # Reduce noise from libraries
    logging.getLogger("httpx").setLevel(logging.WARNING)
    logging.getLogger("httpcore").setLevel(logging.WARNING)
    logging.getLogger("uvicorn.access").setLevel(logging.WARNING)


setup_logging()
logger = logging.getLogger(__name__)


# ============================================================================
# Application Lifecycle
# ============================================================================

@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifecycle manager."""
    # Startup
    logger.info(
        "Starting Edge Untrunc Service",
        extra={
            "ready_path": str(settings.ready_path),
            "export_path": str(settings.export_path),
            "quarantine_path": str(settings.quarantine_path),
            "scan_interval": settings.scan_interval_seconds,
            "reference_strategy": settings.reference_strategy,
        },
    )

    # Ensure directories exist
    settings.ready_path.mkdir(parents=True, exist_ok=True)
    settings.export_path.mkdir(parents=True, exist_ok=True)
    settings.quarantine_path.mkdir(parents=True, exist_ok=True)

    # Start background scanner
    scanner_task = asyncio.create_task(scanner.run_forever())

    yield

    # Shutdown
    logger.info("Shutting down Edge Untrunc Service")
    scanner.stop()
    scanner_task.cancel()
    try:
        await scanner_task
    except asyncio.CancelledError:
        pass


# ============================================================================
# FastAPI Application
# ============================================================================

app = FastAPI(
    title="Edge Untrunc Repair Service",
    description="Local video repair service with AWS fallback",
    version="1.0.0",
    lifespan=lifespan,
)


# ============================================================================
# Request/Response Models
# ============================================================================

class RepairRequest(BaseModel):
    """Request body for manual repair endpoint."""
    relative_path: str
    reference_path: Optional[str] = None
    invoke_aws_on_failure: bool = True


class RepairResponse(BaseModel):
    """Response for repair operations."""
    status: str
    source: Optional[str] = None
    output: Optional[str] = None
    reference: Optional[str] = None
    detail: Optional[str] = None


class HealthResponse(BaseModel):
    """Response for health check endpoint."""
    status: str
    service: str
    ready_path: str
    export_path: str
    quarantine_path: str
    scan_interval_seconds: int
    reference_strategy: str
    aws_fallback_enabled: bool


class ScanResponse(BaseModel):
    """Response for scan endpoint."""
    status: str
    scanned: int
    repaired: int
    failed: int
    reference: Optional[str] = None


# ============================================================================
# Exception Handlers
# ============================================================================

@app.exception_handler(Exception)
async def global_exception_handler(request: Request, exc: Exception):
    """Global exception handler for unhandled errors."""
    logger.exception("Unhandled exception", extra={"path": request.url.path})
    return JSONResponse(
        status_code=500,
        content={"error": "Internal server error", "detail": str(exc)},
    )


# ============================================================================
# API Endpoints
# ============================================================================

@app.get("/health", response_model=HealthResponse)
async def health():
    """Health check endpoint."""
    return HealthResponse(
        status="healthy",
        service=settings.service_name,
        ready_path=str(settings.ready_path),
        export_path=str(settings.export_path),
        quarantine_path=str(settings.quarantine_path),
        scan_interval_seconds=settings.scan_interval_seconds,
        reference_strategy=settings.reference_strategy,
        aws_fallback_enabled=bool(settings.aws_repair_api_base_url),
    )


@app.post("/scan-now", response_model=ScanResponse)
async def scan_now():
    """Trigger an immediate scan of the ready directory."""
    logger.info("Manual scan triggered")

    try:
        result = await scanner.scan_once()
    except Exception as e:
        logger.exception("Scan failed")
        raise HTTPException(status_code=500, detail=f"Scan failed: {e}")

    return ScanResponse(
        status="completed",
        scanned=result.get("scanned", 0),
        repaired=result.get("repaired", 0),
        failed=result.get("failed", 0),
        reference=result.get("reference"),
    )


@app.post("/repair", response_model=RepairResponse)
async def repair(req: RepairRequest):
    """
    Manually repair a specific file.
    
    The file must exist in the ready directory.
    A reference file must be specified or auto-selected.
    """
    src = settings.ready_path / req.relative_path
    dst = settings.export_path / req.relative_path

    # Validate source exists
    if not src.exists():
        raise HTTPException(
            status_code=404,
            detail=f"File not found: {req.relative_path}",
        )

    # Determine reference file
    if req.reference_path:
        reference = settings.ready_path / req.reference_path
        if not reference.exists():
            raise HTTPException(
                status_code=404,
                detail=f"Reference file not found: {req.reference_path}",
            )
    else:
        # Auto-select reference from ready directory
        candidates = [
            p for p in settings.ready_path.rglob("*")
            if p.is_file()
            and p.suffix.lower() in {".mp4", ".mov", ".mkv"}
            and p != src
        ]
        
        if not candidates:
            raise HTTPException(
                status_code=400,
                detail="No reference file available. Upload a working video or specify reference_path.",
            )

        # Use smallest as reference
        reference = min(candidates, key=lambda p: p.stat().st_size)

    logger.info(
        "Manual repair requested",
        extra={
            "source": str(src),
            "reference": str(reference),
        },
    )

    try:
        await run_untrunc(src, dst, reference)

        # Verify output
        if not dst.exists():
            raise UntruncRepairError("Output file not created")

        # Remove source after successful repair
        src.unlink()

        return RepairResponse(
            status="repaired",
            source=str(src),
            output=str(dst),
            reference=str(reference),
        )

    except UntruncRepairError as e:
        logger.warning(
            "Manual repair failed",
            extra={"source": str(src), "error": str(e)},
        )

        # Try AWS fallback if enabled
        if req.invoke_aws_on_failure and settings.aws_repair_api_base_url:
            success = await scanner._invoke_aws_fallback(Path(req.relative_path))
            if success:
                return RepairResponse(
                    status="fallback_invoked",
                    source=str(src),
                    detail=str(e),
                )

        raise HTTPException(status_code=500, detail=str(e))


@app.get("/stats")
async def stats():
    """Get scanner statistics."""
    return {
        "known_files": len(scanner._known),
        "current_reference": str(scanner._current_reference) if scanner._current_reference else None,
        "running": scanner._running,
    }
