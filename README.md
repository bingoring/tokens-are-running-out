# Tokens Are Running Out

> **Where did my tokens go?** · 내 토큰 어디 갔어?

A macOS menu bar app that tells you **why** your Claude Code usage drained, not just how much is left.

Most usage tools show a gauge. This one reads your local Claude Code transcripts and explains where the spend came from, so you can change what you do next time.

> **Status: pre-release.** Signed and notarized builds go to [Releases](https://github.com/bingoring/tokens-are-running-out/releases), and Homebrew works from the first stable release, v0.1.0. The design and its approval gates live in [`docs/dlc/projects/tokens-are-running-out`](docs/dlc/projects/tokens-are-running-out/STATUS.md) ([Waypoint](https://github.com/bingoring/waypoint)).

## What it does

- **Break usage down by cause.** For the last 5 hours, today and the last 7 days, it splits API-price-equivalent cost into normal work, cache rebuilds after a short break, cache rebuilds after a long break, subagents, advisor consults and other causes.
- **Warn before a cache expires.** When an idle session's prompt cache is about to expire, it shows how long is left and how many tokens a resume would have to write again. If you turn it on, it also sends a notification ahead of time.
- **List the costly rebuilds.** It lists each cache rebuild with the session, the break before it and the rule that classified it.

## What it will never do

- Read your login tokens, keychain or cookies.
- Send anything over the network. It has no telemetry.
- Spend your quota, for example by pinging sessions to keep the cache warm.
- Write to `~/.claude`. It only reads.

## Install

Requires macOS 14 or later, on Apple silicon or Intel.

With [Homebrew](https://brew.sh):

```bash
brew install --cask bingoring/tap/tokens-are-running-out
```

Or download `TokensAreRunningOut-<version>.zip` from [Releases](https://github.com/bingoring/tokens-are-running-out/releases), unzip it and move `TokensAreRunningOut.app` to Applications. The app is signed with a Developer ID and notarized by Apple, so it opens without a Gatekeeper warning. To check a download, put the `.sha256` file from the same release next to the zip and run:

```bash
shasum -a 256 -c TokensAreRunningOut-<version>.zip.sha256
```

The index lives in `~/Library/Application Support/TokensAreRunningOut/`; deleting it is safe, the app rebuilds it. `brew uninstall --zap --cask tokens-are-running-out` removes the app, its index and its settings.

## Build from source

Requires Xcode 26.

```bash
scripts/build-app.sh
```

```bash
open .build/apps/TokensAreRunningOut.app
```

The script builds with `xcodebuild` (which compiles the English and Korean strings) and signs the app ad hoc. `scripts/build-app.sh --release 1.2.3` builds the universal (Apple silicon and Intel) app with that version.

## Prototype

[`prototype/drain.py`](prototype/drain.py) counts and classifies cache rebuilds in your local transcripts. It is read-only and needs only Python 3:

```bash
python3 -I prototype/drain.py --from 2026-11-10T00:00:00Z --to 2026-11-17T00:00:00Z
```

The Swift app must reproduce its numbers exactly for the same window.

## Releasing

For maintainers. Pushing a tag runs the [Release workflow](.github/workflows/release.yml):

```bash
git tag v1.2.3
```

```bash
git push origin v1.2.3
```

- `v1.2.3-rc.1` makes a GitHub pre-release and leaves the Homebrew cask alone.
- `v1.2.3` makes a release and points the cask in [bingoring/homebrew-tap](https://github.com/bingoring/homebrew-tap) at it.
- The workflow builds the universal app, signs it with the Developer ID (hardened runtime), notarizes it, staples the ticket and attaches the zip and its SHA-256. It never replaces an existing release.
- If only the Homebrew step fails, for example because the token expired, register a new token and run the **Update Homebrew tap** workflow with the tag. It does not rebuild.

The workflow needs these repository secrets:

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | The Developer ID Application certificate and its private key, exported as `.p12`, in base64 |
| `DEVELOPER_ID_P12_PASSWORD` | The `.p12` export password |
| `NOTARY_KEY_P8_BASE64` | An App Store Connect team API key (`.p8`, Developer access), in base64 |
| `NOTARY_KEY_ID` | That key's ID |
| `NOTARY_ISSUER_ID` | The issuer ID shown above the team keys |
| `TAP_TOKEN` | A fine-grained token with Contents read and write on `bingoring/homebrew-tap` only. Stable releases need it |

Set them in your own terminal, from files or the prompt, so the values never land in the shell history. For example:

```bash
base64 -i DeveloperID.p12 | gh secret set DEVELOPER_ID_P12_BASE64
```

```bash
gh secret set DEVELOPER_ID_P12_PASSWORD
```

To try the signing steps without secrets, build and run the release script with `--dry-run`, which signs ad hoc and skips notarization:

```bash
scripts/build-app.sh --release 1.2.3 && scripts/release.sh --version 1.2.3 --dry-run
```

## License

[MIT](LICENSE)
