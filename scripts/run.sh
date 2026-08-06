#!/bin/bash
# Build the real .app, install it, and launch it.
#
# The app bundle is required: an unbundled `swift run` binary isn't registered
# with LaunchServices, so no menu bar icon appears. Installing to /Applications
# also keeps the code-signature path stable, which is what TCC permission grants
# are tied to — otherwise you re-grant mic/speech access on every rebuild.
#
# Any arguments are forwarded to the app, e.g.
#   ./scripts/run.sh --demo-turn
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME=Jarvis
DERIVED=.build/dd
INSTALLED="/Applications/$APP_NAME.app"

command -v xcodegen >/dev/null || { echo "xcodegen missing: brew install xcodegen"; exit 1; }

xcodegen generate
xcodebuild \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Debug \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="-" \
  build \
  | grep -E "error:|warning: .*(unused|deprecated)|BUILD SUCCEEDED|BUILD FAILED" || true

BUILT="$DERIVED/Build/Products/Debug/$APP_NAME.app"
[ -d "$BUILT" ] || { echo "build produced no app bundle"; exit 1; }

pkill -x "$APP_NAME" 2>/dev/null || true
sleep 1
rm -rf "$INSTALLED"
cp -R "$BUILT" /Applications/

if [ $# -gt 0 ]; then
  open -a "$INSTALLED" --args "$@"
else
  open -a "$INSTALLED"
fi

sleep 2
if pgrep -x "$APP_NAME" >/dev/null; then
  echo "$APP_NAME running (pid $(pgrep -x "$APP_NAME")) - look for the waveform icon in the menu bar"
else
  echo "$APP_NAME failed to stay running"
  exit 1
fi
