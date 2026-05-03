#!/bin/bash
# Build Recorder.app from SwiftPM output and ad-hoc codesign with a stable
# identifier so TCC remembers Screen Recording / Microphone grants across rebuilds.
#
# IMPORTANT: do NOT delete ~/Applications/Recorder.app between builds — overwriting
# preserves the TCC entries keyed on bundle id + signing identifier + path.

set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="Recorder"
BUNDLE_ID="com.hunter.recorder"
BIN_NAME="recorder"
APP_PATH="$HOME/Applications/${APP_NAME}.app"

echo "==> Generating icon"
if [ ! -f "Resources/Recorder.icns" ] || [ "scripts/generate-icon.swift" -nt "Resources/Recorder.icns" ]; then
  swift scripts/generate-icon.swift Resources/Recorder.icns
else
  echo "    (cached)"
fi

echo "==> swift build -c release"
swift build -c release

echo "==> Assembling ${APP_PATH}"
mkdir -p "${APP_PATH}/Contents/MacOS"
mkdir -p "${APP_PATH}/Contents/Resources"

cp -f ".build/release/${BIN_NAME}"  "${APP_PATH}/Contents/MacOS/${BIN_NAME}"
cp -f "Resources/Info.plist"        "${APP_PATH}/Contents/Info.plist"
cp -f "Resources/Recorder.icns"     "${APP_PATH}/Contents/Resources/Recorder.icns"

echo "==> Ad-hoc codesigning with stable identifier ${BUNDLE_ID}"
codesign --force --sign - --identifier "${BUNDLE_ID}" "${APP_PATH}"

echo "==> Done: ${APP_PATH}"
echo "    Launch with: open \"${APP_PATH}\""
