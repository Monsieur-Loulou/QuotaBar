#!/bin/sh
set -eu
cd "$(dirname "$0")"
task_app="$PWD/dist/QuotaBar.app"
task_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$task_app/Contents/Info.plist")
lipo "$task_app/Contents/MacOS/QuotaBar" -verify_arch arm64 x86_64
lipo "$task_app/Contents/Helpers/CodexBarCLI" -verify_arch arm64 x86_64
codesign --verify --deep --strict "$task_app"
"$task_app/Contents/MacOS/QuotaBar" --verify-resources
task_release_dir="$PWD/dist/release-$task_version"
if [ -e "$task_release_dir" ]; then
  printf 'Release directory exists; preserve it or choose a new version before packaging.\n' >&2
  exit 1
fi
mkdir -p "$task_release_dir"
task_stage=$(mktemp -d "${TMPDIR:-/tmp}/quotabar-package.XXXXXX")
trap 'rm -rf "$task_stage"' EXIT HUP INT TERM
ditto --norsrc --noextattr "$task_app" "$task_stage/QuotaBar.app"
codesign --verify --deep --strict "$task_stage/QuotaBar.app"
ln -s /Applications "$task_stage/Applications"
cat > "$task_stage/Installer.txt" <<'TXT'
QuotaBar pour macOS 14 ou plus récent, Mac Intel et Apple Silicon.

1. Glisse QuotaBar dans Applications.
2. Ouvre QuotaBar depuis Applications.
3. Clique sur Vérifier les connexions au premier lancement.

La connexion Codex doit être présente sur ce Mac et Claude connecté sur
claude.ai dans un navigateur compatible. Le lecteur est inclus ; aucune
compilation ni installation de CodexBar n'est nécessaire.

Ce paquet n'est pas notarisé par Apple. macOS peut bloquer son ouverture
après téléchargement. Consulte l’aide officielle Apple avant de décider
de l’autoriser : https://support.apple.com/fr-fr/102445
QuotaBar ne modifie pas les protections du Mac.
TXT
cp "$task_stage/Installer.txt" "$task_release_dir/Installer.txt"
ditto -c -k --norsrc --noextattr --keepParent "$task_stage/QuotaBar.app" "$task_release_dir/QuotaBar-$task_version-universal.zip"
hdiutil create -volname QuotaBar -srcfolder "$task_stage" -format UDZO "$task_release_dir/QuotaBar-$task_version-universal.dmg"
(cd "$task_release_dir" && shasum -a 256 ./*.zip ./*.dmg > SHA256SUMS.txt)
printf 'Release assets : %s\n' "$task_release_dir"
