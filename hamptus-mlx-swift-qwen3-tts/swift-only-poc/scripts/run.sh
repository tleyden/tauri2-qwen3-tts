#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

BUILD_DIR="${BUILD_DIR:-$HOME/Library/Developer/Xcode/DerivedData/swift-only-poc-fmhvmtkwonqmqoebsajlnhrblhhe/Build/Products/Debug}"
BINARY="$BUILD_DIR/Qwen3TTSPoc"

if [[ ! -x "$BINARY" ]]; then
  cat >&2 <<EOF
Qwen3TTSPoc binary was not found at:
  $BINARY

Build it first:
  xcodebuild build -scheme Qwen3TTSPoc -destination 'platform=macOS' -skipPackagePluginValidation

Or override the build products directory:
  BUILD_DIR=/path/to/Build/Products/Debug scripts/run.sh
EOF
  exit 1
fi

DYLD_FRAMEWORK_PATH="$BUILD_DIR:$BUILD_DIR/PackageFrameworks${DYLD_FRAMEWORK_PATH:+:$DYLD_FRAMEWORK_PATH}" "$BINARY" "$@"
