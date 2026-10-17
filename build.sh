#!/bin/zsh
# Build ClaudeLimits.app into ~/Applications and launch it.
set -e
cd "${0:A:h}"
APP="${CLAUDE_LIMITS_APP:-$HOME/Applications/ClaudeLimits.app}"

command -v swiftc >/dev/null || { print -u2 "swiftc not found - install Xcode Command Line Tools"; exit 1 }

swiftc -O -o ClaudeLimits main.swift
pkill -f 'ClaudeLimits.app' 2>/dev/null || true
mkdir -p "$APP/Contents/MacOS"
cp ClaudeLimits "$APP/Contents/MacOS/ClaudeLimits"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ClaudeLimits</string>
  <key>CFBundleDisplayName</key><string>Claude Limits</string>
  <key>CFBundleIdentifier</key><string>local.claudelimits</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleExecutable</key><string>ClaudeLimits</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
open "$APP"
print -r -- "built and launched $APP"
