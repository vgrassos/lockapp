#!/bin/zsh
# Χτίζει το LockApp.app δίπλα σε αυτό το script.
set -e
cd "$(dirname "$0")"

APP=LockApp.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>LockApp</string>
    <key>CFBundleIdentifier</key><string>gr.octo.lockapp</string>
    <key>CFBundleExecutable</key><string>LockApp</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

# Ελάχιστη έκδοση macOS 13, για Apple Silicon και Intel.
for arch in arm64 x86_64; do
    swiftc -O -swift-version 5 -target $arch-apple-macos13.0 main.swift -o "LockApp-$arch"
done
lipo -create LockApp-arm64 LockApp-x86_64 -output "$APP/Contents/MacOS/LockApp"
rm LockApp-arm64 LockApp-x86_64
codesign --force --deep -s - "$APP"
echo "OK: $(pwd)/$APP"
