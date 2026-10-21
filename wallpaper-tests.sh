#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_DIR="$ROOT_DIR/Sources/MatrixScreenSaver"
WALLPAPER_DIR="$ROOT_DIR/Sources/MatrixWallpaper"
TEST_DIR="$ROOT_DIR/Tests/MatrixWallpaperTests"
TEST_BIN="$(mktemp "${TMPDIR:-/tmp}/matrix-wallpaper-tests.XXXXXX")"
trap 'rm -f "$TEST_BIN"' EXIT

swiftc -framework Foundation -framework AppKit -framework ScreenSaver -framework ServiceManagement \
  "$SOURCE_DIR/TerminalSupport.swift" \
  "$SOURCE_DIR/MatrixScreenSaverOptions.swift" \
  "$SOURCE_DIR/Xorshift64.swift" \
  "$SOURCE_DIR/NeoMessageScene.swift" \
  "$SOURCE_DIR/MatrixRendererLimits.swift" \
  "$SOURCE_DIR/NativeMatrixRenderer.swift" \
  "$SOURCE_DIR/ScreenSyncCoordinator.swift" \
  "$SOURCE_DIR/MatrixScreenSaverView.swift" \
  "$WALLPAPER_DIR/DesktopWindow.swift" \
  "$WALLPAPER_DIR/WallpaperPlaybackState.swift" \
  "$WALLPAPER_DIR/LoginItemController.swift" \
  "$WALLPAPER_DIR/WallpaperApp.swift" \
  "$TEST_DIR/SharedSaverTests.swift" \
  "$TEST_DIR/WallpaperAppTests.swift" \
  "$TEST_DIR/LoginItemTests.swift" \
  "$TEST_DIR/main.swift" \
  -o "$TEST_BIN"

"$TEST_BIN"
