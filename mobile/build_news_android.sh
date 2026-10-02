#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
cd "$script_dir"
variant=debug
platform_args=()
for option in "$@"; do
  case "$option" in
    --release) variant=release ;;
    --arm64) platform_args+=("--target-platform=android-arm64") ;;
    --help)
      printf 'Usage: %s [--release] [--arm64]\n' "$0"
      printf 'Release uses the existing local signing configuration.\n'
      exit 0
      ;;
    *) printf 'Unknown option: %s\n' "$option" >&2; exit 2 ;;
  esac
done
# Use the installed Android Studio runtime
# when macOS has no separately registered JAVA_HOME.
if [[ -z "${JAVA_HOME:-}" && -x "/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/java" ]]; then
  export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
fi
# Let Flutter regenerate plugin registration for the selected build mode.
# Raw Gradle release builds can otherwise retain debug-only test plugins.
ORG_GRADLE_PROJECT_newsApp=true flutter build apk "--$variant" \
  --target=lib/main_news.dart "${platform_args[@]}"
printf 'News APK: %s\n' "$script_dir/build/app/outputs/apk/$variant/app-$variant.apk"
