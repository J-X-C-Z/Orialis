#!/usr/bin/env python3
"""Regenerate a synthetic corpus using the pinned upstream implementation.

Only definitions are loaded via AST, without upstream import-time profile discovery
or optional package dependencies. Store I/O is replaced with an in-memory commit;
the original matching and batch implementation are executed unchanged.
"""
import ast
import contextlib
import contextvars
import itertools
import json
import logging
from pathlib import Path
import re
import sys
import types
from typing import Any, Dict, List, Optional, Tuple

ROOT = Path(__file__).resolve().parents[2]
source = ROOT / "upstream-hermes/tools/memory_tool_store.py"
module = ast.parse(source.read_text())
allowed = (ast.FunctionDef, ast.ClassDef, ast.Assign, ast.AnnAssign)
statements = [n for n in module.body if isinstance(n, allowed)]
namespace = dict(globals(), contextmanager=contextlib.contextmanager,
                 suppress=contextlib.suppress, ContextVar=contextvars.ContextVar,
                 _first_threat_message=lambda *args, **kwargs: None)
exec(compile(ast.Module(body=statements, type_ignores=[]), str(source), "exec"), namespace)
Store = namespace["MemoryStore"]
fake = types.ModuleType("tools.memory_tool")
fake._memory_target_error = lambda *args: None
sys.modules["tools.memory_tool"] = fake
Store._path_for = staticmethod(lambda target: Path("USER.md" if target == "user" else "MEMORY.md"))

def mutate(self, target, apply, **kwargs):
    result = apply(list(self._entries_for(target)), self._char_limit(target))
    if isinstance(result, dict):
        return result
    self._set_entries(target, result[0])
    return self._success_response(target, result[1], **(result[2] if len(result) > 2 else {}))
Store._mutate = mutate

match_inputs = [
    (["tea", "drinks tea daily"], "tea"),
    (["tea", "drinks tea daily"], "drinks"),
    (["tea", "drinks tea daily"], "te"),
    (["duplicate", "duplicate"], "duplicate"),
    (["prefers “green” tea — cold"], "'green' tea - cold"),
    (["text with\nwhitespace"], "text with\\nwhitespace"),
    (["first", "second"], "absent"),
    (["a ’"], "'"),
    (["punctuation!"], "!"),
]
batches = [
    (["tea"], [{"action": "add", "content": "tea"}], 1),
    (["12345"], [{"action": "add", "content": "6789"}, {"action": "remove", "old_text": "123"}], 4),
    (["drinks tea daily"], [{"action": "patch", "old_text": "tea ", "new_text": "coffee "}], 30),
    (["1000"], [{"action": "patch", "old_text": "00", "content": "2"}], 30),
    (["one", "two"], [{"action": "remove", "old_text": "one"}, {"action": "remove", "old_text": "two"}], 30),
    (["one"], [{"action": "remove", "old_text": "one"}], 0),
    (["one", "much-too-long"], [{"action": "remove", "old_text": "one"}], 1),
    (["one", "two"], [{"action": "remove", "old_text": "one"}, {"action": "remove", "old_text": "absent"}], 30),
    (["old"], [{"action": "replace", "old_text": "old", "content": "new", "matched_entry": "stale"}], 30),
    (["old"], [{"action": "replace", "old_text": "o", "content": "new"}], 30),
    (["a “quote”"], [{"action": "patch", "old_text": '"quote"', "content": "word"}], 30),
    (["one"], [], 30),
    (["one"], [{"action": "add", "content": "too long"}], 5),
]
result = {"upstream_commit": "36b98bcced7f3c22d08dd1119240e726b3928e3d", "matches": [], "batches": []}
for entries, old in match_inputs:
    i, ambiguous = namespace["_find_unique_match"](entries, old)
    result["matches"].append(dict(entries=entries, old_text=old, index=i, ambiguous=ambiguous))
for entries, operations, limit in batches:
    store = Store(memory_char_limit=limit)
    store.memory_entries = entries[:]
    reply = store.apply_batch("memory", operations)
    result["batches"].append(dict(entries=entries, operations=operations, limit=limit,
                                  success=reply["success"], final_entries=store.memory_entries))
path = Path(__file__).resolve().parent / "fixtures/hermes_memory_corpus.json"
path.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
print(f"Wrote {len(result['matches'])} matching cases and {len(result['batches'])} batch cases")
