#!/bin/sh
# Builds TokensAreRunningOut.app with xcodebuild, which compiles the String Catalog that `swift build`
# only copies, and signs it ad hoc. Developer ID signing and notarization come later (stage 2-4).
#
#   scripts/build-app.sh [--debug] [--snapshots]
#
# --snapshots also builds UISnapshots.app, which renders each screen state to PNG for design review.
set -eu
cd "$(dirname "$0")/.."

configuration=Release
snapshots=0
for arg in "$@"; do
    case "$arg" in
    --debug) configuration=Debug ;;
    --snapshots) snapshots=1 ;;
    *)
        echo "usage: $0 [--debug] [--snapshots]" >&2
        exit 2
        ;;
    esac
done

derived=.build/xcode
products="$derived/Build/Products/$configuration"
version=0.1.0
build=$(git rev-list --count HEAD 2>/dev/null || echo 1)

xcodebuild_product() {
    xcodebuild -scheme "$1" -configuration "$configuration" -destination 'platform=macOS' \
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
    sed -e "s/__IDENTIFIER__/$3/" -e "s/__EXECUTABLE__/$2/" -e "s/__NAME__/$1/" -e "s/__DISPLAY_NAME__/$4/" \
        -e "s/__VERSION__/$version/" -e "s/__BUILD__/$build/" scripts/Info.plist >"$app/Contents/Info.plist"
    codesign --force --sign - "$app" >/dev/null
    echo "built $app"
}

xcodebuild_product TokensAreRunningOut
assemble TokensAreRunningOut TokensAreRunningOut io.github.bingoring.TokensAreRunningOut "Tokens Are Running Out"
if [ "$snapshots" = 1 ]; then
    xcodebuild_product ui-snapshots
    assemble UISnapshots ui-snapshots io.github.bingoring.TokensAreRunningOut.snapshots "UI Snapshots"
fi
