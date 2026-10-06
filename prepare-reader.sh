#!/bin/sh
# Build-time only: fetch a pinned public release, never an installed application.
set -eu
cd "$(dirname "$0")"
task_archive=".vendor/downloads/CodexBar-macos-universal-0.72.0.zip"
task_archive_sha="6cd4a793d493d2216c0f31b839cd94feed47e543cb6767930d68659768091c91"
mkdir -p .vendor/downloads
if [ ! -f "$task_archive" ]; then
  curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 \
    'https://github.com/steipete/CodexBar/releases/download/v0.72.0/CodexBar-macos-universal-0.72.0.zip' \
    --output "$task_archive.partial"
  printf '%s  %s\n' "$task_archive_sha" "$task_archive.partial" | shasum -a 256 -c -
  mv "$task_archive.partial" "$task_archive"
fi
printf '%s  %s\n' "$task_archive_sha" "$task_archive" | shasum -a 256 -c -
task_reader_dir="$PWD/.vendor/signed-reader/CodexBar.app/Contents/Helpers"
# Start clean: files left by another reader version would break the bundle signature.
rm -rf .vendor/signed-reader
mkdir -p .vendor/signed-reader
unzip -qo "$task_archive" \
  'CodexBar.app/Contents/Helpers/CodexBarCLI' \
  'CodexBar.app/Contents/Helpers/CodexBar_CodexBarCore.bundle/*' \
  -d .vendor/signed-reader
printf '%s  %s\n' '3133dd8c790a4fcd2eb5db578932382d175c06770884d49bf9767ef627596da6' \
  "$task_reader_dir/CodexBarCLI" | shasum -a 256 -c -
codesign --verify --strict \
  -R '=anchor apple generic and identifier "CodexBarCLI" and certificate leaf[subject.OU] = "Y5PE65HELJ"' \
  "$task_reader_dir/CodexBarCLI"
codesign --verify --strict "$task_reader_dir/CodexBar_CodexBarCore.bundle"
