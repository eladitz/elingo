#!/bin/zsh
# Builds Elingo.app (Apple Silicon + Intel) with the Command Line Tools; no Xcode needed.
#   ./build.sh               for downloads
#   ./build.sh appstore      for the Mac App Store (sandboxed, no update check)
#   ./build.sh sandbox-test  the App Store build signed ad hoc, to try the sandbox here
set -euo pipefail
MODE=${1:-direct}
BUILD=${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}   # must grow with every App Store upload
FLAGS=()
[[ $MODE != direct ]] && FLAGS=(-D APPSTORE)
cd "$(dirname "$0")"
VERSION=1.0.0
APP=build/Elingo.app
rm -rf "$APP" build/Elingo.iconset
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
    swiftc -parse-as-library -swift-version 5 -O -target $arch-apple-macos26.0 "${FLAGS[@]}" Sources/*.swift -o build/Elingo-$arch
done
lipo -create build/Elingo-arm64 build/Elingo-x86_64 -output "$APP/Contents/MacOS/Elingo"
rm build/Elingo-arm64 build/Elingo-x86_64

swift Icon.swift build/Elingo.iconset
iconutil -c icns build/Elingo.iconset -o "$APP/Contents/Resources/Elingo.icns"
rm -rf build/Elingo.iconset

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Elingo</string>
    <key>CFBundleDisplayName</key><string>Elingo</string>
    <key>CFBundleIdentifier</key><string>com.itzkin.elingo</string>
    <key>CFBundleExecutable</key><string>Elingo</string>
    <key>CFBundleIconFile</key><string>Elingo</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>ITSAppUsesNonExemptEncryption</key><false/>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Elad Itzkin</string>
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSMenuItem</key><dict><key>default</key><string>Translate with Elingo</string></dict>
            <key>NSMessage</key><string>translateFiles</string>
            <key>NSRequiredContext</key><dict/>
            <key>NSSendFileTypes</key><array><string>com.adobe.pdf</string></array>
        </dict>
    </array>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>PDF document</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key><array><string>com.adobe.pdf</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

./sign.sh "$APP" "$MODE"
echo "Built $APP ($MODE)"
