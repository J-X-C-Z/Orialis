"""Best-effort side messages; the real Hermes turn never waits for them."""
from __future__ import annotations

import asyncio
import logging
import time

logger = logging.getLogger(__name__)
PROGRESS_INTERVAL = 30.0


def tool_phase(name: str) -> str:
    # Classify only public tool names; never inspect arguments, output or reasoning.
    name = name.lower()
    if any(word in name for word in ("search", "browse", "web", "fetch")):
        return "查找资料"
    if any(word in name for word in ("read", "file", "document")):
        return "查看文件和资料"
    if any(word in name for word in ("terminal", "execute", "python", "shell")):
        return "执行任务步骤"
    return "调用工具处理请求"


class TurnUpdates:
    def __init__(self, initial, emit, summarize=None):
        self.emit = emit
        self.summarize = summarize
        self.history = []
        self.public_notes = []
        self.previous_updates = []
        self.revision = 0
        self.last_attempt = 0.0
        self._reporting = False
        self.phase = ("processing", "")
        self.last_report = None
        self.last_public = time.monotonic()
        self.paused = False
        self.closed = False
        self.sequence = 0
        self.initial_task = asyncio.create_task(self._initial(initial), name="orialis-initial-reply")
        self.task = asyncio.create_task(self._pump(), name="orialis-progress-replies")

    async def _initial(self, initial):
        try:
            await initial()
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.warning("Orialis initial reply unavailable", exc_info=True)

    def observe(self, phase: str, tool: str = "") -> None:
        if self.closed:
            return
        current = (phase, tool_phase(tool) if tool else "")
        if current != self.phase:
            self.revision += 1
            self.history = (self.history + [{"phase": current[0], "activity": current[1]}])[-6:]
        self.phase = current
        self.paused = False
        if self.task.done() or self.task.cancelling():
            self.task = asyncio.create_task(self._pump(), name="orialis-progress-replies")

    def public_output(self, note: str | None = None) -> None:
        if note and note.strip() and (not self.public_notes or self.public_notes[-1] != note[:800]):
            self.public_notes = (self.public_notes + [note[:800]])[-3:]
        self.revision += 1
        # A real response wins even if the initial model or an ACK is still pending.
        self.last_public = time.monotonic()
        self.paused = True
        self.task.cancel()
        if not self.initial_task.done():
            self.initial_task.cancel()

    def initial_sent(self) -> None:
        self.last_public = time.monotonic()

    async def report(self) -> None:
        if (self.closed or self.paused or self._reporting or not self.summarize
                or self.revision == self.last_report
                or time.monotonic() - max(self.last_public, self.last_attempt) < PROGRESS_INTERVAL):
            return
        revision = self.revision
        facts = {"phase": self.phase[0], "activity": self.phase[1],
                 "stage_history": list(self.history), "public_notes": list(self.public_notes),
                 "previous_updates": list(self.previous_updates)}
        self.last_attempt = time.monotonic()
        self._reporting = True
        try:
            text = await self.summarize(facts)
            # Phase changes and real output supersede even a model that ignores cancellation.
            if self.closed or self.paused or revision != self.revision or not text:
                return
            if text in self.previous_updates or text in self.public_notes:
                self.last_report = revision
                return
            self.sequence += 1
            self.last_report = revision
            self.last_public = time.monotonic()
            self.previous_updates = (self.previous_updates + [text])[-3:]
            await self.emit(text, self.sequence)
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.warning("Orialis contextual progress failed", exc_info=True)
        finally:
            self._reporting = False

    async def _pump(self):
        try:
            while not self.closed and not self.paused and asyncio.current_task() is self.task:
                remaining = PROGRESS_INTERVAL - (time.monotonic() - max(self.last_public, self.last_attempt))
                await asyncio.sleep(remaining if remaining > 0 else PROGRESS_INTERVAL)
                await self.report()
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.warning("Orialis progress delivery unavailable", exc_info=True)

    def close(self) -> None:
        self.closed = True
        self.initial_task.cancel()
        self.task.cancel()
