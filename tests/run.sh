#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/dist"
xcrun clang -fmodules -fsanitize=address -g -I "$ROOT/vendor/m1ddc/headers" \
  "$ROOT/tests/ddc_packets.m" "$ROOT/vendor/m1ddc/sources/i2c.m" \
  -framework Foundation -framework IOKit -o "$ROOT/dist/test-ddc"
"$ROOT/dist/test-ddc"
xcrun clang -fobjc-arc -fblocks -Wall -Wextra "$ROOT/tests/selected-device-policy.m" \
  -framework Foundation -framework IOKit -framework CoreGraphics -o "$ROOT/dist/test-selected-policy"
"$ROOT/dist/test-selected-policy"
python3 "$ROOT/tests/video-failure-policy.py"
"$ROOT/display-handoff" --dry-run
if [ -d "$ROOT/dist/双机切换.app" ]; then
  codesign --verify --deep --strict "$ROOT/dist/双机切换.app"
fi
echo 'Non-interactive checks passed (no display or input routing changed)'
