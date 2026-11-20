#!/bin/sh
# Writes the cask for a released version and pushes it to bingoring/homebrew-tap.
#
#   TAP_TOKEN=… scripts/update-tap.sh VERSION SHA256          # clone, commit and push
#   scripts/update-tap.sh VERSION SHA256 --write-only DIR      # only write DIR/Casks/tokens-are-running-out.rb
set -eu
version="${1:?version}"
sha="${2:?sha256}"
mode="${3:-push}"
echo "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "update-tap: stable versions only, not $version" >&2; exit 2; }
echo "$sha" | grep -Eq '^[0-9a-f]{64}$' || { echo "update-tap: not a SHA-256: $sha" >&2; exit 2; }

write_cask() { # directory
    mkdir -p "$1/Casks"
    cat >"$1/Casks/tokens-are-running-out.rb" <<CASK
cask "tokens-are-running-out" do
  version "$version"
  sha256 "$sha"

  url "https://github.com/bingoring/tokens-are-running-out/releases/download/v#{version}/TokensAreRunningOut-#{version}.zip"
  name "Tokens Are Running Out"
  desc "Menu bar app that shows why Claude Code usage drained"
  homepage "https://github.com/bingoring/tokens-are-running-out"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma

  app "TokensAreRunningOut.app"

  uninstall quit: "io.github.bingoring.TokensAreRunningOut"

  zap trash: [
    "~/Library/Application Support/TokensAreRunningOut",
    "~/Library/Preferences/io.github.bingoring.TokensAreRunningOut.plist",
  ]
end
CASK
}

if [ "$mode" = "--write-only" ]; then
    write_cask "${4:?directory}"
    echo "wrote ${4}/Casks/tokens-are-running-out.rb"
    exit 0
fi

: "${TAP_TOKEN:?TAP_TOKEN is not set}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# The token goes to git through the environment as an HTTP header, so it is in neither the process arguments
# nor the clone's .git/config.
auth=$(printf 'x-access-token:%s' "$TAP_TOKEN" | base64 | tr -d '\n')
if [ "${GITHUB_ACTIONS:-}" = true ]; then
    echo "::add-mask::$auth"
fi
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="http.https://github.com/.extraheader"
export GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $auth"
git clone -q https://github.com/bingoring/homebrew-tap.git "$work/tap"
write_cask "$work/tap"
cd "$work/tap"
if git diff --quiet && [ -z "$(git status --porcelain)" ]; then
    echo "the cask is already at $version"
    exit 0
fi
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add Casks/tokens-are-running-out.rb
git commit -q -m "tokens-are-running-out $version"
git push -q origin HEAD:main
echo "pushed tokens-are-running-out $version to bingoring/homebrew-tap"
