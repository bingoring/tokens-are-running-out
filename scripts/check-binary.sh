#!/bin/sh
# Checks the built app for what scripts/check-anti-goals.py cannot see in the source: in each slice
# (arm64 and x86_64) of the executable, no undefined network symbol and no network or web framework
# linked; and a signature with no entitlements.
#
#   scripts/check-binary.sh .build/apps/TokensAreRunningOut.app
set -eu

app="${1:?usage: scripts/check-binary.sh APP_PATH}"
problems=0
problem() { echo "check-binary: $*" >&2; problems=$((problems + 1)); }
die() { echo "check-binary: $*" >&2; exit 2; }

# C functions are matched by exact name (x86_64 adds suffixes like $NOCANCEL); Network.framework's C API
# by its nw_ prefix; classes and CoreFoundation families anywhere in the name, mangled Swift included.
symbols='^_(socket|connect|getaddrinfo|getnameinfo)(\$.*)?$|^_nw_|CFSocket|CFStream|CFHTTP|NSURLSession|NSURLConnection|URLSession|NWConnection'
libraries='CFNetwork\.framework|/Network\.framework/|WebKit\.framework|libswiftNetwork|libswiftWebKit'

# Prints the lines of $2 that match the extended regex $1. A grep error stops the check instead of
# reading as "no match".
search() {
    set +e
    found=$(printf '%s\n' "$2" | grep -E -- "$1")
    status=$?
    set -e
    [ "$status" -le 1 ] || die "grep failed ($status)"
    printf '%s' "$found"
}

[ -d "$app" ] || die "not an app bundle: $app"
executable=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$app/Contents/Info.plist") ||
    die "no CFBundleExecutable in $app/Contents/Info.plist"
binary="$app/Contents/MacOS/$executable"
[ -f "$binary" ] || die "no executable at $binary"
archs=$(lipo -archs "$binary") || die "lipo cannot read $binary"

for arch in arm64 x86_64; do
    case " $archs " in
    *" $arch "*) ;;
    *) problem "$arch: no slice (the executable has: $archs)"; continue ;;
    esac
    undefined=$(nm -u -arch "$arch" "$binary") || die "$arch: nm failed"
    [ -n "$undefined" ] || die "$arch: nm listed no undefined symbols"
    linked=$(otool -L -arch "$arch" "$binary") || die "$arch: otool failed"
    linked=$(printf '%s\n' "$linked" | sed 1d) # the first line names the executable itself
    [ -n "$linked" ] || die "$arch: otool listed no libraries"

    hits=$(search "$symbols" "$undefined") || exit 2
    if [ -n "$hits" ]; then
        printf '%s\n' "$hits" | sed "s/^/  $arch symbol: /" >&2
        problem "$arch: $(printf '%s\n' "$hits" | wc -l | tr -d ' ') network symbol(s)"
    fi
    hits=$(search "$libraries" "$linked") || exit 2
    if [ -n "$hits" ]; then
        printf '%s\n' "$hits" | sed "s/^[[:space:]]*/  $arch links: /" >&2
        problem "$arch: $(printf '%s\n' "$hits" | wc -l | tr -d ' ') network or web framework(s) linked"
    fi
    echo "$arch: $(printf '%s\n' "$undefined" | wc -l | tr -d ' ') undefined symbols and" \
        "$(printf '%s\n' "$linked" | wc -l | tr -d ' ') libraries checked"
done

# No entitlements (RL-4): codesign prints nothing, or at most an empty dictionary.
entitlements=$(codesign -d --entitlements - --xml "$app" 2>/dev/null) || die "codesign cannot read the signature of $app"
if [ -n "$entitlements" ]; then
    if ! printf '%s' "$entitlements" |
        python3 -I -c 'import plistlib, sys; sys.exit(0 if plistlib.loads(sys.stdin.buffer.read()) == {} else 1)'; then
        printf '  entitlements: %s\n' "$entitlements" >&2
        problem "the signature has entitlements"
    else
        echo "entitlements: none (empty dictionary)"
    fi
else
    echo "entitlements: none"
fi

if [ "$problems" -gt 0 ]; then
    echo "check-binary: $problems problem(s) in $app" >&2
    exit 1
fi
echo "check-binary: ok ($archs)"
