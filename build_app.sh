#!/bin/bash
set -e

APP_NAME="ZoomKeMouse"
APP_BUNDLE="${APP_NAME}.app"
CONTENTS_DIR="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

SDK_PATH=$(xcrun --show-sdk-path)
ARCH=$(uname -m)

echo "=================================================="
echo "🔨 MULAI BUILD: ${APP_NAME}.app (GPU Metal CALayer + App/Screen Capture + Dual Zoom Mode)"
echo "--------------------------------------------------"
echo "• Arsitektur Target : ${ARCH}-apple-macosx13.0"
echo "• macOS SDK Path    : ${SDK_PATH}"
echo "• Daftar File Swift :"
for f in Sources/*.swift; do
    echo "   - $f ($(wc -l < "$f" | tr -d ' ') baris)"
done
echo "=================================================="

mkdir -p "${MACOS_DIR}"
mkdir -p "${RESOURCES_DIR}"

echo "⚙️  [1/3] Menjalankan kompiler swiftc (-O Release Optimization)..."
swiftc \
    -O \
    -target "${ARCH}-apple-macosx13.0" \
    -sdk "${SDK_PATH}" \
    -framework AppKit \
    -framework SwiftUI \
    -framework QuartzCore \
    -framework Metal \
    -framework IOSurface \
    -framework ScreenCaptureKit \
    -framework AVFoundation \
    -framework VideoToolbox \
    -framework CoreGraphics \
    -framework CoreImage \
    -framework CoreMedia \
    -framework CoreVideo \
    -framework UniformTypeIdentifiers \
    Sources/*.swift \
    -o "${MACOS_DIR}/${APP_NAME}"

echo "🎨 [2/4] Menyalin Assets/AppIcon.icns ke Resources..."
cp "Assets/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"

echo "📄 [3/4] Membuat Contents/Info.plist (com.cutefishaep.zoomkmouse)..."
cat > "${CONTENTS_DIR}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>com.cutefishaep.zoomkmouse</string>
    <key>CFBundleName</key>
    <string>Zoom Ke Mouse</string>
    <key>CFBundleDisplayName</key>
    <string>Zoom Ke Mouse</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Zoom Ke Mouse memerlukan izin rekam layar untuk menangkap tampilan layar atau jendela aplikasi Mac Anda dan membuat efek Auto-Zoom.</string>
</dict>
</plist>
EOF

echo "🔏 [4/4] Menandatangani bundel aplikasi (Ad-Hoc Codesign)..."
codesign --force --deep --identifier "com.cutefishaep.zoomkmouse" --sign - "${APP_BUNDLE}" 2>&1 || true

touch "${APP_BUNDLE}"

echo "=================================================="
echo "✅ BUILD SELESAI: $(pwd)/${APP_BUNDLE}"
ls -lh "${MACOS_DIR}/${APP_NAME}" "${RESOURCES_DIR}/AppIcon.icns"
echo "=================================================="
