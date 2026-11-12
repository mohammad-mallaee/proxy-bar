#!/usr/bin/env bash
# Builds ProxyBar.app.
#   ./build.sh              build into ./build/ProxyBar.app
#   ./build.sh --install    also copy it to ~/Applications (quits a running copy first)
#   ./build.sh --run        install and open it
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="ProxyBar"
APP="build/$APP_NAME.app"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"

if [[ "${1:-}" == "--install" || "${1:-}" == "--run" ]]; then
  DEST="$HOME/Applications/$APP_NAME.app"
  if pgrep -x "$APP_NAME" >/dev/null; then
    osascript -e "quit app \"$APP_NAME\"" || true
    for _ in {1..20}; do pgrep -x "$APP_NAME" >/dev/null || break; sleep 0.25; done
  fi
  mkdir -p "$HOME/Applications"
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  echo "Installed $DEST"
  [[ "${1:-}" == "--run" ]] && open "$DEST"
fi
