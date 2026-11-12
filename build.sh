#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${BUILD_DIR:-$PROJECT_DIR/build}"
APP_NAME="PowerTop"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
EXECUTABLE="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

if [[ ! "$VERSION" =~ ^[0-9]+([.][0-9]+){1,2}$ ]]; then
    echo "Invalid VERSION '$VERSION' (expected a numeric version such as 1.0.0)" >&2
    exit 1
fi
if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
    echo "Invalid BUILD_NUMBER '$BUILD_NUMBER' (expected a positive integer)" >&2
    exit 1
fi

echo "=== Building $APP_NAME $VERSION ($BUILD_NUMBER) ==="
rm -rf "$BUILD_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

echo "Compiling arm64 executable..."
swift build --package-path "$PROJECT_DIR" --configuration release --product "$APP_NAME" --arch arm64
SWIFT_BIN_DIR="$(swift build --package-path "$PROJECT_DIR" --configuration release --arch arm64 --show-bin-path)"
/usr/bin/ditto --noextattr --noqtn "$SWIFT_BIN_DIR/$APP_NAME" "$EXECUTABLE"

# ditto flags prevent source quarantine/provenance attributes entering the bundle.
/usr/bin/ditto --noextattr --noqtn "$PROJECT_DIR/PowerTop/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP_BUNDLE/Contents/Info.plist"

ICONSET_SRC="$PROJECT_DIR/PowerTop/Assets.xcassets/AppIcon.appiconset"
ICONSET_ROOT="$(mktemp -d)"
trap 'rm -rf "$ICONSET_ROOT"' EXIT
ICONSET_DIR="$ICONSET_ROOT/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"
for icon in \
    icon_16x16.png icon_16x16@2x.png \
    icon_32x32.png icon_32x32@2x.png \
    icon_128x128.png icon_128x128@2x.png \
    icon_256x256.png icon_256x256@2x.png \
    icon_512x512.png icon_512x512@2x.png; do
    /usr/bin/ditto --noextattr --noqtn "$ICONSET_SRC/$icon" "$ICONSET_DIR/$icon"
done
xcrun iconutil -c icns "$ICONSET_DIR" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

for lproj in en.lproj zh-Hans.lproj; do
    mkdir -p "$APP_BUNDLE/Contents/Resources/$lproj"
    /usr/bin/ditto --noextattr --noqtn \
        "$PROJECT_DIR/PowerTop/$lproj/Localizable.strings" \
        "$APP_BUNDLE/Contents/Resources/$lproj/Localizable.strings"
done

/usr/bin/ditto --noextattr --noqtn \
    "$PROJECT_DIR/ThirdPartyNotices.txt" "$APP_BUNDLE/Contents/Resources/ThirdPartyNotices.txt"

# Remove any metadata introduced by local tools before signing.
xattr -cr "$APP_BUNDLE"

echo "Built $APP_BUNDLE"
