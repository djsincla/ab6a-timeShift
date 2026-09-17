#!/bin/bash
# Notarize and staple ab6a-timeShift.app, then produce a release zip.
#
# One-time setup - stores your app-specific password in the keychain so it never
# appears on a command line or in this repo:
#
#   xcrun notarytool store-credentials ab6a-timeshift \
#       --apple-id you@example.com \
#       --team-id HG979YFABK \
#       --password xxxx-xxxx-xxxx-xxxx
#
# The password is an app-specific password from https://account.apple.com,
# not your Apple ID password.
set -euo pipefail

cd "$(dirname "$0")"
APP="ab6a-timeShift.app"
PROFILE="${NOTARY_PROFILE:-ab6a-timeshift}"
VERSION=$(defaults read "$PWD/$APP/Contents/Info.plist" CFBundleShortVersionString)
ZIP="ab6a-timeShift-${VERSION}.zip"

[ -d "$APP" ] || { echo "no build - run 'make menubar' first" >&2; exit 1; }

echo "==> checking the signature is notarizable"
# capture rather than pipe into grep -q: grep exits on the first match, codesign
# takes SIGPIPE, and under `set -o pipefail` that reads as a failed check
SIGINFO=$(codesign -dv "$APP" 2>&1 || true)
case "$SIGINFO" in
    *"flags="*runtime*) ;;
    *)
        echo "    the app is not signed with the hardened runtime." >&2
        echo "    'make menubar' signs it automatically when a Developer ID cert exists." >&2
        exit 1 ;;
esac
case "$SIGINFO" in
    *"TeamIdentifier=HG979YFABK"*) ;;
    *) echo "    warning: unexpected team identifier" >&2 ;;
esac
codesign --verify --deep --strict --verbose=1 "$APP"

echo "==> submitting to Apple"
# ditto, not zip: it preserves the bundle structure and the signature
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "==> stapling"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
echo "==> $ZIP is notarized and stapled"

echo
echo "Verify it the way Gatekeeper will:"
echo "    spctl -a -vvv -t exec \"$APP\""
echo
echo "Note: the shim dylib and the re-signed WSJT-X copy are signed with the"
echo "same Developer ID, which is what lets library validation accept the shim."
