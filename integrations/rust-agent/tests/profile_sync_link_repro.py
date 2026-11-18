#!/usr/bin/env python3
"""Compare a sync executable and pinned Python on new linked-skill assets.

Only disposable local profiles/hubs are used. A failing candidate produces JSON
evidence and exit 1; no frozen artifact is modified.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile


def probe(command):
    with tempfile.TemporaryDirectory(prefix="profile-sync-link-contract-") as tmp:
        root = Path(tmp)
        library = root / "library"
        library.mkdir()
        (library / "SKILL.md").write_bytes(b"shared skill\n")
        (root / "a/skills").mkdir(parents=True)
        (root / "a/skills/shared").symlink_to(library, target_is_directory=True)
        (root / "b").mkdir()
        configs = {}
        for node in ("a", "b"):
            config = root / f"{node}.json"
            config.write_text(json.dumps({
                "profile": str(root / node),
                "state_dir": str(root / f"{node}-state"),
                "node": node,
                "hub_store": str(root / "hub"),
                "allowed_skill_roots": [str(library)],
            }))
            configs[node] = config

        def sync(node):
            return subprocess.run(
                [*command, "sync", "--config", str(configs[node])],
                capture_output=True, text=True, timeout=30, check=False,
            )

        for node in ("a", "b"):
            result = sync(node)
            if result.returncode:
                raise RuntimeError(f"Bootstrap {node} failed: {result.stderr}")
        relative = "skills/shared/assets/nested/template.bin"
        asset = root / "b" / relative
        asset.parent.mkdir(parents=True)
        expected = b"\x00\xffsupport\r\n\x80"
        asset.write_bytes(expected)
        result = sync("b")
        if result.returncode:
            raise RuntimeError(f"Publishing support asset failed: {result.stderr}")
        result = sync("a")
        installed = root / "a" / relative
        library_unchanged = (
            (library / "SKILL.md").read_bytes() == b"shared skill\n"
            and not (library / "assets").exists()
        )
        installed_exactly = installed.is_file() and installed.read_bytes() == expected
        return {
            "returncode": result.returncode,
            "stderr": result.stderr.strip(),
            "stdout": result.stdout.strip(),
            "library_unchanged": library_unchanged,
            "skill_link_materialized": not (root / "a/skills/shared").is_symlink(),
            "binary_installed_exactly": installed_exactly,
            "passed": result.returncode == 0 and installed_exactly and library_unchanged,
        }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--python-script", type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    report = {
        "candidate_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "candidate": probe([str(binary)]),
    }
    if args.python_script:
        script = args.python_script.resolve(strict=True)
        report["reference_sha256"] = hashlib.sha256(script.read_bytes()).hexdigest()
        report["reference"] = probe([sys.executable, str(script)])
    print(json.dumps(report, indent=2))
    return 0 if report["candidate"]["passed"] and report.get("reference", {"passed": True})["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
