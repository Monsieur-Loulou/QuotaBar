#!/bin/sh
# Resource checks are offline; the default final check reads connected accounts.
set -eu
cd "$(dirname "$0")"
if [ "$#" -gt 1 ]; then
  printf 'Usage: sh verify-standalone.sh [--offline]\n' >&2
  exit 2
fi
case "${1:-}" in
  ''|--offline) ;;
  *) printf 'Usage: sh verify-standalone.sh [--offline]\n' >&2; exit 2 ;;
esac
task_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/quotabar-standalone.XXXXXX")
trap 'rm -rf "$task_test_dir"' EXIT HUP INT TERM
ditto dist/QuotaBar.app "$task_test_dir/QuotaBar.app"
cat > "$task_test_dir/without-codexbar.sb" <<'PROFILE'
(version 1)
(allow default)
(deny file-read* (regex #"/CodexBar[.]app(/|$)"))
(deny process-exec (regex #"/CodexBar[.]app(/|$)"))
(deny file-read* (subpath (param "QUOTA_BUILD")))
(deny file-read* (subpath (param "QUOTA_VENDOR")))
(deny file-read* (subpath (param "QUOTA_DIST")))
PROFILE
run_isolated() {
  sandbox-exec -D "QUOTA_BUILD=$PWD/.build" -D "QUOTA_VENDOR=$PWD/.vendor" \
    -D "QUOTA_DIST=$PWD/dist" -f "$task_test_dir/without-codexbar.sb" "$@"
}
# Confirm the test really blocks a CodexBar.app executable, using a harmless fixture.
mkdir -p "$task_test_dir/CodexBar.app"
cp /usr/bin/true "$task_test_dir/CodexBar.app/ReaderProbe"
if run_isolated "$task_test_dir/CodexBar.app/ReaderProbe" 2>/dev/null; then
  printf 'Isolation check failed: CodexBar.app is accessible\n' >&2
  exit 1
fi
for task_build_folder in .build .vendor dist; do
  if run_isolated /bin/ls "$PWD/$task_build_folder" >/dev/null 2>&1; then
    printf 'Isolation check failed: %s is accessible\n' "$task_build_folder" >&2
    exit 1
  fi
done
printf 'CodexBar.app and build folders are inaccessible to the test process\n'
codesign --verify --deep --strict "$task_test_dir/QuotaBar.app"
run_isolated "$task_test_dir/QuotaBar.app/Contents/MacOS/QuotaBar" --verify-resources
if [ "${1:-}" != --offline ]; then
  run_isolated "$task_test_dir/QuotaBar.app/Contents/MacOS/QuotaBar" --check
fi
