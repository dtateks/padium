#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_DIR="${PADIUM_INSTALL_DIR:-/Applications}"
INSTALL_APP="$INSTALL_DIR/Padium.app"

if [[ -n "${PADIUM_SIGN_HASH:-}" ]]; then
	SIGN_HASH="$PADIUM_SIGN_HASH"
else
	SIGN_HASH="$(security find-identity -v -p codesigning 2>/dev/null | /usr/bin/python3 -c '
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
' || true)"
fi

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

# Quit running Padium gracefully so UserDefaults (including keyboard shortcuts) are flushed.
# AppleScript quit triggers NSApplication.terminate which syncs defaults before exit.
# Falls back to killall if AppleScript fails (e.g., app is hung).
if pgrep -x Padium >/dev/null 2>&1; then
	osascript -e 'tell application "Padium" to quit' 2>/dev/null || killall Padium 2>/dev/null || true
	for _ in {1..50}; do
		pgrep -x Padium >/dev/null 2>&1 || break
		sleep 0.1
	done
fi

mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_APP"
mv "$BUILD_APP" "$INSTALL_APP"
codesign --force --deep --sign "$SIGN_HASH" "$INSTALL_APP"
/usr/bin/touch "$INSTALL_APP"
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -f -R -trusted "$INSTALL_APP"
open "$INSTALL_APP"
