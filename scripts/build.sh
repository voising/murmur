#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

echo "Building Murmur..."
swift build -c release

APP_NAME="Murmur"
APP_DIR=".build/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

# Clean previous bundle
rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

# Copy binary
cp ".build/release/${APP_NAME}" "${MACOS_DIR}/${APP_NAME}"

# Generate .icns from icon-1024.png
if [ -f "icon-1024.png" ]; then
    ICONSET_DIR="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "${ICONSET_DIR}"
    for size in 16 32 64 128 256 512 1024; do
        sips -z "${size}" "${size}" icon-1024.png --out "${ICONSET_DIR}/icon_${size}x${size}.png" >/dev/null
    done
    # @2x variants
    cp "${ICONSET_DIR}/icon_32x32.png"   "${ICONSET_DIR}/icon_16x16@2x.png"
    cp "${ICONSET_DIR}/icon_64x64.png"   "${ICONSET_DIR}/icon_32x32@2x.png"
    cp "${ICONSET_DIR}/icon_256x256.png" "${ICONSET_DIR}/icon_128x128@2x.png"
    cp "${ICONSET_DIR}/icon_512x512.png" "${ICONSET_DIR}/icon_256x256@2x.png"
    cp "${ICONSET_DIR}/icon_1024x1024.png" "${ICONSET_DIR}/icon_512x512@2x.png"
    rm "${ICONSET_DIR}/icon_64x64.png" "${ICONSET_DIR}/icon_1024x1024.png"
    iconutil -c icns "${ICONSET_DIR}" -o "${RESOURCES_DIR}/AppIcon.icns"
fi

# Generate Info.plist
cat > "${CONTENTS_DIR}/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Murmur</string>
    <key>CFBundleIdentifier</key>
    <string>com.railssquad.murmur</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleExecutable</key>
    <string>Murmur</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Murmur needs microphone access to record your voice for transcription.</string>
</dict>
</plist>
PLIST

# Prefer stable self-signed identity so TCC grants persist across rebuilds.
# Falls back to ad-hoc if the cert isn't installed — see scripts/setup-signing.sh.
SIGN_IDENTITY="-"
if security find-certificate -c "MurmurSign" >/dev/null 2>&1; then
    SIGN_IDENTITY="MurmurSign"
fi
codesign --force --deep --sign "${SIGN_IDENTITY}" "${APP_DIR}"

echo "Built: ${APP_DIR}"
echo "Run with: open ${APP_DIR}"
