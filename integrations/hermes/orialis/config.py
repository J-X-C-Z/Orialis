"""Scoped configuration for the Orialis Hermes platform adapter."""

from dataclasses import dataclass
from typing import Any, Optional

from gateway.platforms._shared import extra_or_secret, seed_extra_from_env
from .protocol import is_valid_agent_device_id


_ENV_SPEC = (
    ("ORIALIS_SERVER_URL", "server_url", None),
    ("ORIALIS_DEVICE_ID", "device_id", None),
    ("ORIALIS_DEVICE_TOKEN", "device_token", None),
    ("ORIALIS_HOME_CHANNEL", "home_channel", None),
)


def _positive_float(value: Any, default: float) -> float:
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        return default
    return parsed if parsed > 0 else default


@dataclass(frozen=True)
class OrialisConfig:
    server_url: str
    device_id: str
    device_token: Optional[str] = None
    home_channel: Optional[str] = None
    ack_timeout_seconds: float = 10.0
    interaction_timeout_seconds: float = 300.0
    stream_timeout_seconds: float = 120.0

    @classmethod
    def from_platform_config(cls, platform_config: Any) -> "OrialisConfig":
        extra = getattr(platform_config, "extra", {}) or {}
        return cls(
            server_url=str(extra_or_secret(extra, "server_url", "ORIALIS_SERVER_URL", "")).strip(),
            device_id=str(extra_or_secret(extra, "device_id", "ORIALIS_DEVICE_ID", "")).strip(),
            device_token=(
                str(extra_or_secret(extra, "device_token", "ORIALIS_DEVICE_TOKEN", "")).strip() or None
            ),
            home_channel=(str(extra_or_secret(extra, "home_channel", "ORIALIS_HOME_CHANNEL", "")).strip() or None),
            ack_timeout_seconds=_positive_float(extra.get("ack_timeout_seconds"), 10.0),
            interaction_timeout_seconds=_positive_float(extra.get("interaction_timeout_seconds"), 300.0),
            stream_timeout_seconds=_positive_float(extra.get("stream_timeout_seconds"), 120.0),
        )


def env_enablement() -> dict:
    return seed_extra_from_env(_ENV_SPEC)


def validate(platform_config: Any) -> bool:
    config = OrialisConfig.from_platform_config(platform_config)
    return bool(config.server_url and is_valid_agent_device_id(config.device_id))
