"""
Configuration for the Edge Untrunc Repair Service.

Uses pydantic-settings for environment variable handling.
"""

import os
from pathlib import Path
from typing import Optional

from pydantic import AnyHttpUrl, field_validator
from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    """Application settings loaded from environment variables."""

    # Directory configuration
    container_smb_root: Path = Path("/data")
    ready_dir: str = "ready"
    export_dir: str = "export"
    quarantine_dir: str = "quarantine"

    # Scanner configuration
    scan_interval_seconds: int = 30
    min_file_age_seconds: int = 60
    max_concurrent_jobs: int = 2
    untrunc_timeout_seconds: int = 3600

    # AWS fallback configuration
    aws_repair_api_base_url: Optional[str] = None
    aws_api_key: Optional[str] = None
    aws_fallback_retries: int = 3

    # Reference file strategy: "smallest" or "newest"
    reference_strategy: str = "smallest"

    # Logging
    log_level: str = "INFO"
    log_format: str = "json"  # "json" or "text"

    # Health check
    service_name: str = "edge-untrunc"

    model_config = {
        "env_prefix": "",
        "case_sensitive": False,
    }

    @field_validator("container_smb_root", mode="before")
    @classmethod
    def parse_path(cls, v):
        if isinstance(v, str):
            return Path(v)
        return v

    @field_validator("reference_strategy")
    @classmethod
    def validate_strategy(cls, v):
        allowed = {"smallest", "newest"}
        if v not in allowed:
            raise ValueError(f"reference_strategy must be one of: {allowed}")
        return v

    @property
    def ready_path(self) -> Path:
        return self.container_smb_root / self.ready_dir

    @property
    def export_path(self) -> Path:
        return self.container_smb_root / self.export_dir

    @property
    def quarantine_path(self) -> Path:
        return self.container_smb_root / self.quarantine_dir


# Global settings instance
settings = Settings()
