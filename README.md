# ClaudeLimits

A macOS menu bar meter for Claude usage limits — session (5h) and weekly (7d) —
across multiple accounts at once.

No third-party menu bar host required. Single Swift file, ~500 lines, builds with
the stock toolchain.

```
account      session(5h)         weekly(7d)
──────────────────────────────────────────────
personal     ░░░░░░░░   5% 4h15m  ███░░░░░  37% 2d22h
work         ██░░░░░░  26% 2h45m  ██████░░  69% 3d19h
```

## Install

```sh
git clone https://github.com/waliasanchit007/claude-limits.git
cd claude-limits
./build.sh
```

`build.sh` compiles, bundles into `~/Applications/ClaudeLimits.app`, ad-hoc signs
and launches it. Enable "Launch at login" from the Settings submenu.

For a one-off table in the terminal:

```sh
~/Applications/ClaudeLimits.app/Contents/MacOS/ClaudeLimits --once
```

## Accounts

Accounts are discovered automatically from `~/.config/claude-multi-account/*.oauth`
— one file per account, each containing a single token from `claude setup-token`.
Files under a `disabled/` subdirectory are listed but never polled.

This layout pairs with a shell-function setup where each account gets its own
wrapper that exports `CLAUDE_CODE_OAUTH_TOKEN` before invoking the CLI. Any such
layout works; the app only cares about the `.oauth` files.

Keychain logins can optionally be included, but this is **off by default**: the scan
triggers a macOS access prompt, and on a managed machine where you cannot approve
it, `SecItemCopyMatching` blocks indefinitely.

## How usage is read, and what it costs

Three routes, cheapest first:

**0. Local usage proxy — free *and* live.** `contrib/usage-proxy.py` forwards your
session traffic to `api.anthropic.com` and harvests the rate-limit headers riding on
replies you were already receiving. No request is originated, so it costs nothing,
and it updates the instant a session gets a reply. Rows sourced this way show
`live`. It only covers accounts you actually *use* — readings older than 20 minutes
are treated as stale and fall through to polling, so idle accounts never freeze at
an old value. See `contrib/README.md`, and note the `ECONNREFUSED` guard there: it
is not optional.

**1. `GET /api/oauth/usage` — free.** Requires the `user:profile` OAuth scope.
Credentials from `claude auth login` carry it; credentials from
`claude setup-token` do **not**, and get a 403. Rows fetched this way are marked
`free`.

**2. `POST /v1/messages` — ~9 tokens.** The `anthropic-ratelimit-unified-*` headers
are returned only by a real inference call. `count_tokens`, a malformed 400, and a
bad-model 404 all return none, so this is the floor. The probe is the smallest valid
request: `{"max_tokens":1,"messages":[{"role":"user","content":"."}]}` — 8 input + 1
output. The Claude Code system prompt is *not* required; including it would cost 22
input tokens instead of 8.

Enable **Never spend tokens** to disable route 2 entirely. Accounts without the free
scope then display `needs user:profile scope (free mode)` rather than being polled.

### Measured cost

The API reports utilization only as a fraction, never an absolute budget. Measuring
it directly: 35,537 input tokens moved 5h utilization by exactly 0.01, giving a
session budget of ~3.55M tokens (~17M/day equivalent).

| Refresh | Per refresh (3 accounts) | Tokens/day | Share of daily capacity |
|---|---|---|---|
| 15 min | 27 | 2,592 | 0.0152% |
| 30 min (default) | 27 | 1,296 | 0.0076% |
| 60 min | 27 | 648 | 0.0038% |
| 180 min | 27 | 216 | 0.0013% |
| Manual | 27 | 0 idle | 0% |

Reporting resolution is 0.01, so the true budget lies in roughly 2.4M–7.1M. These
figures could be off by ~2x and remain negligible.

## Reading the display

| | |
|---|---|
| `session(5h)` | rolling 5-hour window, and time until it resets |
| `weekly(7d)` | rolling 7-day window, and time until it resets |
| orange | ≥75% used, or the API returned `allowed_warning` |
| red | ≥90% used, `rejected`, or the account errored |
| `live` | observed from real session traffic via the proxy — free, current |
| `free` | fetched at no token cost |

The menu bar title shows the worst weekly figure across visible accounts.

## Caveats

The parser for `/api/oauth/usage` is written defensively against an unknown schema —
that endpoint has never returned 200 during development, since no token with the
required scope was available to test with. If a scoped token produces wrong-looking
rows, `scrapeUsage()` is the place to look.

Rate limits are per account, so two machines sharing one token share one budget.

## License

MIT
