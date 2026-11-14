#!/bin/zsh
# Setup for ClaudeLimits on macOS: build it, install it, show what it found.
#
#   ./install.sh              build, install, offer the shell commands
#   ./install.sh --build-only build and install, ask nothing
#
# Safe to re-run. Nothing is overwritten without asking.
set -e
cd "${0:A:h}"

TOKEN_DIR="${CLAUDE_LIMITS_TOKEN_DIR:-$HOME/.config/claude-multi-account}"
BUILD_ONLY=0
[[ "${1:-}" == "--build-only" ]] && BUILD_ONLY=1

die() { print -u2 -- "$1"; exit 1 }

# ---------------------------------------------------------------- checks ----
[[ "$(uname -s)" == "Darwin" ]] \
  || die "ClaudeLimits is macOS only (it is a menu bar app). Detected: $(uname -s)."
(( ${${(s:.:)$(sw_vers -productVersion)}[1]} >= 13 )) \
  || die "Needs macOS 13 Ventura or newer. Detected: $(sw_vers -productVersion)."
command -v swiftc >/dev/null \
  || die "swiftc not found. Install the Command Line Tools:\n    xcode-select --install"

print -r -- "ClaudeLimits setup  (macOS $(sw_vers -productVersion))"
print -r -- ""

# ----------------------------------------------------------------- build ----
print -r -- "Building..."
log=$(mktemp -t claudelimits-build)
if ! ./build.sh >"$log" 2>&1; then
  print -u2 -- "Build failed:"
  cat "$log" >&2
  rm -f "$log"
  exit 1
fi
rm -f "$log"
print -r -- "Installed to ~/Applications/ClaudeLimits.app and launched."
print -r -- ""

# ----------------------------------------------------------------- shell ----
if (( ! BUILD_ONLY )); then
  print -r -- "Optional: claude-<name> commands per account, plus claude-set-token"
  print -r -- "and claude-whoami."
  print -n -- "Add them to ~/.zshrc? [y/N] "
  read -r reply
  if [[ "$reply" == [yY]* ]]; then
    line="source ${PWD}/contrib/claude-multi-account.zsh"
    if grep -qF "$line" ~/.zshrc 2>/dev/null; then
      print -r -- "  Already in ~/.zshrc."
    else
      cp ~/.zshrc ~/.zshrc.bak.claude-limits.$(date +%Y%m%d-%H%M%S) 2>/dev/null || true
      print -r -- "\n$line" >> ~/.zshrc
      print -r -- "  Added. Run: source ~/.zshrc"
    fi
  fi
  print -r -- ""
fi

# --------------------------------------------------------------- accounts ---
accounts=(${TOKEN_DIR}/*.oauth(N:t:r))
if (( ${#accounts} )); then
  print -r -- "Found ${#accounts} account(s): ${accounts[*]}"
  print -r -- "The meter is in your menu bar, showing them now."
else
  print -r -- "No accounts yet, so the meter has nothing to show. To add one:"
  print -r -- ""
  print -r -- "    claude setup-token         sign in as that account, prints a token"
  print -r -- "    claude-set-token work      paste it; checked and written 0600"
  print -r -- ""
  print -r -- "Or write the token to ${TOKEN_DIR/#$HOME/~}/<name>.oauth yourself."
  print -r -- "See \"Adding accounts\" in the README for why the checks are worth it."
fi

print -r -- ""
print -r -- "Terminal table:  ~/Applications/ClaudeLimits.app/Contents/MacOS/ClaudeLimits --once"
print -r -- "Launch at login: menu -> Settings -> Launch at login"
