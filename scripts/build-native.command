#!/bin/zsh
set -eu
cd "${0:A:h}"
BUNDLE_ID="${KEEPCLAM_BUNDLE_ID:-io.github.LCROSSY.keepclam}"
VERSION="${KEEPCLAM_VERSION:-}"; VERSION="${VERSION#v}"; VERSION="${VERSION:-0.1.0}"
APP="../build/KeepClam.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ../Sources/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Universal binary held to the macOS 13 floor promised in the README.
clang -fobjc-arc -arch arm64 -arch x86_64 -mmacosx-version-min=13.0 \
  -framework Cocoa -framework IOKit -framework UserNotifications -framework ServiceManagement \
  ../Sources/App.m -o "$APP/Contents/MacOS/KeepClam"
cp ../Sources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
echo "Built $APP (bundle id: $BUNDLE_ID, version: $VERSION)"
