#!/bin/bash
# Build a fresh Recorder.app, package as Recorder.app.zip, and create a GitHub Release.
#
# Usage: scripts/release.sh <version>     e.g.  scripts/release.sh 1.0.0
#
# Requirements:
#   - gh CLI authenticated for hrosenblume/recorder
#   - Working tree clean (script will warn but proceed)
#
# What it does:
#   1. Updates CFBundleShortVersionString in Resources/Info.plist
#   2. Builds the .app via build-app.sh
#   3. Zips ~/Applications/Recorder.app into ./build/Recorder.app.zip with quarantine stripped
#   4. Creates git tag vX.Y.Z and pushes
#   5. gh release create with the zip attached

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <version>   e.g. $0 1.0.0"
  exit 1
fi
VERSION="$1"

cd "$(dirname "$0")/.."
PLIST="Resources/Info.plist"
APP_PATH="$HOME/Applications/Recorder.app"
BUILD_DIR="build"
ZIP_PATH="${BUILD_DIR}/Recorder.app.zip"

echo "==> Setting CFBundleShortVersionString to ${VERSION}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${PLIST}"

echo "==> Building"
bash scripts/build-app.sh

echo "==> Stripping quarantine and zipping ${APP_PATH}"
xattr -cr "${APP_PATH}" 2>/dev/null || true
mkdir -p "${BUILD_DIR}"
rm -f "${ZIP_PATH}"
# ditto preserves bundle structure + symlinks correctly
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${ZIP_PATH}"
echo "    Wrote $(du -h "${ZIP_PATH}" | awk '{print $1}') ${ZIP_PATH}"

if git diff --quiet "${PLIST}"; then
  echo "==> No version change to commit"
else
  echo "==> Committing version bump"
  git add "${PLIST}"
  git commit -m "Release v${VERSION}"
fi

TAG="v${VERSION}"
if git rev-parse "${TAG}" >/dev/null 2>&1; then
  echo "==> Tag ${TAG} already exists, skipping tag"
else
  echo "==> Tagging ${TAG}"
  git tag "${TAG}"
fi

echo "==> Pushing main + tag"
git push origin main
git push origin "${TAG}"

echo "==> Creating GitHub release ${TAG}"
gh release create "${TAG}" "${ZIP_PATH}" \
  --title "Recorder ${TAG}" \
  --notes "Recorder ${TAG} — see commit history for changes."

echo "==> Released: https://github.com/hrosenblume/recorder/releases/tag/${TAG}"
