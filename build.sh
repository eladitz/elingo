#!/bin/zsh
# Builds Elingo.app (Apple Silicon + Intel) with the Command Line Tools; no Xcode needed.
set -euo pipefail
cd "$(dirname "$0")"
VERSION=1.0.0
APP=build/Elingo.app
rm -rf "$APP" build/Elingo.iconset
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
    swiftc -parse-as-library -swift-version 5 -O -target $arch-apple-macos26.0 Sources/*.swift -o build/Elingo-$arch
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
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Elad Itzkin</string>
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

codesign --force --sign - "$APP"
echo "Built $APP"
