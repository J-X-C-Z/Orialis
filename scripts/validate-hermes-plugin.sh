#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
plugin_dir="$repo_root/integrations/hermes/orialis"
python_bin="${HERMES_PYTHON:-python3}"
hermes_bin="${HERMES_CLI:-}"

if ! command -v "$python_bin" >/dev/null 2>&1 && [[ ! -x "$python_bin" ]]; then
  echo "Hermes Python was not found: $python_bin" >&2
  echo "Set HERMES_PYTHON to the Python executable in the Hermes runtime." >&2
  exit 2
fi

if [[ -z "$hermes_bin" ]]; then
  python_path="$(command -v "$python_bin" 2>/dev/null || true)"
  if [[ -z "$python_path" && -x "$python_bin" ]]; then
    python_path="$python_bin"
  fi
  hermes_bin="$(dirname "$python_path")/hermes"
fi

if [[ ! -x "$hermes_bin" ]]; then
  echo "Hermes CLI was not found alongside the selected Python: $hermes_bin" >&2
  echo "Set HERMES_CLI to the Hermes executable in the same runtime." >&2
  exit 2
fi

if ! "$python_bin" -c 'import gateway' >/dev/null 2>&1; then
  echo "The selected Python does not expose Hermes' gateway package: $python_bin" >&2
  echo "Set HERMES_PYTHON to the Python executable in the Hermes runtime." >&2
  exit 2
fi

"$hermes_bin" plugins validate "$plugin_dir"
"$python_bin" -m py_compile "$plugin_dir"/*.py
PYTHONPATH="$repo_root" "$python_bin" -m unittest discover \
  -s "$plugin_dir" \
  -t "$repo_root" \
  -p 'test_*.py'
