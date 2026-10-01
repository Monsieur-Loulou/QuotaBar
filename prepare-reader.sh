#!/bin/sh
# Build-time only: fetch a pinned public release, never an installed application.
set -eu
cd "$(dirname "$0")"
task_archive=".vendor/downloads/CodexBar-macos-universal-0.52.0.zip"
task_archive_sha="92cfbe11857a8d65b98181d6ed7234a6078ac24bf53ad162bda8dd208fa68cd6"
mkdir -p .vendor/downloads
if [ ! -f "$task_archive" ]; then
  curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 \
    'https://github.com/steipete/CodexBar/releases/download/v0.52.0/CodexBar-macos-universal-0.52.0.zip' \
    --output "$task_archive.partial"
  printf '%s  %s\n' "$task_archive_sha" "$task_archive.partial" | shasum -a 256 -c -
  mv "$task_archive.partial" "$task_archive"
fi
printf '%s  %s\n' "$task_archive_sha" "$task_archive" | shasum -a 256 -c -
task_reader_dir="$PWD/.vendor/signed-reader/CodexBar.app/Contents/Helpers"
mkdir -p .vendor/signed-reader
unzip -qo "$task_archive" \
  'CodexBar.app/Contents/Helpers/CodexBarCLI' \
  'CodexBar.app/Contents/Helpers/CodexBar_CodexBarCore.bundle/*' \
  -d .vendor/signed-reader
printf '%s  %s\n' '4ab57c1ba3001631c0854de12adc0ebb87494215d6cf269b5fe75497a1eb6626' \
  "$task_reader_dir/CodexBarCLI" | shasum -a 256 -c -
codesign --verify --strict \
  -R '=anchor apple generic and identifier "CodexBarCLI" and certificate leaf[subject.OU] = "Y5PE65HELJ"' \
  "$task_reader_dir/CodexBarCLI"
codesign --verify --strict "$task_reader_dir/CodexBar_CodexBarCore.bundle"
