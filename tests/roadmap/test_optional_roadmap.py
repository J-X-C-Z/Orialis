from __future__ import annotations

import unittest

from .support import LiveServerMixin


class OptionalNonVoiceRoadmapTests(LiveServerMixin, unittest.TestCase):
    """Capability-gated probes for roadmap surfaces not in the current server."""

    def test_typing_contract(self) -> None:
        self.require_capability("typing", "typing events")
        self.fail("typing is advertised but this black-box suite has no stable endpoint contract")

    def test_ordered_streaming_duplicate_delta_and_reconnect(self) -> None:
        self.require_capability("ordered-streaming", "ordered streaming duplicate delta/reconnect")
        self.fail("ordered streaming is advertised but no stable endpoint contract is available")

    def test_status_and_tool_timeline(self) -> None:
        self.require_capability("timeline", "status/tool timeline")
        self.fail("timeline is advertised but no stable endpoint contract is available")

    def test_clarify_decision(self) -> None:
        self.require_capability("clarify", "clarify")
        self.fail("clarify is advertised but no stable endpoint contract is available")

    def test_approval_four_decisions_timeout_and_duplicate(self) -> None:
        self.require_capability("approval", "approval decisions/timeout/duplicate")
        self.fail("approval is advertised but no stable endpoint contract is available")

    def test_commands(self) -> None:
        self.require_capability("commands", "commands")
        self.fail("commands are advertised but no stable endpoint contract is available")

    def test_cron_delivery(self) -> None:
        self.require_capability("cron-delivery", "cron delivery")
        self.fail("cron delivery is advertised but no stable endpoint contract is available")

    def test_artifact(self) -> None:
        self.require_capability("artifacts", "artifact")
        self.fail("artifacts are advertised but no stable endpoint contract is available")
