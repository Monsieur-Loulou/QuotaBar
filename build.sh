#!/bin/sh
set -eu
cd "$(dirname "$0")"
sh prepare-reader.sh
swift build -c release --product QuotaBar
task_bin_dir=$(swift build -c release --show-bin-path)
task_app_dir="$PWD/dist/QuotaBar.app"
mkdir -p "$task_app_dir/Contents/MacOS" "$task_app_dir/Contents/Resources" "$task_app_dir/Contents/Helpers"
cp "$task_bin_dir/QuotaBar" "$task_app_dir/Contents/MacOS/QuotaBar"
cp -R "$task_bin_dir/QuotaBar_QuotaBar.bundle" "$task_app_dir/Contents/Resources/"
task_reader_dir="$PWD/.vendor/signed-reader/CodexBar.app/Contents/Helpers"
cp "$task_reader_dir/CodexBarCLI" "$task_app_dir/Contents/Helpers/"
cp -R "$task_reader_dir/CodexBar_CodexBarCore.bundle" "$task_app_dir/Contents/Helpers/"
cat > "$task_app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>fr.garage.QuotaBar</string>
<key>CFBundleName</key><string>QuotaBar</string>
<key>CFBundleDisplayName</key><string>QuotaBar</string>
<key>CFBundleExecutable</key><string>QuotaBar</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.8</string>
<key>CFBundleVersion</key><string>10</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - "$task_app_dir"
/usr/bin/codesign --verify --deep --strict "$task_app_dir"
"$task_app_dir/Contents/MacOS/QuotaBar" --verify-resources
printf 'Application : %s\n' "$task_app_dir"
