#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="TimeCapsule Revive"
BUNDLE_DIR="build/${APP_NAME}.app"
CONTENTS="${BUNDLE_DIR}/Contents"
MACOS="${CONTENTS}/MacOS"

echo "Building..."
swift build -c debug

# Find the built executable
EXEC=$(swift build --show-bin-path)/TimeCapsuleApp

echo "Creating app bundle..."
rm -rf "${BUNDLE_DIR}"
mkdir -p "${MACOS}"

cp "${EXEC}" "${MACOS}/TimeCapsuleApp"
cp Sources/TimeCapsuleApp/Info.plist "${CONTENTS}/Info.plist"

echo "Signing..."
codesign --force --sign - --entitlements TimeCapsuleApp.entitlements "${BUNDLE_DIR}"

echo ""
echo "Done: ${BUNDLE_DIR}"
echo "Run with: open \"${BUNDLE_DIR}\""
