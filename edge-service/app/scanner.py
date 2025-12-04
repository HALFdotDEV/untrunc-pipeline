"""
Directory scanner for automatic video repair.

Features:
- Watches READY_DIR for stable video files
- Auto-selects reference file (smallest or newest)
- Repairs files using untrunc
- Moves successful repairs to EXPORT_DIR
- Moves failures to QUARANTINE_DIR with AWS fallback
- Retry logic for AWS fallback calls
"""

import asyncio
import logging
import random
import time
from pathlib import Path
from typing import Dict, List, Optional

import httpx

from .config import settings
from .untrunc_runner import run_untrunc, UntruncRepairError

logger = logging.getLogger(__name__)

VIDEO_EXTENSIONS = {".mp4", ".mov", ".mkv", ".avi", ".m4v"}


class FileState:
    """Track file state for stability detection."""

    def __init__(self, size: int, mtime: float):
        self.size = size
        self.mtime = mtime
        self.first_seen = time.time()


class DirectoryScanner:
    """
    Scans directories for video files and repairs them using untrunc.
    """

    def __init__(self):
        self._known: Dict[Path, FileState] = {}
        self._running = False
        self._current_reference: Optional[Path] = None

    def _is_candidate(self, path: Path) -> bool:
        """Check if path is a video file candidate."""
        if not path.is_file():
            return False
        if path.suffix.lower() not in VIDEO_EXTENSIONS:
            return False
        # Skip hidden files and temp files
        if path.name.startswith(".") or path.name.startswith("~"):
            return False
        return True

    def _is_stable(self, path: Path, min_age: int) -> bool:
        """
        Check if file is stable (not being written to).
        
        A file is stable if:
        1. Its mtime is older than min_age seconds
        2. Its size hasn't changed since we last checked
        """
        try:
            stat = path.stat()
        except OSError:
            return False

        now = time.time()

        # File must be old enough
        if now - stat.st_mtime < min_age:
            return False

        # Check if size has changed
        prev = self._known.get(path)
        current = FileState(size=stat.st_size, mtime=stat.st_mtime)

        if prev is None:
            # First time seeing this file
            self._known[path] = current
            return False

        if prev.size != current.size or prev.mtime != current.mtime:
            # File changed since last check
            self._known[path] = current
            return False

        # File is stable
        return True

    def _select_reference_file(self, candidates: List[Path]) -> Optional[Path]:
        """
        Select a reference file from the candidates.
        
        The reference file should be a working video that untrunc can use
        to understand the codec parameters.
        """
        if not candidates:
            return None

        if len(candidates) == 1:
            # Only one file - can't repair without reference
            logger.warning("Only one file found - cannot determine reference")
            return None

        if settings.reference_strategy == "smallest":
            # Sort by size ascending, pick smallest
            sorted_files = sorted(candidates, key=lambda p: p.stat().st_size)
            return sorted_files[0]

        elif settings.reference_strategy == "newest":
            # Sort by mtime descending, pick newest
            sorted_files = sorted(
                candidates, 
                key=lambda p: p.stat().st_mtime, 
                reverse=True
            )
            return sorted_files[0]

        else:
            # Default to smallest
            sorted_files = sorted(candidates, key=lambda p: p.stat().st_size)
            return sorted_files[0]

    async def scan_once(self) -> dict:
        """
        Perform a single scan of the ready directory.
        
        Returns dict with scan results.
        """
        ready_root = settings.ready_path
        export_root = settings.export_path
        quarantine_root = settings.quarantine_path

        # Ensure directories exist
        ready_root.mkdir(parents=True, exist_ok=True)
        export_root.mkdir(parents=True, exist_ok=True)
        quarantine_root.mkdir(parents=True, exist_ok=True)

        # Find stable candidates
        candidates = []
        for path in ready_root.rglob("*"):
            if not self._is_candidate(path):
                continue
            if not self._is_stable(path, settings.min_file_age_seconds):
                continue
            candidates.append(path)

        if not candidates:
            logger.debug("No stable candidates found in %s", ready_root)
            return {"scanned": 0, "repaired": 0, "failed": 0}

        logger.info("Found %d stable candidates", len(candidates))

        # Select reference file
        reference = self._select_reference_file(candidates)
        if reference is None:
            logger.warning("Could not select reference file - skipping batch")
            return {"scanned": len(candidates), "repaired": 0, "failed": 0, "skipped": "no_reference"}

        self._current_reference = reference
        logger.info(
            "Selected reference file: %s (%d bytes)",
            reference.name,
            reference.stat().st_size,
        )

        # Files to repair = all except reference
        files_to_repair = [f for f in candidates if f != reference]

        if not files_to_repair:
            logger.info("No files to repair (only reference file present)")
            return {"scanned": len(candidates), "repaired": 0, "failed": 0}

        # Process files with concurrency limit
        sem = asyncio.Semaphore(settings.max_concurrent_jobs)
        results = {"repaired": 0, "failed": 0}

        async def worker(src: Path):
            async with sem:
                rel = src.relative_to(ready_root)
                dst = export_root / rel

                try:
                    # Run repair
                    await run_untrunc(src, dst, reference)

                    # Verify output before deleting source
                    if not dst.exists():
                        raise UntruncRepairError("Output file not created")

                    dst_size = dst.stat().st_size
                    if dst_size < 1024:
                        dst.unlink()
                        raise UntruncRepairError(f"Output too small: {dst_size} bytes")

                    # Success - remove source
                    src.unlink()
                    self._known.pop(src, None)
                    results["repaired"] += 1

                    logger.info(
                        "Repaired successfully",
                        extra={"source": str(src), "output": str(dst), "size": dst_size},
                    )

                except UntruncRepairError as e:
                    logger.warning(
                        "Local repair failed",
                        extra={"file": str(src), "error": str(e)},
                    )

                    # Move to quarantine
                    qdst = quarantine_root / rel
                    qdst.parent.mkdir(parents=True, exist_ok=True)
                    try:
                        src.rename(qdst)
                        self._known.pop(src, None)
                    except OSError as move_err:
                        logger.error("Failed to move to quarantine: %s", move_err)

                    # Try AWS fallback
                    await self._invoke_aws_fallback(rel)
                    results["failed"] += 1

        await asyncio.gather(*(worker(p) for p in files_to_repair))

        # Also copy reference to export if not already there
        ref_rel = reference.relative_to(ready_root)
        ref_dst = export_root / ref_rel
        if not ref_dst.exists():
            ref_dst.parent.mkdir(parents=True, exist_ok=True)
            try:
                # Copy (not move) reference in case it's needed again
                import shutil
                shutil.copy2(reference, ref_dst)
                logger.info("Copied reference file to export: %s", ref_dst)
            except OSError as e:
                logger.warning("Failed to copy reference to export: %s", e)

        return {
            "scanned": len(candidates),
            "reference": str(reference),
            **results,
        }

    async def _invoke_aws_fallback(
        self,
        relative_path: Path,
        max_retries: Optional[int] = None,
    ) -> bool:
        """
        Invoke AWS repair API as fallback.
        
        Returns True if invocation succeeded, False otherwise.
        """
        if not settings.aws_repair_api_base_url:
            logger.info(
                "AWS fallback disabled",
                extra={"file": str(relative_path)},
            )
            return False

        if max_retries is None:
            max_retries = settings.aws_fallback_retries

        url = settings.aws_repair_api_base_url.rstrip("/") + "/submit-batch"

        payload = {
            "edge_quarantine_path": str(relative_path),
            "source": "edge-fallback",
        }

        headers = {"Content-Type": "application/json"}
        if settings.aws_api_key:
            headers["X-Api-Key"] = settings.aws_api_key

        logger.info(
            "Invoking AWS fallback",
            extra={"url": url, "file": str(relative_path)},
        )

        for attempt in range(max_retries):
            try:
                async with httpx.AsyncClient(timeout=30) as client:
                    resp = await client.post(url, json=payload, headers=headers)
                    resp.raise_for_status()

                logger.info(
                    "AWS fallback invoked successfully",
                    extra={
                        "status": resp.status_code,
                        "file": str(relative_path),
                    },
                )
                return True

            except httpx.HTTPStatusError as e:
                logger.warning(
                    "AWS fallback HTTP error",
                    extra={
                        "attempt": attempt + 1,
                        "max_retries": max_retries,
                        "status": e.response.status_code,
                        "error": str(e),
                    },
                )

            except Exception as e:
                logger.warning(
                    "AWS fallback error",
                    extra={
                        "attempt": attempt + 1,
                        "max_retries": max_retries,
                        "error": str(e),
                    },
                )

            # Exponential backoff with jitter
            if attempt < max_retries - 1:
                wait = (2 ** attempt) + random.uniform(0, 1)
                await asyncio.sleep(wait)

        logger.error(
            "AWS fallback exhausted retries",
            extra={"file": str(relative_path), "retries": max_retries},
        )
        return False

    async def run_forever(self):
        """Run the scanner in a continuous loop."""
        self._running = True
        logger.info(
            "Scanner started",
            extra={
                "ready_path": str(settings.ready_path),
                "interval": settings.scan_interval_seconds,
            },
        )

        while self._running:
            try:
                result = await self.scan_once()
                if result.get("repaired", 0) > 0 or result.get("failed", 0) > 0:
                    logger.info("Scan completed", extra=result)
            except Exception as e:
                logger.exception("Error during scan: %s", e)

            await asyncio.sleep(settings.scan_interval_seconds)

    def stop(self):
        """Stop the scanner loop."""
        self._running = False


# Global scanner instance
scanner = DirectoryScanner()
