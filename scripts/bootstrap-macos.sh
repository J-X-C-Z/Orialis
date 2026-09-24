#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MOBILE="$ROOT/mobile"

cd "$MOBILE"

flutter create   --platforms=macos   --org app.orialis   --project-name orialis_mobile   .

echo "macOS Runner is ready."
echo "Run: cd mobile && flutter run -d macos"
