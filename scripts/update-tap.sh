#!/bin/sh
# Writes the cask for a released version and pushes it to bingoring/homebrew-tap.
#
#   TAP_TOKEN=… scripts/update-tap.sh VERSION SHA256 [--only-newer]    # clone, commit and push
#   scripts/update-tap.sh VERSION SHA256 [--only-newer] --write-only DIR # only write DIR/Casks/tokens-are-running-out.rb
#
# --only-newer changes the cask only when VERSION is higher than the version it has, so a late or repeated
# release cannot move it back. Without it the cask is set to VERSION, which is how to roll it back.
set -eu

usage() { echo "usage: scripts/update-tap.sh VERSION SHA256 [--only-newer] [--write-only DIR]" >&2; exit 2; }
[ $# -ge 2 ] || usage
version="$1"
sha="$2"
shift 2
only_newer=0 write_only=""
while [ $# -gt 0 ]; do
    case "$1" in
    --only-newer) only_newer=1 ;;
    --write-only)
        [ $# -ge 2 ] && [ -n "$2" ] || usage
        write_only="$2"
        shift
        ;;
    *) usage ;;
    esac
    shift
done

# A stable version is three dot-separated numbers of at most nine digits without leading zeros, and nothing
# else: no "v", no suffix, no space or newline.
is_stable_version() {
    case "$1" in
    "" | *[!0-9.]* | .* | *.) return 1 ;;
    esac
    old_ifs=$IFS
    IFS=.
    # shellcheck disable=SC2086 # split on the dots on purpose; the value has only digits and dots
    set -- $1
    IFS=$old_ifs
    [ $# -eq 3 ] || return 1
    for part in "$@"; do
        case "$part" in
        "" | 0?* | ??????????*) return 1 ;;
        esac
    done
}
is_stable_version "$version" || { echo "update-tap: stable versions only (like 1.2.3), not '$version'" >&2; exit 2; }
case "$sha" in
"" | *[!0-9a-f]*) echo "update-tap: not a SHA-256 (64 lowercase hex digits): '$sha'" >&2; exit 2 ;;
esac
[ "${#sha}" -eq 64 ] || { echo "update-tap: not a SHA-256 (64 lowercase hex digits): '$sha'" >&2; exit 2; }

cask_path() { echo "$1/Casks/tokens-are-running-out.rb"; }

# Exit status 0 when version $1 is higher than version $2. Both are stable versions; the parts are compared
# as numbers, so 0.10.0 is higher than 0.9.0.
is_higher() {
    a=$1 b=$2
    for _ in 1 2 3; do
        a_part=${a%%.*} b_part=${b%%.*}
        if [ "$a_part" -gt "$b_part" ]; then return 0; fi
        if [ "$a_part" -lt "$b_part" ]; then return 1; fi
        a=${a#*.} b=${b#*.}
    done
    return 1
}

# With --only-newer, exits 0 without changing anything unless $version is higher than the cask in $1.
check_newer() {
    [ "$only_newer" = 1 ] || return 0
    cask=$(cask_path "$1")
    if [ ! -e "$cask" ]; then
        echo "the tap has no cask yet; writing $version"
        return 0
    fi
    current=$(sed -n 's/^[[:space:]]*version "\(.*\)"[[:space:]]*$/\1/p' "$cask")
    if ! is_stable_version "$current"; then
        echo "update-tap: cannot read the cask's version (found '$current'); run without --only-newer to set it" >&2
        exit 1
    fi
    if ! is_higher "$version" "$current"; then
        echo "the cask is at $current; $version is not newer, so the cask is left as it is"
        exit 0
    fi
    echo "the cask is at $current; updating it to $version"
}

write_cask() { # directory
    mkdir -p "$1/Casks"
    cat >"$(cask_path "$1")" <<CASK
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

if [ -n "$write_only" ]; then
    check_newer "$write_only"
    write_cask "$write_only"
    echo "wrote $(cask_path "$write_only")"
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
check_newer "$work/tap"
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
