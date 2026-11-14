#!/bin/zsh
# One-step setup for ClaudeLimits on macOS: build, install, add an account.
#
#   ./install.sh              build, install, then offer each optional step
#   ./install.sh --build-only just build and install the app
#
# Safe to re-run. Nothing is overwritten without asking.
set -e
cd "${0:A:h}"

TOKEN_DIR="${CLAUDE_LIMITS_TOKEN_DIR:-$HOME/.config/claude-multi-account}"
BUILD_ONLY=0
[[ "${1:-}" == "--build-only" ]] && BUILD_ONLY=1

die() { print -u2 -- "$1"; exit 1 }
ask() {  # ask "question" -> 0 for yes
  local r; print -n -- "$1 [y/N] "; read -r r; [[ "$r" == [yY]* ]]
}

# ---------------------------------------------------------------- checks ----
[[ "$(uname -s)" == "Darwin" ]] || die "ClaudeLimits is macOS only (menu bar app). Detected: $(uname -s)."
(( ${${(s:.:)$(sw_vers -productVersion)}[1]} >= 13 )) \
  || die "Needs macOS 13 Ventura or newer. Detected: $(sw_vers -productVersion)."
command -v swiftc >/dev/null \
  || die "swiftc not found. Install the Command Line Tools:\n    xcode-select --install"

print -r -- "ClaudeLimits setup"
print -r -- "macOS $(sw_vers -productVersion), $(swiftc --version 2>/dev/null | head -1)"
print -r -- ""

# ----------------------------------------------------------------- build ----
print -r -- "[1/3] Building..."
./build.sh >/dev/null || die "Build failed. Run ./build.sh directly to see why."
print -r -- "      Installed to ~/Applications/ClaudeLimits.app and launched."
print -r -- ""
(( BUILD_ONLY )) && { print -r -- "Done."; exit 0 }

# ----------------------------------------------------------------- token ----
print -r -- "[2/3] Add a Claude account"
print -r -- ""
if ask "      Add one now?"; then
  print -n -- "      Name for this account (e.g. work): "
  read -r name
  [[ -n "$name" ]] || die "No name given."
  f="$TOKEN_DIR/$name.oauth"
  if [[ -e "$f" ]]; then
    ask "      $f exists. Overwrite?" || die "Aborted."
  fi
  print -r -- ""
  print -r -- "      In another terminal, sign in as that account and run:"
  print -r -- "          claude setup-token"
  print -r -- ""
  print -r -- "      Paste the token below (input is hidden), then press Enter twice."
  print -n -- "      > "
  tok=""
  while IFS= read -rs line; do
    [[ -z "${line//[[:space:]]/}" ]] && break
    tok+="${line//[[:space:]]/}"       # strip wrapping introduced by the terminal
  done
  print -r -- ""
  [[ "$tok" == sk-ant-oat01-* ]] \
    || die "      That is not a setup-token (expected it to start sk-ant-oat01-). Nothing written."
  n=${#tok}
  if (( n % 2 == 0 )) && [[ "${tok[1,n/2]}" == "${tok[n/2+1,n]}" ]]; then
    tok="${tok[1,n/2]}"
    print -r -- "      Note: token was pasted twice; collapsed to one."
  fi
  stripped="${tok//sk-ant-oat01-/}"
  (( (${#tok} - ${#stripped}) / 13 <= 1 )) \
    || die "      More than one token pasted. Nothing written."
  (( ${#tok} >= 100 && ${#tok} <= 130 )) \
    || die "      Token is ${#tok} characters, expected about 108. Nothing written."
  mkdir -p "$TOKEN_DIR"
  ( umask 077; print -r -- "$tok" > "$f" )
  chmod 600 "$f"
  print -r -- "      Wrote $f (${#tok} chars, mode 600)."
  print -r -- "      The meter picks it up on its next refresh."
else
  print -r -- "      Skipped. Add accounts any time by dropping a token file in"
  print -r -- "      $TOKEN_DIR/<name>.oauth"
fi
print -r -- ""

# ---------------------------------------------------------------- shell -----
print -r -- "[3/3] Optional shell commands"
print -r -- ""
print -r -- "      Adds claude-<name> per account, plus claude-set-token for"
print -r -- "      adding more accounts later with the same checks used above."
if ask "      Add to ~/.zshrc?"; then
  line="source ${PWD}/contrib/claude-multi-account.zsh"
  if grep -qF "$line" ~/.zshrc 2>/dev/null; then
    print -r -- "      Already present in ~/.zshrc."
  else
    cp ~/.zshrc ~/.zshrc.bak.claude-limits.$(date +%Y%m%d-%H%M%S) 2>/dev/null || true
    print -r -- "\n$line" >> ~/.zshrc
    print -r -- "      Added. Run: source ~/.zshrc"
  fi
else
  print -r -- "      Skipped."
fi

print -r -- ""
print -r -- "Done. The meter is in your menu bar now."
print -r -- "Terminal table:  ~/Applications/ClaudeLimits.app/Contents/MacOS/ClaudeLimits --once"
print -r -- "Launch at login: menu -> Settings -> Launch at login"
