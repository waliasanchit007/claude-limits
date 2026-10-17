# ClaudeLimits

A macOS menu bar meter for Claude usage limits — session (5h) and weekly (7d) —
across as many accounts as you like.

No third-party menu bar host. One Swift file, builds with the stock toolchain.

```
account      session(5h)         weekly(7d)
──────────────────────────────────────────────────
personal     ░░░░░░░░   5% 4h15m  ███░░░░░  37% 2d22h  live
work         ██░░░░░░  26% 2h45m  ██████░░  77% 3d19h  allowed_warning
```

## Quick start

```sh
git clone https://github.com/waliasanchit007/claude-limits.git
cd claude-limits
./build.sh
```

That compiles, bundles to `~/Applications/ClaudeLimits.app`, ad-hoc signs and
launches it. Turn on **Settings → Launch at login** if you want it permanent.

Now give it an account. One file per account, each holding a single token:

```sh
mkdir -p ~/.config/claude-multi-account
claude setup-token                    # sign in as the account you want
umask 077
pbpaste > ~/.config/claude-multi-account/work.oauth
```

The app picks it up on its next refresh. Repeat for as many accounts as you have.

For a terminal table instead:

```sh
~/Applications/ClaudeLimits.app/Contents/MacOS/ClaudeLimits --once
```

### Optional: shell wrappers

`contrib/claude-multi-account.zsh` gives you a `claude-<name>` command per account,
generated automatically from the token files — no per-account lines to maintain.

```sh
echo 'source /path/to/claude-limits/contrib/claude-multi-account.zsh' >> ~/.zshrc
```

`work.oauth` becomes `claude-work`. It also provides `claude-set-token <name>`,
which stores a token safely — hidden input, whitespace stripped, doubled pastes
collapsed, length and prefix validated, written `0600`. Both are real failure modes
that produce a token which looks fine and fails with an opaque 401.

### Optional: free, live usage

```sh
./contrib/install-proxy.sh
```

See [Getting usage for free](#getting-usage-for-free). **Read the `ECONNREFUSED`
warning there before enabling it.**

## Where accounts come from

Any `*.oauth` file in `~/.config/claude-multi-account/`, each containing one token
from `claude setup-token`. Files under a `disabled/` subdirectory are listed but
never polled — useful for an account that is revoked or blocked but whose token you
do not want to throw away yet.

Keychain logins can optionally be included, but this is **off by default**: the scan
triggers a macOS access prompt, and on a managed machine where you cannot approve
it, `SecItemCopyMatching` blocks indefinitely rather than failing.

## How usage is read, and what it costs

Three routes, cheapest first, chosen per account on every refresh.

**0. Local usage proxy — free *and* live.** The rate-limit headers ride on replies
your sessions already receive. `contrib/usage-proxy.py` forwards traffic to
`api.anthropic.com` and records those headers in passing, so no request is ever
originated for the sake of measurement. Rows read this way are marked `live`.
Only covers accounts you actually *use*; readings older than 20 minutes are ignored
so an idle account falls back to polling rather than freezing at a stale value.

**1. `GET /api/oauth/usage` — free.** Requires the `user:profile` OAuth scope.
Credentials from `claude auth login` carry it; credentials from `claude setup-token`
do **not**, and get a 403. Tried automatically — if your token ever qualifies, the
app uses it with no change from you.

**2. `POST /v1/messages` — ~9 tokens.** The `anthropic-ratelimit-unified-*` headers
come back only on a real inference call. `count_tokens`, a malformed 400 and a
bad-model 404 all return none, so this is the floor. The probe is the smallest valid
request — `{"max_tokens":1,"messages":[{"role":"user","content":"."}]}`, 8 input + 1
output. The Claude Code system prompt is *not* required; including it would cost 22
input tokens rather than 8.

**Never spend tokens** disables route 2 entirely. Accounts with no free source then
say so rather than quietly spending.

### Cost

| Refresh | Per refresh (3 accounts) | Tokens/day |
|---|---|---|
| 15 min | 27 | 2,592 |
| 30 min (default) | 27 | 1,296 |
| 60 min | 27 | 648 |
| Manual | 27 | 0 while idle |

Accounts covered by the proxy cost nothing at all, so the bill shrinks the more you
actually use an account.

Expressing that as a *percentage* needs your plan's absolute token budget, which the
API never exposes — it reports utilization only as a fraction. The built-in figure
(~3.55M tokens per 5h window) was measured on one Team-plan account by observing that
35,537 input tokens moved utilization by exactly 0.01. **Your plan almost certainly
differs.** Override it with `CLAUDE_LIMITS_5H_BUDGET`. Nothing else depends on this
number — the meters themselves come from the API and are always accurate.

## Getting usage for free

```sh
./contrib/install-proxy.sh          # LaunchAgent, RunAtLoad + KeepAlive
```

Then point sessions at it. **Never set `ANTHROPIC_BASE_URL` unconditionally** — if
the proxy is not running, every session pointed at it dies with `ECONNREFUSED`. Set
it only when the port is actually listening, so a dead proxy degrades to a direct
connection. `contrib/claude-multi-account.zsh` already does this; see
`contrib/README.md` if you are wiring it yourself.

Remove it with `./contrib/uninstall-proxy.sh`.

## Configuration

Each reads an environment variable first, then a `UserDefaults` key under
`local.claudelimits`, then the default.

| Env | Default key | Default |
|---|---|---|
| `CLAUDE_LIMITS_TOKEN_DIR` | `tokenDir` | `~/.config/claude-multi-account` |
| `CLAUDE_LIMITS_USAGE_FILE` | `usageFile` | `~/.local/share/claude-usage/usage.json` |
| `CLAUDE_LIMITS_MODEL` | `probeModel` | `claude-haiku-4-5-20251001` |
| `CLAUDE_LIMITS_5H_BUDGET` | `fiveHourBudget` | `3553699` |

```sh
defaults write local.claudelimits probeModel -string "claude-sonnet-4-5"
```

Menu settings (refresh rate, hidden accounts, never-spend, keychain) persist the
same way.

## Reading the display

| | |
|---|---|
| `session(5h)` | rolling 5-hour window, and time until it resets |
| `weekly(7d)` | rolling 7-day window, and time until it resets |
| `live` | observed from real session traffic via the proxy — free and current |
| `free` | fetched at no token cost |
| orange | ≥75% used, or the API returned `allowed_warning` |
| red | ≥90% used, `rejected`, or the account errored |

`allowed_warning` is Anthropic's own signal, not this app's: the API returns it with
`7d-surpassed-threshold: 0.75` once you cross 75% of the weekly window. Requests
still succeed — it is a heads-up, not a block.

Note that colour keys off the **weekly** figure. A session window filling fast will
not turn orange on its own; it goes red only once the API actually returns
`rejected`, by which point you are already throttled.

The menu bar title shows the worst weekly figure across visible accounts.

## Caveats

The parser for `/api/oauth/usage` is written defensively against an unknown schema —
that endpoint has never returned 200 during development, since no token with the
required scope was available to test against. If a scoped token produces
wrong-looking rows, `scrapeUsage()` is where to look.

Rate limits are per account, so two machines sharing one token share one budget.

## License

MIT
