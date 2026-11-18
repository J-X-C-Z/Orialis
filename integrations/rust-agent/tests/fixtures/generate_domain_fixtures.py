#!/usr/bin/env python3
"""Regenerate local contract goldens from the fixed upstream checkout; no network."""
import argparse
import hashlib
import importlib
import json
import math
from pathlib import Path
import random
import struct
import subprocess
import sys

PIN = "f9a064bf05b18265afd26905e7240777d4ce355c"
p = argparse.ArgumentParser()
p.add_argument("orialis_checkout", type=Path)
args = p.parse_args()
source = args.orialis_checkout.resolve()
if subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip() != PIN:
    raise SystemExit("Refusing to regenerate from a different upstream commit")
sys.dont_write_bytecode = True
sys.path.insert(0, str(source / "integrations/hermes"))
tools = importlib.import_module("orialis.tools")
root = Path(__file__).resolve().parents[2]
contract = {
    "source_commit": PIN,
    "source_file": "integrations/hermes/orialis/tools.py",
    "source_sha256": hashlib.sha256((source / "integrations/hermes/orialis/tools.py").read_bytes()).hexdigest(),
    "schemas": {name: tools.HANDLERS[name][0] for name in tools.TOOL_NAMES},
    "tool_names": tools.TOOL_NAMES,
    "domain_contracts": tools.DOMAIN_CONTRACTS,
    "operations": tools.PLUGIN_OPERATIONS,
    "response_ui": tools.RESPONSE_UI,
    "event_granularity_rules": tools.EVENT_GRANULARITY_RULES,
}
(root / "src/domain_tools/upstream_contract.json").write_text(json.dumps(contract, ensure_ascii=False, indent=2) + "\n")
values = [
    [],
    [{"repository": "中/文", "stars": 1.0, "score": 0.00001}],
    {"repositories": [], "z": 1e20, "a": 0.0001, "q": 1e15, "n": -0.0},
    {"repositories": [], "numbers": [1e-6, 1e-7, 1e-4, 1e16, 1.2e20, -1e-5, 0.1, 1.2345678901234567, 1e100]},
]
rng = random.Random(20261114)
numbers = [struct.unpack("!d", rng.getrandbits(64).to_bytes(8, "big"))[0] for _ in range(100)]
values.append({"repositories": [], "numbers": [n for n in numbers if math.isfinite(n)]})
values.append({"repositories": [], "integers": [2**64, -(2**80), 10**100 + 1]})
rows = []
for result in values:
    payload = {"source": "githot.dev", "result": result}
    canonical = json.dumps(["github.daily", payload], ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False)
    rows.append({"arguments": {"dataset": "github.daily", "result": result}, "canonical": canonical,
                 "id": "hermes-news-" + hashlib.sha256(canonical.encode()).hexdigest()})
(root / "tests/fixtures/news_idempotency.json").write_text(json.dumps(rows, ensure_ascii=False, indent=2) + "\n")
print(f"Generated {len(tools.TOOL_NAMES)} tool contracts and {len(rows)} Python publisher fixtures.")
