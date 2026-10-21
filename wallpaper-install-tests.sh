#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_BUNDLE="${1:-$ROOT_DIR/build/MatrixWallpaper.app}"
if [[ ! -d "$SOURCE_BUNDLE" ]]; then
  echo "Build the app with ./build-wallpaper.sh before running installer checks." >&2
  exit 1
fi
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/matrix-wallpaper-install-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
export HOME="$TEST_DIR/home"
mkdir -p "$HOME" "$TEST_DIR/bin"
export PATH="$TEST_DIR/bin:$PATH"

# Test copies never start an app or interact with real running processes.
export QUIT_LOG="$TEST_DIR/quit-request"
cat > "$TEST_DIR/bin/osascript" <<'SCRIPT'
#!/bin/bash
cat >/dev/null
[[ "${SIMULATE_QUIT_FAILURE:-0}" != 1 ]] || exit 1
touch "$QUIT_LOG"
SCRIPT
cat > "$TEST_DIR/bin/ditto" <<'SCRIPT'
#!/bin/bash
[[ "${FAIL_COPY:-0}" != 1 ]] || exit 1
/usr/bin/ditto "$@"
if [[ "${CORRUPT_COPY:-0}" == 1 ]]; then
  printf 'corrupt' >> "$2/Contents/MacOS/MatrixWallpaper"
fi
SCRIPT
cat > "$TEST_DIR/bin/mv" <<'SCRIPT'
#!/bin/bash
if [[ "${FAIL_PROMOTION:-0}" == 1 && "$1" == */.MatrixWallpaper-install.*/MatrixWallpaper.app ]]; then
  exit 1
fi
/bin/mv "$@"
SCRIPT
chmod +x "$TEST_DIR/bin/osascript" "$TEST_DIR/bin/ditto" "$TEST_DIR/bin/mv"

install_app() { bash "$ROOT_DIR/install-wallpaper.sh" "$SOURCE_BUNDLE" > "$TEST_DIR/output" 2>&1; }
expect_failure() {
  if install_app; then
    echo "not ok - $1" >&2
    exit 1
  fi
  [[ "$(stat -f %i "$HOME/Applications/MatrixWallpaper.app")" == "$OLD_INODE" ]]
  codesign --verify --deep --strict "$HOME/Applications/MatrixWallpaper.app"
  echo "ok - $1 preserves the working installation"
}

install_app
[[ -f "$QUIT_LOG" ]]
codesign --verify --deep --strict "$HOME/Applications/MatrixWallpaper.app"
cmp "$SOURCE_BUNDLE/Contents/MacOS/MatrixWallpaper" "$HOME/Applications/MatrixWallpaper.app/Contents/MacOS/MatrixWallpaper"
echo "ok - installs a verified app into user Applications"
OLD_INODE="$(stat -f %i "$HOME/Applications/MatrixWallpaper.app")"
mkdir -p "$HOME/Library/Preferences"
printf 'unchanged preferences' > "$HOME/Library/Preferences/dev.patsch.MatrixScreenSaver.plist"
export FAIL_COPY=1
expect_failure "copy failure"
unset FAIL_COPY
export CORRUPT_COPY=1
expect_failure "signature verification failure"
unset CORRUPT_COPY
export FAIL_PROMOTION=1
expect_failure "promotion failure"
unset FAIL_PROMOTION
export SIMULATE_QUIT_FAILURE=1
expect_failure "app refusing to quit"
unset SIMULATE_QUIT_FAILURE
install_app
[[ "$(stat -f %i "$HOME/Applications/MatrixWallpaper.app")" != "$OLD_INODE" ]]
[[ "$(cat "$HOME/Library/Preferences/dev.patsch.MatrixScreenSaver.plist")" == 'unchanged preferences' ]]
[[ -z "$(find "$HOME/Applications" -maxdepth 1 -name '.MatrixWallpaper-install.*' -print)" ]]
echo "ok - reinstall replaces the old bundle and cleans staging"
