#!/bin/bash
# Source this file to retain the environment for later Flutter commands.
orialis_prepare_macos_toolchain() {
  local scratch="${PAPERCLIP_SCRATCH_DIR:-${PAPERCLIP_RUN_SCRATCH_DIR:-}}"
  if [[ -z "$scratch" || ! -d "$scratch" ]]; then
    echo 'Set PAPERCLIP_SCRATCH_DIR to an existing writable scratch directory.' >&2
    return 1
  fi
  local sdk_source="${ORIALIS_FLUTTER_SOURCE:-/opt/homebrew/share/flutter}"
  local cache_source="${ORIALIS_PUB_CACHE_SOURCE:-$HOME/.pub-cache}"
  export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
  xcodebuild -version || return 1
  xcodebuild -checkFirstLaunchStatus || return 1
  mkdir -p "$scratch/orialis-toolchain/config" || return 1
  if [[ ! -d "$scratch/orialis-toolchain/flutter" ]]; then
    cp -cR "$sdk_source" "$scratch/orialis-toolchain/flutter" || return 1
  fi
  if [[ ! -d "$scratch/orialis-toolchain/pub-cache" ]]; then
    if [[ -d "$cache_source" ]]; then
      cp -cR "$cache_source" "$scratch/orialis-toolchain/pub-cache" || return 1
    else
      mkdir -p "$scratch/orialis-toolchain/pub-cache" || return 1
    fi
  fi
  mkdir -p "$scratch/orialis-toolchain/bin" "$scratch/orialis-toolchain/tmp" \
    "$scratch/orialis-toolchain/xcode-cache" "$scratch/orialis-toolchain/clang-cache"
  # Flutter invokes xcodebuild through xcrun, including package-resolution queries.
  # Keep their caches in allowed directories without changing global defaults.
  cat > "$scratch/orialis-toolchain/bin/xcrun" <<'WRAPPER'
#!/bin/bash
if [[ "${1:-}" == xcodebuild ]]; then
  shift
  exec /usr/bin/xcrun xcodebuild \
    -IDECustomDerivedDataLocation="$ORIALIS_XCODE_CACHE/DerivedData" \
    -packageCachePath "$ORIALIS_XCODE_CACHE/Packages" "$@"
fi
exec /usr/bin/xcrun "$@"
WRAPPER
  chmod +x "$scratch/orialis-toolchain/bin/xcrun"
  export ORIALIS_XCODE_CACHE="$scratch/orialis-toolchain/xcode-cache"
  export TMPDIR="$scratch/orialis-toolchain/tmp/"
  export CLANG_MODULE_CACHE_PATH="$scratch/orialis-toolchain/clang-cache"
  export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
  export PUB_CACHE="$scratch/orialis-toolchain/pub-cache"
  export XDG_CONFIG_HOME="$scratch/orialis-toolchain/config"
  export CP_HOME_DIR="$scratch/orialis-toolchain/cocoapods"
  export CP_CACHE_DIR="$scratch/orialis-toolchain/pod-cache"
  export COCOAPODS_DISABLE_STATS=true
  export CI=true FLUTTER_SUPPRESS_ANALYTICS=true
  export PATH="$scratch/orialis-toolchain/bin:$scratch/orialis-toolchain/flutter/bin:$PATH"
  flutter --version
  # This local Runner uses CocoaPods while SwiftPM writes outside allowed paths.
  # XDG_CONFIG_HOME scopes this preference to the run, not the user's SDK.
  flutter config --no-enable-swift-package-manager
}
orialis_prepare_macos_toolchain
orialis_toolchain_status=$?
unset -f orialis_prepare_macos_toolchain
return "$orialis_toolchain_status" 2>/dev/null || exit "$orialis_toolchain_status"
