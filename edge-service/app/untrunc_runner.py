"""
Untrunc subprocess runner with security hardening.

Features:
- Uses subprocess exec (not shell) to prevent injection
- Verifies output file exists and has reasonable size
- Proper timeout handling
- Structured logging
- Handles both -dst output and auto-generated _fixed output

untrunc CLI syntax (anthwlock/untrunc):
  untrunc [options] <reference.mp4> <corrupted.mp4>
  
Options used:
  -n    : non-interactive mode (no prompts)
  -dst  : set output destination file
"""

import asyncio
import logging
import shutil
from pathlib import Path
from typing import Optional

from .config import settings

logger = logging.getLogger(__name__)


class UntruncRepairError(Exception):
    """Raised when untrunc repair fails."""
    pass


def find_untrunc_binary() -> str:
    """Find the untrunc binary on PATH."""
    binary = shutil.which("untrunc")
    if binary:
        return binary
    
    # Check common locations
    common_paths = [
        "/usr/local/bin/untrunc",
        "/usr/bin/untrunc",
        "/app/bin/untrunc",
    ]
    for path in common_paths:
        if Path(path).exists():
            return path
    
    raise UntruncRepairError(
        "untrunc binary not found. Please install it and ensure it's on PATH."
    )


async def run_untrunc(
    input_path: Path,
    output_path: Path,
    reference_path: Path,
    timeout: Optional[int] = None,
) -> None:
    """
    Run untrunc to repair a video file.

    Args:
        input_path: Path to the corrupted video file
        output_path: Path where repaired file will be written
        reference_path: Path to a working reference video from the same camera
        timeout: Timeout in seconds (default from settings)

    Raises:
        UntruncRepairError: If repair fails for any reason
    """
    if timeout is None:
        timeout = settings.untrunc_timeout_seconds

    # Validate inputs exist
    if not input_path.exists():
        raise UntruncRepairError(f"Input file does not exist: {input_path}")
    
    if not reference_path.exists():
        raise UntruncRepairError(f"Reference file does not exist: {reference_path}")

    # Create output directory
    output_path.parent.mkdir(parents=True, exist_ok=True)

    # Find untrunc binary
    try:
        untrunc_bin = find_untrunc_binary()
    except UntruncRepairError:
        raise

    # Build command - using exec style (no shell)
    # untrunc CLI syntax (anthwlock/untrunc):
    #   untrunc [options] <reference.mp4> <corrupted.mp4>
    # Options:
    #   -n    : non-interactive mode (no prompts)
    #   -s    : step through unknown sequences (improves recovery)
    #   -dst  : set output destination file
    cmd = [
        untrunc_bin,
        "-n",                     # Non-interactive mode
        "-s",                     # Step through unknown sequences (better recovery)
        "-dst", str(output_path), # Set output destination
        str(reference_path),      # Reference (working) video
        str(input_path),          # Corrupted video to repair
    ]

    logger.info(
        "Running untrunc",
        extra={
            "input": str(input_path),
            "output": str(output_path),
            "reference": str(reference_path),
            "timeout": timeout,
            "command": " ".join(cmd),
        }
    )

    # Run subprocess
    process = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )

    try:
        stdout, stderr = await asyncio.wait_for(
            process.communicate(),
            timeout=timeout,
        )
    except asyncio.TimeoutError:
        process.kill()
        await process.wait()
        raise UntruncRepairError(
            f"untrunc timed out after {timeout} seconds"
        )

    stdout_text = stdout.decode(errors="ignore").strip()
    stderr_text = stderr.decode(errors="ignore").strip()
    
    # Log output regardless of success/failure
    if stdout_text:
        logger.debug("untrunc stdout: %s", stdout_text[:1000])
    if stderr_text:
        logger.debug("untrunc stderr: %s", stderr_text[:1000])

    # Check return code
    if process.returncode != 0:
        logger.error(
            "untrunc failed",
            extra={
                "returncode": process.returncode,
                "stderr": stderr_text[:500],
                "stdout": stdout_text[:500],
            }
        )
        raise UntruncRepairError(
            f"untrunc failed with code {process.returncode}: {stderr_text[:200]}"
        )

    # Verify output file was created
    # untrunc might create file at -dst location OR as <input>_fixed.<ext>
    if not output_path.exists():
        # Check for auto-generated _fixed file
        auto_output = input_path.parent / f"{input_path.stem}_fixed{input_path.suffix}"
        if auto_output.exists():
            logger.info(f"Moving auto-generated output {auto_output} to {output_path}")
            shutil.move(str(auto_output), str(output_path))
        else:
            raise UntruncRepairError(
                f"untrunc did not create output file at {output_path} or {auto_output}"
            )

    # Verify output has reasonable size (at least 1KB)
    output_size = output_path.stat().st_size
    if output_size < 1024:
        output_path.unlink()  # Remove invalid output
        raise UntruncRepairError(
            f"Output file too small ({output_size} bytes) - repair likely failed"
        )

    # Log success
    input_size = input_path.stat().st_size
    logger.info(
        "untrunc completed successfully",
        extra={
            "input": str(input_path),
            "output": str(output_path),
            "input_size": input_size,
            "output_size": output_size,
        }
    )
