# Tokens Are Running Out

> **Where did my tokens go?** · 내 토큰 어디 갔어?

A macOS menu bar app that tells you **why** your Claude Code usage drained, not just how much is left.

Most usage tools show a gauge. This one reads your local Claude Code transcripts and explains where the spend came from, so you can change what you do next time.

> **Status: development build.** The app runs from source; signed releases and Homebrew come later. The design and its approval gates live in [`docs/dlc/projects/tokens-are-running-out`](docs/dlc/projects/tokens-are-running-out/STATUS.md) ([Waypoint](https://github.com/bingoring/waypoint)).

## What it does

- **Break usage down by cause.** For the last 5 hours, today and the last 7 days, it splits API-price-equivalent cost into normal work, cache rebuilds after a short break, cache rebuilds after a long break, subagents, advisor consults and other causes.
- **Warn before a cache expires.** When an idle session's prompt cache is about to expire, it shows how long is left and how many tokens a resume would have to write again. If you turn it on, it also sends a notification ahead of time.
- **List the costly rebuilds.** It lists each cache rebuild with the session, the break before it and the rule that classified it.

## What it will never do

- Read your login tokens, keychain or cookies.
- Send anything over the network. It has no telemetry.
- Spend your quota, for example by pinging sessions to keep the cache warm.
- Write to `~/.claude`. It only reads.

## Build and run

Requires macOS 14 or later and Xcode 26.

```bash
scripts/build-app.sh
```

```bash
open .build/apps/TokensAreRunningOut.app
```

The script builds with `xcodebuild` (which compiles the English and Korean strings) and signs the app ad hoc. The index lives in `~/Library/Application Support/TokensAreRunningOut/`; deleting it is safe, the app rebuilds it.

## Prototype

[`prototype/drain.py`](prototype/drain.py) counts and classifies cache rebuilds in your local transcripts. It is read-only and needs only Python 3:

```bash
python3 -I prototype/drain.py --from 2026-11-10T00:00:00Z --to 2026-11-17T00:00:00Z
```

The Swift app must reproduce its numbers exactly for the same window.

## License

[MIT](LICENSE)
