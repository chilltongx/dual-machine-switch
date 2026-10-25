#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/双机切换.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun clang -fobjc-arc -fblocks -Wall -Wextra "$ROOT/macos/DisplayProfile.m" -framework Foundation -framework CoreGraphics -framework ColorSync -o "$APP/Contents/Resources/display-profile"
codesign --force --sign - "$APP/Contents/Resources/display-profile"
xcrun clang -fobjc-arc -fblocks -O2 -Wall -Wextra -c "$ROOT/selective-input/Router.m" -o "$ROOT/dist/SelectiveRouter.o"
xcrun swiftc -O -import-objc-header "$ROOT/selective-input/Router.h" "$ROOT/macos/SelectiveSwitch.swift" "$ROOT/dist/SelectiveRouter.o" -o "$APP/Contents/MacOS/DualSwitch" -framework AppKit -framework Carbon -framework IOKit -framework CoreGraphics
xcrun swift "$ROOT/macos/Icon.swift" "$ROOT/dist/AppIcon.iconset"
iconutil -c icns "$ROOT/dist/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
make -C "$ROOT/vendor/m1ddc"
cp "$ROOT/vendor/m1ddc/m1ddc" "$APP/Contents/Resources/m1ddc"
cp "$ROOT/vendor/m1ddc/LICENSE" "$APP/Contents/Resources/m1ddc-LICENSE"
cp "$ROOT/display-handoff" "$APP/Contents/Resources/display-handoff"
codesign --force --sign - "$APP/Contents/Resources/m1ddc"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>DualSwitch</string>
<key>CFBundleIdentifier</key><string>local.chilltong.dual-switch</string>
<key>CFBundleName</key><string>双机切换</string>
<key>CFBundleDisplayName</key><string>双机切换</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleVersion</key><string>5</string>
<key>CFBundleShortVersionString</key><string>0.5</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
