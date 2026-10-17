# usage-proxy.py — free, live usage

A pass-through proxy that harvests `anthropic-ratelimit-unified-*` headers from
traffic your sessions make anyway, so the meter can read usage at **zero token
cost**, updated the moment a session gets a reply.

It originates no requests of its own. It forwards to `api.anthropic.com`
untouched, streams responses back (SSE intact), and notes the usage headers in
passing to `~/.local/share/claude-usage/usage.json`.

Entries are keyed by a SHA-256 prefix of the bearer token, **not** by
organization — several accounts commonly share one org, and org-keying makes
them silently overwrite each other. The token is forwarded but never stored or
logged.

## Run it

    python3 usage-proxy.py 8787

Then point sessions at it:

    ANTHROPIC_BASE_URL=http://127.0.0.1:8787 claude -p "hi"

For a LaunchAgent with `KeepAlive`, see the plist example below.

## The guard you must not skip

**If the proxy is not running, every session pointed at it dies with
`ECONNREFUSED`.** Never set `ANTHROPIC_BASE_URL` unconditionally. Set it only
when the port is actually listening, so a dead proxy degrades to a direct
connection:

```zsh
_claude_proxy_up() {
  local port="${CLAUDE_PROXY_PORT:-8787}"
  zmodload -F zsh/net/tcp b:ztcp 2>/dev/null || return 1
  if ztcp 127.0.0.1 "$port" 2>/dev/null; then ztcp -c "$REPLY" 2>/dev/null; return 0; fi
  return 1
}

local -a proxy_env=()
if [[ -z "$CLAUDE_NO_PROXY" ]] && _claude_proxy_up; then
  proxy_env=(ANTHROPIC_BASE_URL="http://127.0.0.1:${CLAUDE_PROXY_PORT:-8787}")
fi
env "${proxy_env[@]}" claude "$@"
```

## Gotchas found the hard way

- **macOS system Python ships no CA bundle.** Without an explicit SSL context the
  upstream handshake fails and the session *hangs* rather than erroring cleanly.
  The script falls back to `/etc/ssl/cert.pem`.
- **Only accounts you actually use get updated.** An idle account generates no
  traffic, so no readings. The meter treats observations older than 20 minutes as
  stale and falls back to polling — the proxy complements polling, it does not
  replace it.
- The proxy handles your OAuth token in memory to forward it. Localhost only.
  Decide whether that is acceptable on a managed machine.
