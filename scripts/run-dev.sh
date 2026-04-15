#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_DIR="${PADIUM_INSTALL_DIR:-$HOME/Applications}"
INSTALL_APP="$INSTALL_DIR/Padium.app"

SIGN_HASH="${PADIUM_SIGN_HASH:-$({ security find-identity -v -p codesigning || true; } | /usr/bin/python3 -c '
import re, sys
candidates = []
for line in sys.stdin:
    match = re.search(r"\)\s+([0-9A-F]{40})\s+\"([^\"]+)\"", line)
    if match:
        candidates.append(match.groups())
for preferred in ("Apple Development", "Mac Development"):
    for identity_hash, identity_name in candidates:
        if preferred in identity_name:
            print(identity_hash)
            raise SystemExit(0)
raise SystemExit(1)
') } )}"

if [[ -z "$SIGN_HASH" ]]; then
	print -u2 "No Apple Development or Mac Development signing identity found."
	exit 1
fi

BUILD_PRODUCTS_DIR="$(xcodebuild -project "$ROOT_DIR/Padium.xcodeproj" -scheme Padium -showBuildSettings 2>/dev/null | /usr/bin/python3 -c '
import re, sys
text = sys.stdin.read()
match = re.search(r"BUILT_PRODUCTS_DIR = (.+)", text)
print(match.group(1).strip() if match else "")
')"

if [[ -z "$BUILD_PRODUCTS_DIR" ]]; then
	print -u2 "Unable to resolve BUILT_PRODUCTS_DIR from xcodebuild settings."
	exit 1
fi

xcodebuild -project "$ROOT_DIR/Padium.xcodeproj" -scheme Padium build CODE_SIGNING_ALLOWED=NO

BUILD_APP="$BUILD_PRODUCTS_DIR/Padium.app"
if [[ ! -d "$BUILD_APP" ]]; then
	print -u2 "Built app not found at $BUILD_APP"
	exit 1
fi

mkdir -p "$INSTALL_DIR"
/usr/bin/rsync -a --delete "$BUILD_APP/" "$INSTALL_APP/"
codesign --force --deep --sign "$SIGN_HASH" "$INSTALL_APP"
open "$INSTALL_APP"
