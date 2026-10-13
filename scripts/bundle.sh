#!/bin/sh
# Builds Notchd.app into ./build (ad-hoc signed).
set -e
cd "$(dirname "$0")/.."
./scripts/build-mediaremote.sh
swift build -c release
APP=build/Notchd.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Notchd "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R .build/mediaremote/MediaRemoteAdapter.framework .build/mediaremote/mediaremote-adapter.pl "$APP/Contents/Resources/"
# A stable identity keeps privacy permissions (Calendar, ...) across rebuilds; ad-hoc signing ties them
# to the binary hash, so macOS asks again after every build. Override with NOTCHD_SIGN_IDENTITY.
IDENTITY=${NOTCHD_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep -m1 -o '"Apple Development[^"]*"' | tr -d '"')}
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "$APP"
