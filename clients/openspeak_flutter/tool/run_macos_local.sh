#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_DIR="${TMPDIR:-/tmp}/openspeak_flutter_run"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This helper is only for macOS." >&2
  exit 1
fi

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

rsync -a \
  --exclude '.dart_tool' \
  --exclude '.idea' \
  --exclude 'build' \
  "$PROJECT_DIR/" "$WORK_DIR/"

# Flutter macOS builds can fail codesign when the source lives on a NAS/share.
# Building from a local temp copy avoids resource-fork and extended-attribute
# detritus on generated frameworks.
xattr -cr "$WORK_DIR" 2>/dev/null || true

cd "$WORK_DIR"
flutter pub get
flutter run -d macos "$@"
