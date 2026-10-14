#!/bin/zsh
set -euo pipefail
ROOT_DIR="${0:A:h:h}"
PROBE_DIR="$(mktemp -d /tmp/wd-ice-bar-integration.XXXXXX)"
trap 'rm -rf "$PROBE_DIR"' EXIT
cp "$ROOT_DIR/scripts/overflow-click-integration.swift" "$PROBE_DIR/main.swift"
SOURCES=("$ROOT_DIR"/Sources/WDIceBar/*.swift)
SOURCES=("${(@)SOURCES:#*/main.swift}")
swiftc -swift-version 6 -D MENU_BAR_INTEGRATION -target "$(uname -m)-apple-macosx14.0" \
  "${SOURCES[@]}" \
  "$PROBE_DIR/main.swift" -o "$PROBE_DIR/probe"
"$PROBE_DIR/probe" "$@"
