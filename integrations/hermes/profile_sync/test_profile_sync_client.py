"""Focused client-side tests for the Hermes profile sync protocol."""
import base64
import importlib.util
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("profile_sync.py")
SPEC = importlib.util.spec_from_file_location("profile_sync_client", SCRIPT)
profile_sync = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(profile_sync)


def exchange_request(node, hub_id, base_data, live_data):
    base = profile_sync.manifest(base_data)
    live = profile_sync.manifest(live_data)
    payload = {
        path: base64.b64encode(data).decode("ascii")
        for path, data in live_data.items()
        if live.get(path) != base.get(path)
    }
    return {"node": node, "hub_id": hub_id, "base": base, "live": live,
            "payload": payload}


class ProfileSyncClientTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.profile = self.root / "profile"
        self.profile.mkdir()
        self.store = self.root / "hub"
        self.state = self.root / "client-state"
        self.config = {"profile": str(self.profile), "state_dir": str(self.state),
                       "node": "client", "hub_store": str(self.store)}

    def tearDown(self):
        self.temp.cleanup()

    def write_profile(self, rel, data):
        path = self.profile / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def sync(self):
        return profile_sync.run_sync(self.config)

    def seed_hub(self, data):
        return profile_sync.exchange(self.store, exchange_request("seed", None, {}, data))

    def test_additions_and_deletions_are_applied_to_actual_profile_files(self):
        self.write_profile("skills/demo/SKILL.md", b"base\n")
        self.assertEqual(self.sync(), 0)
        state = profile_sync.json_read(self.state / "client.json")
        hub_id = state["hub_id"]
        base = {"skills/demo/SKILL.md": b"base\n"}

        remote = {**base, "skills/demo/EXTRA.md": b"new from hub\n"}
        profile_sync.exchange(self.store, exchange_request("peer", hub_id, base, remote))
        self.assertEqual(self.sync(), 0)
        self.assertEqual((self.profile / "skills/demo/EXTRA.md").read_bytes(), b"new from hub\n")

        remote_without_base = {"skills/demo/EXTRA.md": b"new from hub\n"}
        profile_sync.exchange(self.store, exchange_request("peer", hub_id, remote, remote_without_base))
        self.assertEqual(self.sync(), 0)
        self.assertFalse((self.profile / "skills/demo/SKILL.md").exists())
        self.assertTrue((self.profile / "skills/demo/EXTRA.md").exists())

    def test_soul_conflict_does_not_overwrite_local_file(self):
        soul = self.write_profile("SOUL.md", b"common\n")
        self.assertEqual(self.sync(), 0)
        state = profile_sync.json_read(self.state / "client.json")
        hub_id = state["hub_id"]
        base = {"SOUL.md": b"common\n"}
        profile_sync.exchange(self.store, exchange_request("peer", hub_id, base,
                                                            {"SOUL.md": b"remote edit\n"}))
        soul.write_bytes(b"local edit\n")

        self.assertEqual(self.sync(), 2)
        self.assertEqual(soul.read_bytes(), b"local edit\n")
        self.assertIn("SOUL.md", profile_sync.json_read(self.state / "conflicts.json")["paths"])

    def test_client_can_sync_through_local_hub_store(self):
        skill = self.write_profile("skills/demo/SKILL.md", b"local\n")
        self.assertEqual(self.sync(), 0)
        state = profile_sync.json_read(self.state / "client.json")
        self.assertTrue(state["hub_id"])
        self.assertEqual(profile_sync.get_blob(self.store, state["base"]["skills/demo/SKILL.md"]),
                         skill.read_bytes())

    def test_linked_skill_write_materializes_profile_without_touching_external_library(self):
        external = self.root / "shared-skill"
        external.mkdir()
        library_file = external / "SKILL.md"
        library_file.write_bytes(b"version one\n")
        skills = self.profile / "skills"
        skills.mkdir()
        (skills / "shared").symlink_to(external, target_is_directory=True)

        self.assertEqual(self.sync(), 0)
        state = profile_sync.json_read(self.state / "client.json")
        hub_id = state["hub_id"]
        base = {"skills/shared/SKILL.md": b"version one\n"}
        profile_sync.exchange(self.store, exchange_request("peer", hub_id, base,
                                                            {"skills/shared/SKILL.md": b"version two\n"}))

        self.assertEqual(self.sync(), 0)
        self.assertEqual(library_file.read_bytes(), b"version one\n")
        self.assertFalse((skills / "shared").is_symlink())
        self.assertEqual((skills / "shared/SKILL.md").read_bytes(), b"version two\n")
        backups = list((self.state / "backups").glob("*/links/skills/shared.link.json"))
        self.assertEqual(len(backups), 1)

    def test_files_outside_profile_sync_scope_remain_unchanged(self):
        unrelated = self.write_profile("config.yaml", b"keep this config\n")
        self.write_profile("skills/demo/SKILL.md", b"v1\n")
        self.assertEqual(self.sync(), 0)
        state = profile_sync.json_read(self.state / "client.json")
        hub_id = state["hub_id"]
        base = {"skills/demo/SKILL.md": b"v1\n"}
        profile_sync.exchange(self.store, exchange_request("peer", hub_id, base,
                                                            {"skills/demo/SKILL.md": b"v2\n"}))

        self.assertEqual(self.sync(), 0)
        self.assertEqual(unrelated.read_bytes(), b"keep this config\n")


if __name__ == "__main__":
    unittest.main()
