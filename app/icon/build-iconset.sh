#!/bin/sh
# Regenerates AppIcon.icns from make-icon.swift. Only needed when the icon changes;
# build-app.sh runs this automatically if icon/AppIcon.icns is missing.
set -e
cd "$(dirname "$0")"
swift make-icon.swift icon-1024.png
rm -rf AppIcon.iconset
mkdir AppIcon.iconset
for logical in 16 32 128 256 512; do
  px=$((logical * 2))
  sips -z $logical $logical icon-1024.png --out "AppIcon.iconset/icon_${logical}x${logical}.png" >/dev/null
  sips -z $px $px icon-1024.png --out "AppIcon.iconset/icon_${logical}x${logical}@2x.png" >/dev/null
done
iconutil -c icns AppIcon.iconset -o AppIcon.icns
rm -rf AppIcon.iconset preview-512.png preview-64.png
echo "Built icon/AppIcon.icns"
