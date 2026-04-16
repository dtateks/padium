#!/usr/bin/env bash
# Build a release Padium.app bundle and zip it for distribution.
#
# Inputs:
#   $1 (optional) — output zip path. Defaults to ./Padium-darwin-<arch>.zip in the repo root.
#
# Outputs:
#   <output-zip>      — ditto archive containing Padium.app
#   build/Build/Products/Release/Padium.app — built bundle
#
# Signing:
#   Ad-hoc signed (CODE_SIGN_IDENTITY="-"). Required for the binary to launch
#   on Apple Silicon. Does NOT provide stable code identity across builds, so
#   Accessibility permission may need to be re-granted after each update.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_PATH="$BUILD_DIR/Build/Products/Release/Padium.app"

case "$(uname -m)" in
arm64 | aarch64) ARCH="arm64" ;;
x86_64) ARCH="x64" ;;
*)
	echo "Unsupported build architecture: $(uname -m)" >&2
	exit 1
	;;
esac

OUTPUT_ZIP="${1:-$ROOT_DIR/Padium-darwin-${ARCH}.zip}"

cd "$ROOT_DIR"

xcodebuild \
	-project Padium.xcodeproj \
	-scheme Padium \
	-configuration Release \
	-derivedDataPath "$BUILD_DIR" \
	-destination 'generic/platform=macOS' \
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

rm -f "$OUTPUT_ZIP"
ditto -c -k --keepParent --sequesterRsrc "$APP_PATH" "$OUTPUT_ZIP"

echo "Built: $APP_PATH"
echo "Zipped: $OUTPUT_ZIP"
