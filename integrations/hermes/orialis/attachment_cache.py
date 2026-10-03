"""Persistent inbound files: a reply or socket reconnect must not erase history paths."""

from __future__ import annotations

import hashlib
import logging
import os
import shutil
import time
from pathlib import Path

logger = logging.getLogger(__name__)

RETENTION_SECONDS = 30 * 24 * 60 * 60


def _key(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


class AttachmentCache:
    def __init__(self, server_url: str, device_id: str, token: str | None):
        home = Path(os.environ.get("HERMES_HOME") or Path.home() / ".hermes")
        # Token fingerprint prevents cache reuse across credential/identity changes.
        self.root = home / "cache" / "orialis-attachments" / _key(
            repr((server_url, device_id, token or ""))
        )
        self.active: dict[str, Path] = {}

    def acquire(self, conversation_id: str, message_id: str) -> Path:
        self.prune()
        directory = self.root / _key(repr((conversation_id, message_id)))
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        directory.touch()
        self.active[message_id] = directory
        return directory

    def release(self, message_id: str) -> None:
        directory = self.active.pop(message_id, None)
        if directory is not None:
            try:
                os.utime(directory, None)
            except OSError:
                logger.warning("Could not refresh Orialis attachment retention", exc_info=True)

    def prune(self) -> None:
        if not self.root.exists():
            return
        cutoff = time.time() - RETENTION_SECONDS
        pinned = set(self.active.values())
        try:
            directories = list(self.root.iterdir())
        except OSError:
            logger.warning("Could not inspect Orialis attachment cache", exc_info=True)
            return
        for directory in directories:
            try:
                if directory.is_symlink() or not directory.is_dir() or directory in pinned:
                    continue
                if directory.stat().st_mtime < cutoff:
                    shutil.rmtree(directory)
            except OSError:
                logger.warning("Could not prune Orialis attachment cache", exc_info=True)
