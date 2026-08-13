#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
BUILD_DIR="$ROOT_DIR/.build/release"
APP_DIR="$ROOT_DIR/build/wd-ice-bar.app"

# Screen Recording is granted by macOS TCC to a signed app identity. An ad-hoc
# signature changes with every rebuilt binary, so use a stable local development
# certificate unless the caller explicitly specifies another one.
SIGNING_IDENTITY="${WD_ICE_BAR_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  # Use the certificate SHA-1, not its display name. Keychains can contain multiple valid
  # Apple Development certificates with the same name, which makes codesign reject a name.
  SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/^[[:space:]]*[0-9][0-9]*) \([0-9A-F]*\) "Apple Development:.*/\1/p' | head -n 1)"
fi

if [[ -z "$SIGNING_IDENTITY" ]]; then
  echo "No Apple Development signing identity found. Open the project in Xcode, sign in with an Apple ID, then build again."
  exit 1
fi

swift build --package-path "$ROOT_DIR" -c release
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$BUILD_DIR/wd-ice-bar" "$APP_DIR/Contents/MacOS/wd-ice-bar"
cp "$ROOT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
codesign --force --timestamp=none --sign "$SIGNING_IDENTITY" "$APP_DIR"

echo "Built $APP_DIR"
echo "Signed with $SIGNING_IDENTITY"
