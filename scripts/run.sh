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

# Sign with a stable identity when one exists. Ad-hoc signing (`-`) mints a new
# code identity on every build, so macOS treats each rebuild as a different app
# and re-asks for Keychain approval every single time. See scripts/setup-signing.sh.
IDENTITY="-"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Jarvis Local Dev"; then
  IDENTITY="Jarvis Local Dev"
else
  echo "note: no stable signing identity — expect a Keychain prompt on each rebuild"
  echo "      run scripts/setup-signing.sh once to fix that"
fi

# Manual signing: a named identity can't be used with automatic signing, which
# insists on a development team.
STYLE=Manual
[ "$IDENTITY" = "-" ] && STYLE=Automatic

xcodegen generate
BUILD_LOG=$(mktemp)
xcodebuild \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Debug \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  CODE_SIGN_STYLE="$STYLE" \
  DEVELOPMENT_TEAM="" \
  build > "$BUILD_LOG" 2>&1 || true

grep -E "error:" "$BUILD_LOG" | head -10 || true

# Check the build actually succeeded — otherwise a stale bundle from a previous
# run gets installed and you debug code that isn't the code you just wrote.
if ! grep -q "BUILD SUCCEEDED" "$BUILD_LOG"; then
  echo "BUILD FAILED (full log: $BUILD_LOG)"
  exit 1
fi
rm -f "$BUILD_LOG"
echo "BUILD SUCCEEDED"

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
