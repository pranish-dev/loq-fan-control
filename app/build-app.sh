#!/bin/sh
set -e
cd "$(dirname "$0")"
swift build -c release
APP="LOQ Fan Control.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/LOQControl "$APP/Contents/MacOS/LOQControl"
# App icon: regenerate with  cd icon && swift make-icon.swift icon-1024.png  if missing.
if [ ! -f icon/AppIcon.icns ]; then
  (cd icon && sh ../icon/build-iconset.sh)
fi
cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LOQControl</string>
<key>CFBundleIdentifier</key><string>com.local.LOQControl</string>
<key>CFBundleName</key><string>LOQ Fan Control</string>
<key>CFBundleDisplayName</key><string>LOQ Fan Control</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.0</string>
<key>CFBundleVersion</key><string>3</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PL
codesign --force --sign - "$APP" 2>/dev/null || true
echo "Built: $APP   (run: open \"$APP\")"
