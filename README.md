# ClaudeLimits

A macOS menu bar meter for Claude usage limits, session (5h) and weekly (7d),
across as many accounts as you like.

```
account      session(5h)         weekly(7d)
──────────────────────────────────────────────────
personal     ░░░░░░░░   5% 4h15m  ███░░░░░  37% 2d22h  live
work         ██░░░░░░  26% 2h45m  ██████░░  77% 3d19h  allowed_warning
```

macOS only. It is an AppKit menu bar app, so there is no Linux or Windows build.
It is one Swift file with no runtime dependencies, and it needs no menu bar host like
xbar or SwiftBar.

## Requirements

- macOS 13 Ventura or newer
- Xcode Command Line Tools, for `swiftc` (`xcode-select --install`)
- At least one Claude account

## Install

```sh
git clone https://github.com/waliasanchit007/claude-limits.git
cd claude-limits
./install.sh
```

It checks your macOS version and toolchain, builds the app into
`~/Applications/ClaudeLimits.app`, launches it, and lists the accounts it found.
The one question it asks is whether to add the shell commands to your `~/.zshrc`.
Re-running it is safe; it asks before overwriting anything.

To skip that question, `./install.sh --build-only`.

If you already have accounts configured, the meter starts showing them straight
away and there is nothing else to do.

Turn on **Settings → Launch at login** in the menu to keep it running.

## What this shows you that the Claude apps don't

Claude's own interface reports usage for the account you are signed into, when you
ask. It leaves out four things.

Accounts only make sense side by side. If you keep work and personal accounts, or
several under one org, each one has its own reset clock. Four accounts under one org
can reset at four different times, so "when does my limit come back" has a different
answer for each of them, and this is the view that shows all four at once.

Setup-token credentials cannot report their own usage. They carry inference scope
only, and Anthropic's usage endpoint needs `user:profile`, so it answers them with a
403. For those accounts no official free read exists. This finds two ways around it:
the proxy, which is free and live, and a 9-token probe as the floor. Both are in
[How usage is read](#how-usage-is-read-and-what-it-costs).

The warnings arrive late. `allowed_warning` shows up at 75% of the weekly window,
and `rejected` shows up once you are already throttled. A meter you can see all the
time gives you more notice than either.

The token cost is written down. Every refresh has a stated price, in the table
below, and Never spend tokens turns the paid route off. An account left with no free
source then says so rather than quietly spending.

## Adding accounts

```sh
claude-set-token work
```

Use that rather than writing the file yourself. Pasting a token by hand fails in two
ways, and both leave a file that looks correct and then returns an opaque 401:

- **The terminal wraps it.** `claude setup-token` prints the token to your terminal,
  so copying it from the screen can capture the line breaks and leading spaces the
  terminal added for display.
- **It arrives twice.** A double-tap of ⌘V gives you 216 characters where 108 belong,
  and the prefix still looks right.

`claude-set-token` takes the paste hidden, strips whitespace, collapses a doubled
paste, rejects a double paste of two *different* tokens, checks the prefix and
length, and writes the file `0600`. It comes from
`contrib/claude-multi-account.zsh`, which the installer offers to add to your
`~/.zshrc`.

### Doing it by hand

One file per account, each holding one token:

```sh
mkdir -p ~/.config/claude-multi-account
claude setup-token                    # sign in as the account you want first
umask 077
pbpaste > ~/.config/claude-multi-account/work.oauth
```

The two odd lines are deliberate, because the file holds a live credential.

`umask 077` makes the file `0600` at the moment it is created. Writing it first and
running `chmod` after leaves a window where any user on the machine can read your
token.

`pbpaste >` keeps the token out of your shell history. Typing
`echo 'sk-ant-oat01-…' > file` writes a working credential into `~/.zsh_history`
permanently, and shows it in `ps` while it runs.

What `pbpaste` does not do is check anything. It copies the clipboard exactly as it
is, so it carries both failure modes above straight through. If a token written that
way gives you a 401, check its length first:

```sh
tr -d '[:space:]' < ~/.config/claude-multi-account/work.oauth | wc -c    # expect 108
```

The app picks up new files on its next refresh.

### Where accounts come from

Any `*.oauth` file in `~/.config/claude-multi-account/`, each containing one token
from `claude setup-token`. Files under a `disabled/` subdirectory are listed but
never polled, which is useful for an account that is revoked or blocked but whose
token you do not want to throw away yet.

Keychain logins can optionally be included, but this is **off by default**: the scan
triggers a macOS access prompt, and on a managed machine where you cannot approve
it, `SecItemCopyMatching` blocks indefinitely rather than failing.

## Other ways to read it

A table in your terminal, no app needed:

```sh
~/Applications/ClaudeLimits.app/Contents/MacOS/ClaudeLimits --once
```

Worth putting on your `PATH` as `claude-limits`, which also makes it easy to drop
into a shell prompt or a status bar.

### Shell commands per account

`contrib/claude-multi-account.zsh` gives you a `claude-<name>` command per account,
generated from the token files, with no per-account lines to maintain. `work.oauth`
becomes `claude-work`. It also provides `claude-set-token` for adding an account,
`claude-profiles` for listing the ones you have, and `claude-whoami`, which prints
each account's org id, usage and reset times as a table. `claude-whoami` costs 9
tokens per account, because it uses the same probe described below.

## How usage is read, and what it costs

Three routes, cheapest first, chosen per account on every refresh.

**0. Local usage proxy, free *and* live.** The rate-limit headers ride on replies
your sessions already receive. `contrib/usage-proxy.py` forwards traffic to
`api.anthropic.com` and records those headers in passing, so no request is ever
originated for the sake of measurement. Rows read this way are marked `live`.
Only covers accounts you actually *use*; readings older than 20 minutes are ignored
so an idle account falls back to polling rather than freezing at a stale value.

**1. `GET /api/oauth/usage`, free.** Requires the `user:profile` OAuth scope.
Credentials from `claude auth login` carry it; credentials from `claude setup-token`
do **not**, and get a 403. It is tried automatically, so if your token ever qualifies the
app uses it with no change from you.

**2. `POST /v1/messages`, ~9 tokens.** The `anthropic-ratelimit-unified-*` headers
come back only on a real inference call. `count_tokens`, a malformed 400 and a
bad-model 404 all return none, so this is the floor. The probe is the smallest valid
request, `{"max_tokens":1,"messages":[{"role":"user","content":"."}]}`, measured at 8
input and 1 output. The Claude Code system prompt is *not* required; including it
would cost 22 input tokens rather than 8.

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
API never exposes, since it reports utilization only as a fraction. The built-in figure
(~3.55M tokens per 5h window) was measured on one Team-plan account by observing that
35,537 input tokens moved utilization by exactly 0.01. **Your plan almost certainly
differs.** Override it with `CLAUDE_LIMITS_5H_BUDGET`. Nothing else depends on this
number. The meters themselves come from the API and are always accurate.

## Getting usage for free

```sh
./contrib/install-proxy.sh          # LaunchAgent, RunAtLoad + KeepAlive
```

Then point sessions at it. **Never set `ANTHROPIC_BASE_URL` unconditionally.** If
the proxy is not running, every session pointed at it dies with `ECONNREFUSED`. Set
it only when the port is actually listening, so a dead proxy degrades to a direct
connection. `contrib/claude-multi-account.zsh` already does this; see
`contrib/README.md` if you are wiring it yourself.

The proxy handles your OAuth tokens in memory. It forwards but never logs them, and
listens on localhost only. Decide for yourself whether that is acceptable on a
machine you do not control.

Remove it with `./contrib/uninstall-proxy.sh`.

## Configuration

Each reads an environment variable first, then a `UserDefaults` key under
`local.claudelimits`, then the default.

| Env | Default key | Default |
|---|---|---|
| `CLAUDE_LIMITS_TOKEN_DIR` | `tokenDir` | `~/.config/claude-multi-account` |
| `CLAUDE_LIMITS_USAGE_FILE` | `usageFile` | `~/.local/share/claude-usage/usage.json` |
| `CLAUDE_LIMITS_MODEL` | `probeModel` | `claude-haiku-4-5` |
| `CLAUDE_LIMITS_5H_BUDGET` | `fiveHourBudget` | `3553699` |

```sh
defaults write local.claudelimits probeModel -string "claude-haiku-4-5"
```

Menu settings (refresh rate, hidden accounts, never-spend, keychain) persist the
same way.

## Reading the display

| | |
|---|---|
| `session(5h)` | rolling 5-hour window, and time until it resets |
| `weekly(7d)` | rolling 7-day window, and time until it resets |
| `live` | observed from real session traffic via the proxy, free and current |
| `free` | fetched at no token cost |
| orange | ≥75% used, or the API returned `allowed_warning` |
| red | ≥90% used, `rejected`, or the account errored |

`allowed_warning` is Anthropic's own signal, not this app's: the API returns it with
`7d-surpassed-threshold: 0.75` once you cross 75% of the weekly window. Requests
still succeed. It is a heads-up rather than a block.

Note that colour keys off the **weekly** figure. A session window filling fast will
not turn orange on its own; it goes red only once the API actually returns
`rejected`, by which point you are already throttled.

The menu bar title shows the worst weekly figure across visible accounts.

## Caveats

The parser for `/api/oauth/usage` is written defensively against an unknown schema.
That endpoint has never returned 200 during development, since no token with the
required scope was available to test against. If a scoped token produces
wrong-looking rows, `scrapeUsage()` is where to look.

Route 2 only works with a model your subscription can actually call. Haiku 4.5
answers a subscription token with 200 and the rate-limit headers. Haiku 5.5 and
Sonnet 4.5 both answer the same token with a bare 429 carrying no rate-limit headers
at all, so pointing `CLAUDE_LIMITS_MODEL` at one of those disables route 2 rather
than making it more current. Test any replacement before trusting it.

Rate limits are per account, so two machines sharing one token share one budget.

## License

MIT
