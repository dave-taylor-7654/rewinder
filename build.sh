#!/bin/zsh
# Build, assemble, and sign Rewinder.app.
#   ./build.sh                  build + sign (Developer ID, hardened runtime)
#   NOTARIZE=1 ./build.sh       also notarize + staple (needs the
#                               "rewinder-notary" keychain profile, see README)
set -e
cd "$(dirname "$0")"
# Signing: put REWINDER_CERT (and REWINDER_NOTARY_PROFILE for notarization)
# in an untracked sign.env. Without it, the build is ad-hoc signed — fine for
# compiling and running your own copy.
[[ -f sign.env ]] && source sign.env
CERT="${REWINDER_CERT:--}"
TSFLAG=(); [[ "$CERT" != "-" ]] && TSFLAG=(--timestamp)
APP="${1:-/Applications/Rewinder.app}"

mkdir -p build
swiftc -O app/main.swift app/Server.swift -o build/Rewinder

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/ui"
cp build/Rewinder "$APP/Contents/MacOS/Rewinder"
cp ui/index.html "$APP/Contents/Resources/ui/"
cp assets/Rewinder.icns "$APP/Contents/Resources/"
cp assets/cwebp "$APP/Contents/Resources/cwebp"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.dtav.rewinder</string>
    <key>CFBundleName</key><string>Rewinder</string>
    <key>CFBundleDisplayName</key><string>Rewinder</string>
    <key>CFBundleExecutable</key><string>Rewinder</string>
    <key>CFBundleIconFile</key><string>Rewinder</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>2.2</string>
    <key>CFBundleVersion</key><string>2.2</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppTransportSecurity</key>
    <dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

xattr -cr "$APP"
# nested executables must be signed before the bundle (notarization requirement)
codesign -f --options runtime "${TSFLAG[@]}" -s "$CERT" "$APP/Contents/Resources/cwebp"
codesign -f --options runtime "${TSFLAG[@]}" -s "$CERT" "$APP"
echo "signed:"
codesign -dv "$APP" 2>&1 | grep -E "Identifier=|Authority=Developer" | head -2

if [[ -n "$NOTARIZE" ]]; then
    echo "notarizing…"
    ditto -c -k --keepParent "$APP" build/Rewinder-notarize.zip
    xcrun notarytool submit build/Rewinder-notarize.zip \
        --keychain-profile "${REWINDER_NOTARY_PROFILE:?set in sign.env}" --wait
    xcrun stapler staple "$APP"
    spctl -a -vv "$APP"
fi
