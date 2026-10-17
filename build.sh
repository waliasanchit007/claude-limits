#!/bin/zsh
# Rebuild and reinstall ClaudeLimits.app from main.swift
set -e
cd "${0:A:h}"
APP="$HOME/Applications/ClaudeLimits.app"
swiftc -O -o ClaudeLimits main.swift
pkill -f 'ClaudeLimits.app' 2>/dev/null || true
mkdir -p "$APP/Contents/MacOS"
cp ClaudeLimits "$APP/Contents/MacOS/ClaudeLimits"
codesign --force --deep --sign - "$APP"
open "$APP"
echo "rebuilt and relaunched"
