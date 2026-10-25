#!/bin/zsh
# Builds LogiBar.app (menu bar only, ad-hoc signed). Pass --install to copy it to ~/Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
APP=build/LogiBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp .build/release/LogiBar "$APP/Contents/MacOS/LogiBar"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>LogiBar</string>
    <key>CFBundleIdentifier</key><string>com.shashankanil.logibar</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleName</key><string>LogiBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x LogiBar 2>/dev/null || true
    mkdir -p ~/Applications
    rm -rf ~/Applications/LogiBar.app
    cp -R "$APP" ~/Applications/
    open ~/Applications/LogiBar.app
    echo "Installed and launched ~/Applications/LogiBar.app"
fi
