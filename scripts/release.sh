#!/bin/sh
# Signs the app from `scripts/build-app.sh --release VERSION` with Developer ID (hardened runtime, secure
# timestamp), notarizes it, staples the ticket and packages it as a zip with its SHA-256.
#
#   scripts/release.sh --version VERSION --identity SHA1 [--keychain PATH] \
#       --notary-key AuthKey.p8 --notary-key-id ID --notary-issuer UUID
#   scripts/release.sh --version VERSION --dry-run     # ad-hoc signature, no notarization
#
# Output: .build/dist/TokensAreRunningOut-VERSION.zip and .zip.sha256
set -eu
cd "$(dirname "$0")/.."

version="" identity="" keychain="" key="" key_id="" issuer="" dry_run=0
while [ $# -gt 0 ]; do
    case "$1" in
    --version) version="$2"; shift ;;
    --identity) identity="$2"; shift ;;
    --keychain) keychain="$2"; shift ;;
    --notary-key) key="$2"; shift ;;
    --notary-key-id) key_id="$2"; shift ;;
    --notary-issuer) issuer="$2"; shift ;;
    --dry-run) dry_run=1 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
    esac
    shift
done
fail() { echo "release: $*" >&2; exit 1; }
[ -n "$version" ] || fail "--version is required"
if [ "$dry_run" = 0 ]; then
    [ -n "$identity" ] && [ -n "$key" ] && [ -n "$key_id" ] && [ -n "$issuer" ] ||
        fail "--identity, --notary-key, --notary-key-id and --notary-issuer are required (or --dry-run)"
fi

app=.build/apps/TokensAreRunningOut.app
out=.build/dist # not .build/release, which is SwiftPM's link to its release products
asset="TokensAreRunningOut-$version.zip"
[ -d "$app" ] || fail "build first: scripts/build-app.sh --release $version"
rm -rf "$out"
mkdir -p "$out"

# The bundle must be the version being released, and universal.
plist_version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")
[ "$plist_version" = "${version%%-*}" ] || fail "the app is $plist_version, not ${version%%-*}"
archs=$(lipo -archs "$app/Contents/MacOS/TokensAreRunningOut")
case "$archs" in *arm64*) ;; *) fail "no arm64 slice ($archs)" ;; esac
case "$archs" in *x86_64*) ;; *) fail "no x86_64 slice ($archs)" ;; esac

# Sign: hardened runtime, no entitlements (RL-4).
if [ "$dry_run" = 1 ]; then
    codesign --force --options runtime --timestamp=none --sign - "$app" 2>&1 | grep -v "replacing existing" || true
else
    codesign --force --options runtime --timestamp --sign "$identity" ${keychain:+--keychain "$keychain"} "$app"
fi
codesign --verify --strict --deep "$app" || fail "the signature does not verify"
codesign -dvv "$app" 2>&1 | grep -q 'flags=0x[0-9a-f]*(.*runtime' || fail "hardened runtime is not on"
echo "signed: hardened runtime, $archs"

if [ "$dry_run" = 0 ]; then
    ditto -c -k --keepParent "$app" "$out/submit.zip"
    # notarytool prints its JSON on stdout when the submission is accepted, and on stderr when it is not or
    # when the wait times out. Read both and take the JSON line.
    output=$(xcrun notarytool submit "$out/submit.zip" --key "$key" --key-id "$key_id" --issuer "$issuer" \
        --wait --timeout 30m --output-format json 2>&1) || true
    json=$(printf '%s\n' "$output" | grep '^{' | tail -n 1)
    field() { printf '%s' "$json" | python3 -c "import json, sys; print(json.load(sys.stdin).get('$1', ''))" 2>/dev/null || true; }
    status=$(field status)
    id=$(field id)
    echo "notarization: ${status:-no status}${id:+, submission $id}"
    if [ "$status" != "Accepted" ]; then
        printf '%s\n' "$output" >&2
        case "$status" in
        Invalid | Rejected) xcrun notarytool log "$id" --key "$key" --key-id "$key_id" --issuer "$issuer" || true ;;
        esac
        if [ -n "$id" ] && [ -z "$status" ]; then
            echo "Apple is still processing it. Check later with: xcrun notarytool info $id" \
                "--key <AuthKey.p8> --key-id <key ID> --issuer <issuer ID>" >&2
        fi
        fail "notarization was not accepted"
    fi
    rm "$out/submit.zip"
    # stapler cannot staple a zip: staple the app, then zip it again.
    xcrun stapler staple -q "$app" || fail "stapling failed"
    xcrun stapler validate -q "$app" || fail "the stapled ticket does not validate"
    assessment=$(spctl --assess --type execute -vv "$app" 2>&1 || true)
    case "$assessment" in
    *"source=Notarized Developer ID"*) ;;
    *) printf '%s\n' "$assessment" >&2; fail "Gatekeeper does not accept the app as notarized" ;;
    esac
    echo "gatekeeper: accepted (Notarized Developer ID)"
fi

ditto -c -k --keepParent "$app" "$out/$asset"
(cd "$out" && shasum -a 256 "$asset" >"$asset.sha256")
echo "packaged $out/$asset"
cat "$out/$asset.sha256"
