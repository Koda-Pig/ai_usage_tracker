# AI Usage Tracker

A menu bar-only macOS app that shows Claude and Codex allowance remaining: the 5-hour window over the weekly window, as percentages. Like a battery, 100% means full allowance and 0% means exhausted. Click it for reset times. There is no Dock icon, no window and no background helper.

```
✳ 88%   >_ 100%
  69%      41%
```

## Where the numbers come from

**Claude.** The app has its own sign-in. Choose *Sign in to Claude…* once and approve in the browser; the app keeps its own OAuth tokens in its Keychain item and refreshes them silently. It is a separate grant from Claude Code's, so:

- you never need to run `claude` in the morning to keep it working, and
- it never reads or refreshes Claude Code's Keychain item, so it can't log your CLI out.

It uses the same public OAuth client and PKCE flow as `claude auth login` (constants taken from Claude Code 2.1.287), asks only for `user:profile`, and reads `GET api.anthropic.com/api/oauth/usage`, the endpoint behind Claude Code's `/usage`. Both are undocumented. If Anthropic changes them, the menu shows the error and keeps the last numbers.

**Codex.** On each refresh the app starts `codex app-server`, sends `account/rateLimits/read` over stdio, and quits it. That takes about 1.3 s and 0.25 s of CPU. Codex handles its own login, so the app never touches Codex's tokens. If the CLI is missing or offline, the app falls back to the newest `~/.codex/sessions` log, which holds the same numbers as of your last Codex request, and the menu says so.

Once a window's reset time has passed, it shows 100% remaining even if the last fetch was older. Dropdown meters drain as allowance is consumed, with colors blending smoothly from green at 100%, through orange at 30%, to red at 10% and below.

## Why it's cheap

- Pure AppKit `NSStatusItem` + `NSMenu`. No SwiftUI, no floating panels, no animation.
- It polls every 5 minutes on a timer with 60 s tolerance, so macOS can coalesce wake-ups. It also refreshes once on wake from sleep, and when you open the menu if the data is over a minute old.
- The menu bar glyph is redrawn only when the data changes. Countdowns are computed when the menu opens, never on a ticking timer.
- No resident child process: `codex app-server` exits after each query.
- On a 429 it honours `Retry-After` and skips Claude until then.

## Build

Needs Xcode 26 / Swift 6.2+ and macOS 26.

```sh
scripts/build.sh test      # unit tests (no network)
scripts/build.sh run       # build, sign, relaunch from build/
scripts/build.sh install   # copy to ~/Applications and launch (needed for Open at Login)
```

Signing uses `SIGN_IDENTITY` if set, otherwise the first "Apple Development" certificate in your keychain, otherwise ad hoc. Use a real identity: the Keychain ties the saved Claude sign-in to the app's signature, so an ad hoc build asks for Keychain access again after every rebuild.

`AIUsageTracker --dump [dir]` does one real refresh, prints the menu as text, and writes the menu bar glyph to `dir/status.png`. Use it to check the UI without screen-recording permission.

## Layout

```
Sources/UsageCore/        all logic, unit tested
  ClaudeOAuth.swift       PKCE sign-in + refresh requests
  ClaudeClient.swift      token lifecycle (single-flight refresh) + usage endpoint
  LoopbackCallback.swift  one-shot 127.0.0.1 listener for the OAuth redirect
  CodexClient.swift       one-shot app-server query + session-log fallback
  Keychain.swift          the only place secrets are stored
Sources/AIUsageTracker/   menu bar app (AppDelegate, StatusImage, UsageStore)
Tests/UsageCoreTests/     fixtures of observed responses + tests
```

Rules: never log or persist tokens anywhere except the Keychain (`ClaudeTokens.description` is redacted). Tests use the `Transport` and `SecretStore` stubs, never the network. Keep it small: no third-party dependencies.
