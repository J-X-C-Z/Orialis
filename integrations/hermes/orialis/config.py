"""Scoped configuration for the Orialis Hermes platform adapter."""

from dataclasses import dataclass
from typing import Any, Optional

from gateway.platforms._shared import extra_or_secret, seed_extra_from_env


_ENV_SPEC = (
    ("ORIALIS_SERVER_URL", "server_url", None),
    ("ORIALIS_DEVICE_ID", "device_id", None),
    ("ORIALIS_DEVICE_TOKEN", "device_token", None),
)


@dataclass(frozen=True)
class OrialisConfig:
    server_url: str
    device_id: str
    device_token: Optional[str] = None

    @classmethod
    def from_platform_config(cls, platform_config: Any) -> "OrialisConfig":
        extra = getattr(platform_config, "extra", {}) or {}
        return cls(
            server_url=str(extra_or_secret(extra, "server_url", "ORIALIS_SERVER_URL", "")).strip(),
            device_id=str(extra_or_secret(extra, "device_id", "ORIALIS_DEVICE_ID", "")).strip(),
            device_token=(
                str(extra_or_secret(extra, "device_token", "ORIALIS_DEVICE_TOKEN", "")).strip() or None
            ),
        )


def env_enablement() -> dict:
    return seed_extra_from_env(_ENV_SPEC)


def validate(platform_config: Any) -> bool:
    config = OrialisConfig.from_platform_config(platform_config)
    return bool(config.server_url and config.device_id)
