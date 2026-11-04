#!/bin/zsh
# Builds "ARM Sim.app" (release) into ./build. Needs only the Xcode Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product ARMSimIDE

APP="build/ARM Sim.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ARMSimIDE "$APP/Contents/MacOS/ARM Sim"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>ARM Sim</string>
    <key>CFBundleIdentifier</key><string>local.armsim.ide</string>
    <key>CFBundleName</key><string>ARM Sim</string>
    <key>CFBundleDisplayName</key><string>ARM Sim</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>ARM Sim Project</string>
            <key>CFBundleTypeExtensions</key><array><string>armsim</string></array>
            <key>CFBundleTypeRole</key><string>Editor</string>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>µVision Project</string>
            <key>CFBundleTypeExtensions</key><array><string>uvprojx</string></array>
            <key>CFBundleTypeRole</key><string>Viewer</string>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Created $APP"
