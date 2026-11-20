#!/bin/sh
# Builds TokensAreRunningOut.app with xcodebuild, which compiles the String Catalog that `swift build`
# only copies, and signs it ad hoc. scripts/release.sh signs it with Developer ID and notarizes it.
#
#   scripts/build-app.sh [--debug] [--snapshots] [--release VERSION]
#
# --release VERSION builds a universal (arm64 and x86_64) Release app with that version, e.g. 0.1.0-rc.1.
# --snapshots also builds UISnapshots.app, which renders each screen state to PNG for design review.
set -eu
cd "$(dirname "$0")/.."

configuration=Release
snapshots=0
release=""
while [ $# -gt 0 ]; do
    case "$1" in
    --debug) configuration=Debug ;;
    --snapshots) snapshots=1 ;;
    --release)
        if [ $# -lt 2 ] || [ -z "$2" ]; then
            echo "--release takes a version like 1.2.3 or 1.2.3-rc.1" >&2
            exit 2
        fi
        release="$2"
        shift
        ;;
    *)
        echo "usage: $0 [--debug] [--snapshots] [--release VERSION]" >&2
        exit 2
        ;;
    esac
    shift
done

if [ -n "$release" ]; then
    # CFBundleShortVersionString takes digits and dots only, so a pre-release suffix stays out of it.
    version="${release%%-*}"
    if ! echo "$release" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$'; then
        echo "--release takes a version like 1.2.3 or 1.2.3-rc.1" >&2
        exit 2
    fi
    configuration=Release
    destination='generic/platform=macOS'
else
    version=0.1.0
    destination="platform=macOS,arch=$(uname -m)"
fi

derived=.build/xcode
products="$derived/Build/Products/$configuration"
build=$(git rev-list --count HEAD 2>/dev/null || echo 1)

xcodebuild_product() {
    xcodebuild -scheme "$1" -configuration "$configuration" -destination "$destination" \
        -derivedDataPath "$derived" -quiet build
}

assemble() { # name executable identifier display-name
    app=".build/apps/$1.app"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$products/$2" "$app/Contents/MacOS/$2"
    for bundle in "$products"/*.bundle; do
        [ -d "$bundle" ] && cp -R "$bundle" "$app/Contents/Resources/"
    done
    cp Assets/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
    sed -e "s/__IDENTIFIER__/$3/" -e "s/__EXECUTABLE__/$2/" -e "s/__NAME__/$1/" -e "s/__DISPLAY_NAME__/$4/" \
        -e "s/__VERSION__/$version/" -e "s/__BUILD__/$build/" scripts/Info.plist >"$app/Contents/Info.plist"
    codesign --force --sign - "$app" 2>&1 | grep -v "replacing existing signature" || true
    echo "built $app ($version, build $build)"
}

xcodebuild_product TokensAreRunningOut
assemble TokensAreRunningOut TokensAreRunningOut io.github.bingoring.TokensAreRunningOut "Tokens Are Running Out"
if [ "$snapshots" = 1 ]; then
    xcodebuild_product ui-snapshots
    assemble UISnapshots ui-snapshots io.github.bingoring.TokensAreRunningOut.snapshots "UI Snapshots"
fi
