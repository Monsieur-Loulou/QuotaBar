#!/bin/sh
set -eu
cd "$(dirname "$0")"
case "${1:-}" in
  '') task_universal=false ;;
  --universal) task_universal=true ;;
  *) printf 'Usage: sh build.sh [--universal]\n' >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then printf 'Usage: sh build.sh [--universal]\n' >&2; exit 2; fi
task_app_dir="$PWD/dist/QuotaBar.app"
rm -rf "$task_app_dir/Contents/Helpers"
mkdir -p "$task_app_dir/Contents/MacOS" "$task_app_dir/Contents/Resources"
if [ "$task_universal" = true ]; then
  for task_arch in arm64 x86_64; do
    task_scratch="$PWD/.build/universal-$task_arch"
    swift build --scratch-path "$task_scratch" --triple "$task_arch-apple-macosx14.0" -c release --product QuotaBar
  done
  task_arm_bin=$(swift build --scratch-path "$PWD/.build/universal-arm64" --triple arm64-apple-macosx14.0 -c release --show-bin-path)
  task_intel_bin=$(swift build --scratch-path "$PWD/.build/universal-x86_64" --triple x86_64-apple-macosx14.0 -c release --show-bin-path)
  lipo -create "$task_arm_bin/QuotaBar" "$task_intel_bin/QuotaBar" -output "$task_app_dir/Contents/MacOS/QuotaBar"
  task_bin_dir="$task_arm_bin"
else
  swift build --scratch-path "$PWD/.build/native" -c release --product QuotaBar
  task_bin_dir=$(swift build --scratch-path "$PWD/.build/native" -c release --show-bin-path)
  cp "$task_bin_dir/QuotaBar" "$task_app_dir/Contents/MacOS/QuotaBar"
fi
cp -R "$task_bin_dir/QuotaBar_QuotaBar.bundle" "$task_app_dir/Contents/Resources/"
cp LICENSE "$task_app_dir/Contents/Resources/QuotaBar-LICENSE.txt"
swift scripts/make-app-icon.swift "$PWD/dist/QuotaBar.iconset"
iconutil -c icns "$PWD/dist/QuotaBar.iconset" -o "$task_app_dir/Contents/Resources/QuotaBar.icns"
cat > "$task_app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>fr.garage.QuotaBar</string>
<key>CFBundleName</key><string>QuotaBar</string>
<key>CFBundleDisplayName</key><string>QuotaBar</string>
<key>CFBundleExecutable</key><string>QuotaBar</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.0</string>
<key>CFBundleVersion</key><string>11</string>
<key>CFBundleIconFile</key><string>QuotaBar.icns</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
if [ -n "${QUOTABAR_SIGNING_IDENTITY:-}" ]; then
  /usr/bin/codesign --force --sign "$QUOTABAR_SIGNING_IDENTITY" --options runtime --timestamp "$task_app_dir"
else
  /usr/bin/codesign --force --sign - "$task_app_dir"
fi
/usr/bin/codesign --verify --deep --strict "$task_app_dir"
if [ "$task_universal" = true ]; then
  lipo "$task_app_dir/Contents/MacOS/QuotaBar" -verify_arch arm64 x86_64
fi
"$task_app_dir/Contents/MacOS/QuotaBar" --verify-resources
printf 'Application : %s\n' "$task_app_dir"
