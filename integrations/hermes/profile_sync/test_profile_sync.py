"""Focused protocol tests for the Hermes profile sync hub."""
import base64
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("profile_sync.py")
SPEC = importlib.util.spec_from_file_location("profile_sync", SCRIPT)
profile_sync = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(profile_sync)


def make_request(node, hub_id, base_data, live_data):
    """Build the documented request from path -> bytes snapshots."""
    base = profile_sync.manifest(base_data)
    live = profile_sync.manifest(live_data)
    payload = {
        path: base64.b64encode(data).decode("ascii")
        for path, data in live_data.items()
        if live.get(path) != base.get(path)
    }
    return {"node": node, "hub_id": hub_id, "base": base, "live": live,
            "payload": payload}


class ProfileSyncTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = Path(self.temp.name) / "hub"

    def tearDown(self):
        self.temp.cleanup()

    def exchange(self, node, base, live, hub_id=None):
        return profile_sync.exchange(
            self.store, make_request(node, hub_id, base, live))

    def blob(self, sha):
        return profile_sync.get_blob(self.store, sha)

    def test_hub_replies_to_one_frame_without_waiting_for_ssh_eof(self):
        request = make_request("windows", None, {}, {})
        proc = subprocess.Popen([sys.executable, str(SCRIPT), "hub", "--store", str(self.store)],
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            proc.stdin.write((json.dumps(request) + "\n").encode())
            proc.stdin.flush()
            self.assertEqual(proc.wait(timeout=3), 0)
            self.assertEqual(json.loads(proc.stdout.read())["files"], {})
        finally:
            proc.kill() if proc.poll() is None else None
            proc.wait()
            proc.stdin.close()
            proc.stdout.close()
            proc.stderr.close()

    def test_memory_over_capacity_stays_recoverable_without_truncation(self):
        p = "memories/MEMORY.md"
        first = self.exchange("mac", {}, {p: b"base"})
        state = profile_sync.json_read(self.store / "hub.json")
        state["memory_limits"] = {p: 8}
        profile_sync.json_write(self.store / "hub.json", state)
        result = self.exchange("windows", {p: b"base"}, {p: b"long new memory"}, first["hub_id"])
        self.assertIn(p, result["conflicts"])
        self.assertEqual(self.blob(result["files"][p]), b"base")
        self.assertEqual(self.blob(profile_sync.digest(b"long new memory")), b"long new memory")

    def test_incremental_add_and_offline_delete_do_not_resurrect(self):
        initial = {"skills/demo/SKILL.md": b"original\n"}
        first = self.exchange("mac", {}, initial)
        hub_id = first["hub_id"]
        baseline = dict(initial)

        # Windows comes online later with the same baseline and sees the new file.
        mac_live = {**baseline, "skills/demo/extra.md": b"added incrementally\n"}
        updated = self.exchange("mac", baseline, mac_live, hub_id)
        self.assertIn("skills/demo/extra.md", updated["files"])
        windows = self.exchange("windows", baseline, baseline, hub_id)
        self.assertEqual(
            base64.b64decode(windows["changes"]["skills/demo/extra.md"]),
            b"added incrementally\n")

        # Windows is now offline. Mac deletes the original; an unchanged stale
        # snapshot from Windows must not restore it.
        deleted = self.exchange("mac", mac_live, {"skills/demo/extra.md": b"added incrementally\n"}, hub_id)
        self.assertNotIn("skills/demo/SKILL.md", deleted["files"])
        reconciled = self.exchange("windows", baseline, baseline, hub_id)
        self.assertNotIn("skills/demo/SKILL.md", reconciled["files"])
        self.assertIsNone(reconciled["changes"]["skills/demo/SKILL.md"])

        # A subsequent incremental exchange from Windows still cannot revive it.
        final = self.exchange("windows", baseline, baseline, hub_id)
        self.assertNotIn("skills/demo/SKILL.md", final["files"])

    def test_memory_concurrent_additions_and_deletions_are_combined(self):
        path = "memories/MEMORY.md"
        base = {path: "keep\n§\ndelete-a\n§\ndelete-b".encode()}
        initial = self.exchange("mac", {}, base)
        hub_id = initial["hub_id"]

        mac_live = {path: "keep\n§\ndelete-b\n§\nmac-add".encode()}
        self.exchange("mac", base, mac_live, hub_id)
        windows_live = {path: "keep\n§\ndelete-a\n§\nwindows-add".encode()}
        result = self.exchange("windows", base, windows_live, hub_id)
        merged = self.blob(result["files"][path]).decode()
        self.assertEqual(set(merged.split("\n§\n")), {"keep", "mac-add", "windows-add"})
        self.assertNotIn("delete-a", merged)
        self.assertNotIn("delete-b", merged)

    def test_soul_conflict_preserves_both_blobs_without_returning_conflict_text(self):
        base = {"SOUL.md": b"voice: plain\n"}
        initial = self.exchange("mac", {}, base)
        hub_id = initial["hub_id"]
        mac_live = {"SOUL.md": b"voice: warm\n"}
        self.exchange("mac", base, mac_live, hub_id)
        windows_live = {"SOUL.md": b"voice: terse\n"}

        result = self.exchange("windows", base, windows_live, hub_id)
        self.assertEqual(result["conflicts"], ["SOUL.md"])
        self.assertEqual(self.blob(profile_sync.digest(mac_live["SOUL.md"])), mac_live["SOUL.md"])
        self.assertEqual(self.blob(profile_sync.digest(windows_live["SOUL.md"])), windows_live["SOUL.md"])
        self.assertNotIn("SOUL.md", result["changes"])
        self.assertNotIn(b"<<<<<<<", b"".join(result["changes"].values()))

    def test_nonoverlapping_skill_text_edits_merge(self):
        path = "skills/demo/SKILL.md"
        base = {path: b"one\ntwo\nthree\n"}
        first = self.exchange("mac", {}, base)
        hub_id = first["hub_id"]
        mac_live = {path: b"ONE\ntwo\nthree\n"}
        self.exchange("mac", base, mac_live, hub_id)
        windows_live = {path: b"one\ntwo\nTHREE\n"}
        result = self.exchange("windows", base, windows_live, hub_id)
        self.assertEqual(self.blob(result["files"][path]), b"ONE\ntwo\nTHREE\n")
        self.assertEqual(result["conflicts"], [])

    def test_changed_hub_identity_is_rejected(self):
        initial = self.exchange("mac", {}, {"SOUL.md": b"identity"})
        request = make_request("windows", "different-hub-id", {}, {})
        with self.assertRaisesRegex(ValueError, "Hub identity changed"):
            profile_sync.exchange(self.store, request)
        self.assertEqual(profile_sync.json_read(self.store / "hub.json")["hub_id"], initial["hub_id"])

    def test_scope_traversal_and_windows_case_collisions_are_rejected(self):
        for path in ("skills/../outside.txt", "memories/SECRET.md", "skills/demo\\escape.md"):
            with self.subTest(path=path), self.assertRaises(ValueError):
                profile_sync.validate_paths([path])
        with self.assertRaisesRegex(ValueError, "Cross-platform filename collision"):
            profile_sync.validate_paths(["skills/Demo/SKILL.md", "skills/demo/skill.md"])

    def test_lost_response_retry_is_idempotent(self):
        request = make_request("mac", None, {}, {"skills/demo/SKILL.md": b"one"})
        first = profile_sync.exchange(self.store, request)
        # Simulate a client that did not persist the first response.
        second = profile_sync.exchange(self.store, request)
        self.assertEqual(second["hub_id"], first["hub_id"])
        self.assertEqual(second["revision"], first["revision"])
        self.assertEqual(second["files"], first["files"])
        self.assertEqual(len(list((self.store / "history").glob("*.json"))), 1)

    def test_concurrent_binary_soul_edits_conflict_and_keep_both_objects(self):
        base = {"SOUL.md": b"base\x00bytes"}
        first = self.exchange("mac", {}, base)
        hub_id = first["hub_id"]
        mac_live = {"SOUL.md": b"mac\x00version"}
        self.exchange("mac", base, mac_live, hub_id)
        windows_live = {"SOUL.md": b"windows\x00version"}
        result = self.exchange("windows", base, windows_live, hub_id)
        self.assertEqual(result["conflicts"], ["SOUL.md"])
        self.assertEqual(self.blob(profile_sync.digest(mac_live["SOUL.md"])), mac_live["SOUL.md"])
        self.assertEqual(self.blob(profile_sync.digest(windows_live["SOUL.md"])), windows_live["SOUL.md"])
        self.assertNotIn("SOUL.md", result["changes"])


if __name__ == "__main__":
    unittest.main()
