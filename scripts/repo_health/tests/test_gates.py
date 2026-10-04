import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from types import SimpleNamespace

from scripts.repo_health.check_changed_artifacts import validate
from scripts.repo_health.clippy_diagnostics import capture, compare


def warning(text="unused variable", line="let x = 1;", row=1):
    return {
        "level": "warning",
        "code": {"code": "unused_variables"},
        "package_id": "path+file:///tmp/checkout#orio-server@0.1.0",
        "target": {"name": "orio-server", "kind": ["lib"]},
        "message": text,
        "spans": [{"is_primary": True, "file_name": "orialis-server/src/lib.rs",
                   "line_start": row, "column_start": 4, "label": "unused",
                   "text": [{"text": line, "highlight_start": 1, "highlight_end": 2}]}],
    }


class ClippyComparatorFixtures(unittest.TestCase):
    def test_same_baseline_passes_even_if_positions_shift(self):
        added, removed, *_ = compare([warning()], [warning(row=88)], Path.cwd())
        self.assertEqual((added, removed), (0, 0))

    def test_one_added_warning_fails(self):
        added, _, *_ = compare([], [warning()], Path.cwd())
        self.assertEqual(added, 1)

    def test_removed_warning_passes(self):
        added, removed, *_ = compare([warning()], [], Path.cwd())
        self.assertEqual((added, removed), (0, 1))

    def test_duplicate_warning_count_is_detected(self):
        added, _, *_ = compare([warning()], [warning(), warning()], Path.cwd())
        self.assertEqual(added, 1)

    def test_cargo_process_failure_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "diagnostics.jsonl"
            failed = SimpleNamespace(stdout="", stderr="cargo failed", returncode=101)
            with patch("scripts.repo_health.clippy_diagnostics.subprocess.run", return_value=failed):
                self.assertEqual(capture(output, Path(directory)), 101)
            self.assertEqual(output.read_text(), "")


class ArtifactCheckerFixtures(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        subprocess.run(["git", "init", "-q"], cwd=self.root, check=True)
        subprocess.run(["git", "config", "user.email", "fixture@example.invalid"], cwd=self.root, check=True)
        subprocess.run(["git", "config", "user.name", "Fixture"], cwd=self.root, check=True)

    def tearDown(self):
        self.temp.cleanup()

    def commit(self):
        subprocess.run(["git", "add", "-A"], cwd=self.root, check=True)
        subprocess.run(["git", "commit", "-qm", "fixture"], cwd=self.root, check=True)
        return subprocess.run(["git", "rev-parse", "HEAD"], cwd=self.root, check=True,
                              text=True, capture_output=True).stdout.strip()

    def test_forbidden_build_output_fails(self):
        result = validate(self.root, ["mobile/build/app.apk", "uploads/test.bin"], "HEAD", {})
        self.assertTrue(any("forbidden changed path" in problem for problem in result))

    def test_generated_source_and_product_asset_pass(self):
        (self.root / "mobile/lib/model.g.dart").parent.mkdir(parents=True)
        (self.root / "mobile/lib/model.g.dart").write_text("// generated fixture\n")
        (self.root / "mobile/assets").mkdir(parents=True)
        (self.root / "mobile/assets/product.png").write_bytes(b"PNG fixture")
        head = self.commit()
        result = validate(self.root, ["mobile/lib/model.g.dart", "mobile/assets/product.png"], head, {})
        self.assertEqual(result, [])

    def test_unlisted_oversized_blob_fails(self):
        (self.root / "assets/large-resource.bin").parent.mkdir()
        (self.root / "assets/large-resource.bin").write_bytes(b"x" * 1025)
        head = self.commit()
        result = validate(self.root, ["assets/large-resource.bin"], head, {}, max_bytes=1024)
        self.assertTrue(any("oversized new blob" in problem for problem in result))

    def test_exact_allowlisted_sdk_blob_passes(self):
        (self.root / "sdk").mkdir()
        (self.root / "sdk/necessary.bin").write_bytes(b"x" * 1025)
        head = self.commit()
        blob = subprocess.run(["git", "rev-parse", f"{head}:sdk/necessary.bin"], cwd=self.root,
                              check=True, text=True, capture_output=True).stdout.strip()
        allowlist = {"sdk/necessary.bin": {"blob_id": blob, "rationale": "fixture SDK required by product"}}
        self.assertEqual(validate(self.root, ["sdk/necessary.bin"], head, allowlist, 1024), [])


if __name__ == "__main__":
    unittest.main()
