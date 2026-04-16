#!/usr/bin/env bash
# Build a release Padium.app universal bundle (arm64 + x86_64) and zip it.
#
# Inputs:
#   $1 (required) — output zip path.
#
# Outputs:
#   <output-zip>                              — ditto archive containing Padium.app
#   build/Build/Products/Release/Padium.app   — built bundle
#
# Signing:
#   Ad-hoc signed (CODE_SIGN_IDENTITY="-"). Required for the binary to launch
#   on Apple Silicon. Does NOT provide stable code identity across builds, so
#   Accessibility permission may need to be re-granted after each update.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_PATH="$BUILD_DIR/Build/Products/Release/Padium.app"

if [[ $# -ne 1 ]]; then
	echo "Usage: $0 <output-zip-path>" >&2
	exit 1
fi

OUTPUT_ZIP="$1"
mkdir -p "$(dirname "$OUTPUT_ZIP")"

if [[ "$(uname -s)" != "Darwin" ]]; then
	echo "build-release.sh must run on macOS (uses xcodebuild)" >&2
	exit 1
fi

cd "$ROOT_DIR"

# Force universal Mach-O output regardless of scheme defaults.
xcodebuild \
	-project Padium.xcodeproj \
	-scheme Padium \
	-configuration Release \
	-derivedDataPath "$BUILD_DIR" \
	-destination 'generic/platform=macOS' \
	ARCHS="arm64 x86_64" \
	ONLY_ACTIVE_ARCH=NO \
	CODE_SIGN_IDENTITY="-" \
	CODE_SIGN_STYLE=Manual \
	DEVELOPMENT_TEAM="" \
	CODE_SIGNING_REQUIRED=YES \
	CODE_SIGNING_ALLOWED=YES \
	build

if [[ ! -d "$APP_PATH" ]]; then
	echo "Built app not found at $APP_PATH" >&2
	exit 1
fi

EXEC_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_PATH/Contents/Info.plist")"
EXEC_PATH="$APP_PATH/Contents/MacOS/$EXEC_NAME"

# Verify the produced binary is actually universal. Catches toolchain regressions
# or scheme overrides that silently drop a slice.
ARCHS_OUT="$(lipo -archs "$EXEC_PATH")"
echo "Binary architectures: $ARCHS_OUT"
if ! grep -qw arm64 <<<"$ARCHS_OUT"; then
	echo "Universal verification failed: arm64 slice missing" >&2
	exit 1
fi
if ! grep -qw x86_64 <<<"$ARCHS_OUT"; then
	echo "Universal verification failed: x86_64 slice missing" >&2
	exit 1
fi

rm -f "$OUTPUT_ZIP"
ditto -c -k --keepParent --sequesterRsrc "$APP_PATH" "$OUTPUT_ZIP"

echo "Built: $APP_PATH"
echo "Zipped: $OUTPUT_ZIP"
