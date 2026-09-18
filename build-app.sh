#!/bin/bash
# Build AB6A TimeShift.app. Signs with a Developer ID when one exists.
#
# The bundle name contains a space, which is miserable as a make target, so the
# bundle assembly lives here and the Makefile just calls this.
set -euo pipefail

cd "$(dirname "$0")"
APP="build/AB6A TimeShift.app"
BIN="AB6A TimeShift"

SIGN_ID="${TIMESHIFT_SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"

echo "==> icon"
if python3 -c 'import PIL' 2>/dev/null; then
    python3 make-icon.py ab6a-timeShift.icns
elif [ -f ab6a-timeShift.icns ]; then
    echo "    Pillow not installed - reusing the existing ab6a-timeShift.icns"
else
    echo "    need Pillow for the icon: python3 -m pip install pillow" >&2
    exit 1
fi

echo "==> compiling"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -swift-version 5 -O -target arm64-apple-macos13.0 \
    -framework AppKit -o "$APP/Contents/MacOS/$BIN" menubar/main.swift

cp ab6a-timeShift.icns "$APP/Contents/Resources/ab6a-timeShift.icns"

echo "==> bundle"
# The identifier deliberately does NOT change with the display name: TCC keys
# microphone access on it, and renaming it would drop the grant.
/usr/libexec/PlistBuddy -c 'Clear dict' \
    -c 'Add :CFBundleName string "AB6A TimeShift"' \
    -c 'Add :CFBundleDisplayName string "AB6A TimeShift"' \
    -c "Add :CFBundleExecutable string \"$BIN\"" \
    -c 'Add :CFBundleIdentifier string com.ab6a.timeshift' \
    -c 'Add :CFBundleIconFile string ab6a-timeShift' \
    -c 'Add :CFBundlePackageType string APPL' \
    -c 'Add :CFBundleShortVersionString string 1.1' \
    -c 'Add :CFBundleVersion string 2' \
    -c 'Add :LSMinimumSystemVersion string 13.0' \
    -c 'Add :LSUIElement bool true' \
    -c 'Add :NSHighResolutionCapable bool true' \
    -c 'Add :NSHumanReadableCopyright string "AB6A"' \
    -c 'Add :NSMicrophoneUsageDescription string "WSJT-X instances launched by AB6A TimeShift receive radio audio through your sound card."' \
    "$APP/Contents/Info.plist" >/dev/null

echo "==> signing"
if [ -n "$SIGN_ID" ]; then
    echo "    $SIGN_ID"
    codesign -f -s "$SIGN_ID" --options runtime --timestamp "$APP"
else
    echo "    ad-hoc (no Developer ID found)"
    codesign -f -s - "$APP"
fi

echo "==> built $APP"
