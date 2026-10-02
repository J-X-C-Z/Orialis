#!/bin/bash
# Run by the product path owner after creating the macOS host and desktop entry.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
check_only=false
if [[ "${1:-}" == --check ]]; then
  check_only=true
  shift
fi
if [[ $# != 1 ]]; then
  echo 'Usage: bash desktop/build-macos-release.sh [--check] lib/<desktop-entry>.dart' >&2
  exit 2
fi
entry="$1"
case "$entry" in
  lib/*.dart) ;;
  *) echo 'Provide an explicit Dart entry relative to mobile/lib.' >&2; exit 2 ;;
esac
case "/$entry/" in
  */../*|*/./*) echo 'Entry must not contain traversal segments.' >&2; exit 2 ;;
esac
if [[ ! -f "$repo_root/mobile/macos/Runner.xcodeproj/project.pbxproj" ]]; then
  echo 'Product macOS host is missing: mobile/macos/Runner.xcodeproj/project.pbxproj' >&2
  exit 1
fi
if [[ ! -f "$repo_root/mobile/$entry" ]]; then
  echo "Desktop entry is missing: mobile/$entry" >&2
  exit 1
fi
if "$check_only"; then
  echo "Product build inputs exist: mobile/macos and mobile/$entry"
  exit 0
fi
source "$repo_root/desktop/prepare-macos-toolchain.sh"
cd "$repo_root/mobile"
flutter pub get
flutter build macos --release --target "$entry"
apps=()
for candidate in build/macos/Build/Products/Release/*.app; do
  [[ -d "$candidate" ]] && apps+=("$candidate")
done
if [[ ${#apps[@]} != 1 ]]; then
  echo 'Expected exactly one product app in the release output.' >&2
  exit 1
fi
app="${apps[0]}"
app_name="$(basename "$app")"
# Xcode can retain the old outer seal when Flutter updates only App.framework.
# Preserve the rejected generated bundle and rebuild it once so Xcode signs a
# fresh product. Never replace the signature or weaken the verification check.
if ! codesign --verify --deep --strict "$app"; then
  rejected="${PAPERCLIP_SCRATCH_DIR:-${PAPERCLIP_RUN_SCRATCH_DIR:-}}/orialis-rejected-release-$$"
  mkdir -p "$rejected"
  mv "$app" "$rejected/$app_name"
  echo "Rebuilding rejected incremental bundle; previous output: $rejected"
  flutter build macos --release --target "$entry"
  [[ -d "$app" ]]
  codesign --verify --deep --strict "$app"
fi
executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")"
[[ -f "$app/Contents/MacOS/$executable" ]]
archs="$(lipo -archs "$app/Contents/MacOS/$executable")"
case " $archs " in
  *' arm64 '*) ;;
  *) echo "Release does not include host arm64 architecture: $archs" >&2; exit 1 ;;
esac
output="$repo_root/desktop/dist/$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$output"
ditto -c -k --sequesterRsrc --keepParent "$app" "$output/Orialis-macos.zip"
shasum -a 256 "$output/Orialis-macos.zip" > "$output/SHA256SUMS"
{
  echo "Built at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Entry: $entry"
  echo "App: $app_name"
  echo "Architectures: $archs"
  echo "HEAD: $(git -C "$repo_root" rev-parse HEAD)"
  echo 'Worktree status (build includes local modifications):'
  git -C "$repo_root" status --short
  xcodebuild -version
  flutter --version
  echo 'This records build and signature verification; launch and business acceptance remain required.'
} > "$output/build-evidence.txt"
echo "Release archive: $output/Orialis-macos.zip"
echo "Extract, then run: open <extracted-directory>/$app_name"
