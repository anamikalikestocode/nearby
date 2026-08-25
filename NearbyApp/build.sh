#!/bin/bash
# Build Nearby.app and package as DMG for distribution
set -e

cd "$(dirname "$0")"

echo "Building..."
swift build -c release

echo "Packaging app bundle..."
cp .build/release/NearbyApp Nearby.app/Contents/MacOS/Nearby

echo "Signing with entitlements + hardened runtime..."
codesign --force --deep --options runtime \
    --entitlements Nearby.entitlements \
    -s "Developer ID Application: Anamika Bhoyrul (98F3BWXPZ2)" Nearby.app

# ---------- Notarization ----------
# Requires a one-time credential setup:
#   xcrun notarytool store-credentials nearby --apple-id YOUR_APPLE_ID --team-id 98F3BWXPZ2
# Without it, Gatekeeper on macOS 15+ blocks the downloaded app with
# "Apple could not verify" and users must approve it in System Settings.
if xcrun notarytool history --keychain-profile nearby > /dev/null 2>&1; then
    echo "Notarizing (this can take a few minutes)..."
    ditto -c -k --keepParent Nearby.app /tmp/nearby-notarize.zip
    xcrun notarytool submit /tmp/nearby-notarize.zip \
        --keychain-profile nearby --wait
    rm -f /tmp/nearby-notarize.zip
    echo "Stapling ticket..."
    xcrun stapler staple Nearby.app
else
    echo "⚠️  Skipping notarization — no 'nearby' keychain profile found."
    echo "   Users on macOS 15+ will hit a Gatekeeper warning. To fix, run:"
    echo "   xcrun notarytool store-credentials nearby --apple-id YOUR_APPLE_ID --team-id 98F3BWXPZ2"
fi

# ---------- DMG ----------
echo "Creating DMG..."
DMG_NAME="Nearby"
DMG_TEMP="/tmp/nearby-dmg-$$"
DMG_FILE="${DMG_NAME}.dmg"

rm -rf "$DMG_TEMP" "$DMG_FILE"
mkdir -p "$DMG_TEMP"

# Copy the signed app into the staging folder
cp -R Nearby.app "$DMG_TEMP/"

# Create a symlink to /Applications so the user can drag
ln -s /Applications "$DMG_TEMP/Applications"

# Add hidden background image folder
if [ -f dmg_background.png ]; then
    mkdir -p "$DMG_TEMP/.background"
    cp dmg_background.png "$DMG_TEMP/.background/bg.png"
fi

# Create the DMG (read-write first, then convert to compressed read-only)
hdiutil create -srcfolder "$DMG_TEMP" \
    -volname "$DMG_NAME" \
    -fs HFS+ \
    -format UDRW \
    -ov "/tmp/${DMG_NAME}_rw.dmg"

# Mount it so we can set Finder view options
MOUNT_DIR=$(hdiutil attach "/tmp/${DMG_NAME}_rw.dmg" -readwrite -noverify | grep "/Volumes/" | tail -1 | awk '{print $NF}')

# Set Finder window appearance via AppleScript
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$DMG_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {100, 100, 640, 480}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 110
        -- Set background image if it exists
        try
            set background picture of viewOptions to file ".background:bg.png"
        end try
        -- Position the app on the left, Applications on the right
        set position of item "Nearby.app" of container window to {130, 160}
        set position of item "Applications" of container window to {410, 160}
        close
    end tell
end tell
APPLESCRIPT

# Give Finder a moment to write .DS_Store
sleep 2

# Unmount
hdiutil detach "$MOUNT_DIR" -quiet

# Convert to compressed read-only DMG
hdiutil convert "/tmp/${DMG_NAME}_rw.dmg" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$DMG_FILE"

rm -f "/tmp/${DMG_NAME}_rw.dmg"
rm -rf "$DMG_TEMP"

# Also keep the zip for the curl one-liner
rm -f Nearby.zip
ditto -c -k --keepParent Nearby.app Nearby.zip

DMG_SIZE=$(du -h "$DMG_FILE" | cut -f1 | xargs)
ZIP_SIZE=$(du -h Nearby.zip | cut -f1 | xargs)
echo ""
echo "Done!"
echo "  DMG: NearbyApp/${DMG_FILE} ($DMG_SIZE) — upload to GitHub Releases"
echo "  ZIP: NearbyApp/Nearby.zip ($ZIP_SIZE) — for curl one-liner"
