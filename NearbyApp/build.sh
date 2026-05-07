#!/bin/bash
# Build Nearby.app for distribution
set -e

cd "$(dirname "$0")"

echo "Building..."
swift build -c release

echo "Packaging app bundle..."
cp .build/release/NearbyApp Nearby.app/Contents/MacOS/Nearby

echo "Signing..."
codesign --force --deep -s - Nearby.app

# Create zip for GitHub Releases
cd Nearby.app/..
rm -f Nearby.zip
ditto -c -k --keepParent Nearby.app Nearby.zip

SIZE=$(du -h Nearby.zip | cut -f1 | xargs)
echo ""
echo "Done: NearbyApp/Nearby.zip ($SIZE)"
echo "Upload this to GitHub Releases"
