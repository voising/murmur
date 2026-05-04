#!/bin/bash
# Build, sign, notarize, and staple a distributable Murmur.app + DMG.
#
# Required env:
#   MURMUR_TEAM_ID         10-char Apple Developer Team ID (e.g. ABCDE12345)
#   MURMUR_NOTARY_PROFILE  notarytool keychain profile name (set up once with
#                          `xcrun notarytool store-credentials`)
#
# Optional env:
#   MURMUR_SIGN_IDENTITY   exact codesign identity. Default: "Developer ID
#                          Application" (matches any Developer ID cert).
#   MURMUR_VERSION         CFBundleShortVersionString. Default: 1.0.0
#   MURMUR_BUILD           CFBundleVersion. Default: 1
#
# Output:
#   dist/Murmur.app        signed + notarized + stapled
#   dist/Murmur-<v>.dmg    signed + notarized + stapled

set -euo pipefail

cd "$(dirname "$0")/.."

: "${MURMUR_TEAM_ID:?Set MURMUR_TEAM_ID to your 10-char Apple Team ID}"
: "${MURMUR_NOTARY_PROFILE:?Set MURMUR_NOTARY_PROFILE to your notarytool keychain profile}"

SIGN_IDENTITY="${MURMUR_SIGN_IDENTITY:-Developer ID Application}"
VERSION="${MURMUR_VERSION:-1.0.0}"
BUILD="${MURMUR_BUILD:-1}"

APP_NAME="Murmur"
BUNDLE_ID="com.railssquad.murmur"
TEAM_NAME="RailsSquad OU"

DIST_DIR="dist"
APP_DIR="${DIST_DIR}/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
ENTITLEMENTS="Murmur.entitlements"
DMG_PATH="${DIST_DIR}/${APP_NAME}-${VERSION}.dmg"

echo "┌─────────────────────────────────────────────────────────"
echo "│ Murmur release"
echo "│   version : ${VERSION} (build ${BUILD})"
echo "│   team    : ${TEAM_NAME} (${MURMUR_TEAM_ID})"
echo "│   identity: ${SIGN_IDENTITY}"
echo "│   notary  : ${MURMUR_NOTARY_PROFILE}"
echo "└─────────────────────────────────────────────────────────"

rm -rf "${DIST_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

echo "==> [1/7] Building universal release binary"
swift build -c release --arch arm64 --arch x86_64
cp ".build/apple/Products/Release/${APP_NAME}" "${MACOS_DIR}/${APP_NAME}"

echo "==> [2/7] Generating icon + Info.plist"
if [ -f "icon-1024.png" ]; then
    ICONSET_DIR="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "${ICONSET_DIR}"
    for size in 16 32 64 128 256 512 1024; do
        sips -z "${size}" "${size}" icon-1024.png --out "${ICONSET_DIR}/icon_${size}x${size}.png" >/dev/null
    done
    cp "${ICONSET_DIR}/icon_32x32.png"     "${ICONSET_DIR}/icon_16x16@2x.png"
    cp "${ICONSET_DIR}/icon_64x64.png"     "${ICONSET_DIR}/icon_32x32@2x.png"
    cp "${ICONSET_DIR}/icon_256x256.png"   "${ICONSET_DIR}/icon_128x128@2x.png"
    cp "${ICONSET_DIR}/icon_512x512.png"   "${ICONSET_DIR}/icon_256x256@2x.png"
    cp "${ICONSET_DIR}/icon_1024x1024.png" "${ICONSET_DIR}/icon_512x512@2x.png"
    rm "${ICONSET_DIR}/icon_64x64.png" "${ICONSET_DIR}/icon_1024x1024.png"
    iconutil -c icns "${ICONSET_DIR}" -o "${RESOURCES_DIR}/AppIcon.icns"
fi

YEAR="$(date +%Y)"
cat > "${CONTENTS_DIR}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © ${YEAR} ${TEAM_NAME}. All rights reserved.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Murmur needs microphone access to record your voice for transcription.</string>
</dict>
</plist>
PLIST

echo "==> [3/7] Signing with hardened runtime"
codesign --force \
    --options runtime \
    --timestamp \
    --entitlements "${ENTITLEMENTS}" \
    --sign "${SIGN_IDENTITY}" \
    "${APP_DIR}"

codesign --verify --strict --verbose=2 "${APP_DIR}"
spctl --assess --type execute --verbose=4 "${APP_DIR}" || true

echo "==> [4/7] Notarizing app"
APP_ZIP="${DIST_DIR}/${APP_NAME}.zip"
ditto -c -k --keepParent "${APP_DIR}" "${APP_ZIP}"
xcrun notarytool submit "${APP_ZIP}" \
    --keychain-profile "${MURMUR_NOTARY_PROFILE}" \
    --wait
rm "${APP_ZIP}"

echo "==> [5/7] Stapling app"
xcrun stapler staple "${APP_DIR}"
xcrun stapler validate "${APP_DIR}"

echo "==> [6/7] Building DMG"
hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${APP_DIR}" \
    -ov -format UDZO \
    "${DMG_PATH}"

codesign --force \
    --timestamp \
    --sign "${SIGN_IDENTITY}" \
    "${DMG_PATH}"

echo "==> [7/7] Notarizing + stapling DMG"
xcrun notarytool submit "${DMG_PATH}" \
    --keychain-profile "${MURMUR_NOTARY_PROFILE}" \
    --wait
xcrun stapler staple "${DMG_PATH}"
xcrun stapler validate "${DMG_PATH}"

echo ""
echo "┌─────────────────────────────────────────────────────────"
echo "│ Done."
echo "│   App : ${APP_DIR}"
echo "│   DMG : ${DMG_PATH}"
echo "└─────────────────────────────────────────────────────────"
