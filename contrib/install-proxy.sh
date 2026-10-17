#!/bin/zsh
# Installs the usage proxy as a LaunchAgent (RunAtLoad + KeepAlive).
#
# Installs only:
#   ~/.local/src/claude-usage-proxy/usage-proxy.py
#   ~/.local/share/claude-usage/            (data + logs)
#   ~/Library/LaunchAgents/local.claude-usage-proxy.plist
#
# It does not touch your shell config. Add the guard yourself (see README), or
# source contrib/claude-multi-account.zsh which already includes it.
set -e
cd "${0:A:h}"

PORT="${1:-8787}"
SRC="$HOME/.local/src/claude-usage-proxy"
DATA="$HOME/.local/share/claude-usage"
PLIST="$HOME/Library/LaunchAgents/local.claude-usage-proxy.plist"

mkdir -p "$SRC" "$DATA" "$HOME/Library/LaunchAgents"
cp usage-proxy.py "$SRC/usage-proxy.py"
print -r -- "installed $SRC/usage-proxy.py"

cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>local.claude-usage-proxy</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/python3</string>
    <string>$SRC/usage-proxy.py</string>
    <string>$PORT</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$DATA/stdout.log</string>
  <key>StandardErrorPath</key><string>$DATA/stderr.log</string>
</dict>
</plist>
PLISTEOF

plutil -lint "$PLIST" >/dev/null
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
print -r -- "loaded LaunchAgent on port $PORT"

for i in {1..10}; do
  if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then
    print -r -- "proxy is listening on 127.0.0.1:$PORT"
    print -r -- ""
    print -r -- "Verify end to end:"
    print -r -- "  ANTHROPIC_BASE_URL=http://127.0.0.1:$PORT claude -p hi"
    print -r -- "  cat $DATA/usage.json"
    exit 0
  fi
  sleep 1
done
print -u2 "proxy did not come up; check $DATA/stderr.log"
exit 1
