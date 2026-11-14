# Multi-account wrappers for Claude Code.
#
#   source /path/to/claude-multi-account.zsh
#
# Each account is one file: ~/.config/claude-multi-account/<name>.oauth
# containing a single token from `claude setup-token`. Profiles are discovered
# automatically — no per-account lines to maintain. A file named work.oauth
# gives you `claude-work`.
#
# Files under a disabled/ subdirectory are ignored.

: ${CLAUDE_MULTI_DIR:="$HOME/.config/claude-multi-account"}
: ${CLAUDE_PROXY_PORT:=8787}

# True if the local usage proxy is accepting connections. Uses zsh's built-in TCP
# module so this costs no subprocess per launch.
_claude_proxy_up() {
  zmodload -F zsh/net/tcp b:ztcp 2>/dev/null || return 1
  if ztcp 127.0.0.1 "$CLAUDE_PROXY_PORT" 2>/dev/null; then
    ztcp -c "$REPLY" 2>/dev/null
    return 0
  fi
  return 1
}

_claude_multi_token() {
  local f="$CLAUDE_MULTI_DIR/$1.oauth"
  if [[ ! -r "$f" ]]; then
    print -u2 "No token for '$1' (expected $f)"
    print -u2 "Create one with:  claude setup-token   then:  claude-set-token $1"
    return 1
  fi
  print -r -- "$(<"$f")"
}

_claude_multi_run() {
  local profile="$1"; shift
  local token claude_bin
  token="$(_claude_multi_token "$profile")" || return 1

  claude_bin="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
  if [[ ! -x "$claude_bin" ]]; then
    claude_bin="$(command -v claude 2>/dev/null)"
    [[ -n "$claude_bin" ]] || { print -u2 "Claude CLI not found; set CLAUDE_BIN"; return 1 }
  fi

  # Route through the usage proxy ONLY if it is actually listening. Setting this
  # unconditionally makes every session die with ECONNREFUSED when the proxy is
  # down. CLAUDE_NO_PROXY=1 forces a direct connection.
  local -a proxy_env
  proxy_env=()
  if [[ -z "$CLAUDE_NO_PROXY" ]] && _claude_proxy_up; then
    proxy_env=(ANTHROPIC_BASE_URL="http://127.0.0.1:${CLAUDE_PROXY_PORT}")
  fi

  env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN \
    ANTHROPIC_PROFILE="$profile" \
    CLAUDE_CODE_OAUTH_TOKEN="$token" \
    "${proxy_env[@]}" \
    "$claude_bin" "$@"
}

# Define claude-<name> for every token file present.
claude-reload-profiles() {
  local f name
  CLAUDE_MULTI_PROFILES=()
  for f in "$CLAUDE_MULTI_DIR"/*.oauth(N); do
    name="${${f:t}%.oauth}"
    CLAUDE_MULTI_PROFILES+=("$name")
    # eval rather than the functions[] array: that needs zsh/parameter, which
    # is not guaranteed to be loaded (e.g. under `zsh -f`).
    eval "claude-${name}() { _claude_multi_run ${(q)name} \"\$@\"; }"
  done
}

# Show the org id and current usage for each account, as a table.
#
# This SPENDS TOKENS: one 9-token call per account (8 in, 1 out), the same probe
# the meter uses. Nothing cheaper returns the rate-limit headers.
#
# The probe model must be one your subscription can call. Haiku 4.5 works on
# subscription tokens; Sonnet and Haiku 5.5 answer them with a bare 429 carrying
# no rate-limit headers at all. Override with CLAUDE_LIMITS_MODEL.
claude-whoami() {
  local profiles=("$@")
  (( $# )) || profiles=($CLAUDE_MULTI_PROFILES)
  (( ${#profiles} )) || { print -u2 "No accounts in $CLAUDE_MULTI_DIR"; return 1 }

  local model="${CLAUDE_LIMITS_MODEL:-claude-haiku-4-5}"
  local payload
  payload=$(printf '{"model":"%s","max_tokens":1,"messages":[{"role":"user","content":"."}]}' "$model")

  local p token hdrs org u5 u7 r5 r7 st
  _cw_hv() { print -r -- "$hdrs" | grep -i "^$1:" | sed "s/^[^:]*: *//" }
  _cw_ts() { [[ -n "$1" ]] && date -r "$1" "+%m-%d %H:%M" 2>/dev/null || print -n "?" }

  printf "%-10s %-38s %5s %5s %-12s %-12s %s\n" \
    PROFILE ORGANIZATION-ID 5H 7D 5H-RESET 7D-RESET STATUS
  for p in "${profiles[@]}"; do
    token="$(_claude_multi_token "$p" 2>/dev/null)" || {
      printf "%-10s %s\n" "$p" "(no token)"; continue
    }
    hdrs=$(curl -s -m 30 -D - -o /dev/null https://api.anthropic.com/v1/messages \
      -H "Authorization: Bearer $token" \
      -H "anthropic-version: 2023-06-01" \
      -H "anthropic-beta: oauth-2025-04-20" \
      -H "content-type: application/json" \
      -d "$payload" | tr -d '\r')

    if ! print -r -- "$hdrs" | grep -qE '^HTTP/[0-9.]+ 200'; then
      printf "%-10s %s\n" "$p" "(failed: $(print -r -- "$hdrs" | head -1))"
      continue
    fi

    org=$(_cw_hv anthropic-organization-id)
    u5=$(_cw_hv anthropic-ratelimit-unified-5h-utilization)
    u7=$(_cw_hv anthropic-ratelimit-unified-7d-utilization)
    r5=$(_cw_ts "$(_cw_hv anthropic-ratelimit-unified-5h-reset)")
    r7=$(_cw_ts "$(_cw_hv anthropic-ratelimit-unified-7d-reset)")
    st=$(_cw_hv anthropic-ratelimit-unified-status)
    printf "%-10s %-38s %5s %5s %-12s %-12s %s\n" \
      "$p" "${org:-?}" "${u5:-?}" "${u7:-?}" "$r5" "$r7" "${st:-?}"
  done
  unset -f _cw_hv _cw_ts 2>/dev/null

  print -r -- ""
  print -r -- "Accounts in one org share an org id but keep separate reset windows, so the"
  print -r -- "reset columns are what tell them apart. Email addresses are not recoverable"
  print -r -- "from these tokens; run /status inside a session to see one."
}

claude-profiles() {
  local p
  (( ${#CLAUDE_MULTI_PROFILES} )) || { print -r -- "  none found in $CLAUDE_MULTI_DIR"; return }
  for p in $CLAUDE_MULTI_PROFILES; do print -r -- "  $p"; done
}

# Store a token safely: hidden multi-line read, strips all whitespace, collapses
# an accidentally doubled paste, validates prefix and length, writes 0600.
claude-set-token() {
  local profile="$1"
  [[ -n "$profile" ]] || { print -u2 "usage: claude-set-token <name>"; return 1 }
  local f="$CLAUDE_MULTI_DIR/$profile.oauth"
  if [[ -e "$f" ]]; then
    local reply
    print -n "$f exists. Overwrite? [y/N] "; read -r reply
    [[ "$reply" == [yY]* ]] || { print -r -- "Aborted."; return 1 }
  fi
  print -r -- "Paste the token for '$profile' (hidden), then Enter on an empty line."
  local line tok=""
  while IFS= read -rs line; do
    [[ -z "${line//[[:space:]]/}" ]] && break
    tok+="${line//[[:space:]]/}"
  done
  [[ "$tok" == sk-ant-oat01-* ]] || { print -u2 "Not a setup-token. Nothing written."; return 1 }
  local n=${#tok} half
  if (( n % 2 == 0 )); then
    half="${tok[1,n/2]}"
    [[ "$half" == "${tok[n/2+1,n]}" ]] && { print -r -- "Note: pasted twice; collapsed."; tok="$half" }
  fi
  local stripped="${tok//sk-ant-oat01-/}"
  (( (${#tok} - ${#stripped}) / 13 <= 1 )) || { print -u2 "Multiple tokens pasted. Nothing written."; return 1 }
  (( ${#tok} >= 100 && ${#tok} <= 130 )) || { print -u2 "Length ${#tok}, expected ~108. Nothing written."; return 1 }
  mkdir -p "$CLAUDE_MULTI_DIR" || return 1
  ( umask 077; print -r -- "$tok" > "$f" ) || return 1
  chmod 600 "$f"
  print -r -- "Wrote $f (${#tok} chars). Run claude-reload-profiles to pick it up."
  claude-reload-profiles
}

claude-reload-profiles
