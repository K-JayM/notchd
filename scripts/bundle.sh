#!/bin/sh
# Builds build/Notchd.app.
#   UNIVERSAL=1      build for Apple Silicon + Intel (CI does this)
#   BUILD_NUMBER=n   CFBundleVersion (defaults to the git commit count)
# The marketing version comes from the VERSION file.
set -e
cd "$(dirname "$0")/.."
./scripts/build-mediaremote.sh

if [ -n "$UNIVERSAL" ]; then ARCHS="--arch arm64 --arch x86_64"; else ARCHS=""; fi
swift build -c release $ARCHS
BIN="$(swift build -c release $ARCHS --show-bin-path)/Notchd"

VERSION=$(cat VERSION)
BUILD_NUMBER=${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}

APP=build/Notchd.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R Resources/Localization/*.lproj "$APP/Contents/Resources/"
cp -R .build/mediaremote/MediaRemoteAdapter.framework .build/mediaremote/mediaremote-adapter.pl "$APP/Contents/Resources/"

# A stable identity keeps privacy permissions (Calendar, ...) across rebuilds; ad-hoc signing ties them
# to the binary hash, so macOS asks again after every build. Override with NOTCHD_SIGN_IDENTITY.
IDENTITY=${NOTCHD_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep -m1 -o '"Apple Development[^"]*"' | tr -d '"')}
IDENTITY=${IDENTITY:--}
# Inside out: the helper framework first, then the app that seals it.
codesign --force --sign "$IDENTITY" "$APP/Contents/Resources/MediaRemoteAdapter.framework"
codesign --force --sign "$IDENTITY" "$APP"
echo "$APP ($VERSION, build $BUILD_NUMBER)"
