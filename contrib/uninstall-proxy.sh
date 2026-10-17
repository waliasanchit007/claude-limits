#!/bin/zsh
# Removes the proxy LaunchAgent. Leaves ~/.local/share/claude-usage data alone.
PLIST="$HOME/Library/LaunchAgents/local.claude-usage-proxy.plist"
launchctl unload "$PLIST" 2>/dev/null || true
rm -f "$PLIST"
print -r -- "LaunchAgent removed. Sessions fall back to direct connections."
print -r -- "Data kept at ~/.local/share/claude-usage (delete manually if unwanted)."
