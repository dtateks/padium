#!/bin/bash
set -euo pipefail

APP_NAME="Padium.app"
APP_BUNDLE_ID="com.padium"
RELEASE_DOWNLOAD_BASE_URL="${PADIUM_DOWNLOAD_BASE_URL:-https://github.com/dtateks/padium/releases/latest/download}"
RELEASE_ZIP="Padium-macos.zip"
INSTALL_DIR="/Applications"
APP_EXECUTABLE_RELATIVE_PATH="Contents/MacOS/Padium"
TEMP_DIR=""

cleanup() {
	if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
		rm -rf "$TEMP_DIR"
	fi
}

trap cleanup EXIT

require_macos() {
	if [ "$(uname -s)" != "Darwin" ]; then
		echo "This installer runs on macOS only." >&2
		exit 1
	fi
}

resolve_zip_url() {
	if [ -n "${PADIUM_ZIP_URL:-}" ]; then
		printf '%s' "$PADIUM_ZIP_URL"
		return 0
	fi
	printf '%s' "$RELEASE_DOWNLOAD_BASE_URL/$RELEASE_ZIP"
}

find_app_bundle() {
	local search_root="$1"
	local app_path
	app_path=$(find "$search_root" -maxdepth 4 -name "$APP_NAME" -type d | while IFS= read -r path; do
		printf '%s\n' "$path"
		break
	done)
	if [ -z "$app_path" ]; then
		echo "Could not find $APP_NAME in extracted archive" >&2
		exit 1
	fi
	printf '%s' "$app_path"
}

verify_bundle_id() {
	local bundle_path="$1"
	local info_plist="$bundle_path/Contents/Info.plist"
	local actual_bundle_id
	actual_bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist" 2>/dev/null || true)
	if [ "$actual_bundle_id" != "$APP_BUNDLE_ID" ]; then
		echo "Unexpected bundle id: ${actual_bundle_id:-<missing>}" >&2
		exit 1
	fi
}

ensure_install_dir_writable() {
	if [ -w "$INSTALL_DIR" ]; then
		return 0
	fi

	cat >&2 <<EOF
$INSTALL_DIR is not writable by the current user.
Re-run with: sudo bash install.sh
EOF
	exit 1
}

terminate_running_app() {
	local installed_app_path="$1"
	local executable_path="${installed_app_path}/${APP_EXECUTABLE_RELATIVE_PATH}"

	if ! pgrep -f "$executable_path" >/dev/null 2>&1; then
		return 0
	fi

	osascript -e "tell application id \"$APP_BUNDLE_ID\" to quit" >/dev/null 2>&1 || true

	local waited=0
	while pgrep -f "$executable_path" >/dev/null 2>&1; do
		if [ "$waited" -ge 50 ]; then
			pkill -TERM -f "$executable_path" >/dev/null 2>&1 || true
			sleep 1
			break
		fi
		sleep 0.1
		waited=$((waited + 1))
	done
}

install_bundle() {
	local source_bundle="$1"
	local installed_app_path="$INSTALL_DIR/$APP_NAME"

	terminate_running_app "$installed_app_path"
	rm -rf "$installed_app_path"
	ditto "$source_bundle" "$installed_app_path"
	xattr -cr "$installed_app_path" || true
	open "$installed_app_path"
}

main() {
	if [ "$#" -ne 0 ]; then
		echo "This installer does not accept positional arguments" >&2
		exit 1
	fi

	require_macos

	local zip_url zip_path unpack_dir app_bundle

	TEMP_DIR=$(mktemp -d "/tmp/padium-install.XXXXXX")
	zip_url=$(resolve_zip_url)
	zip_path="$TEMP_DIR/padium.zip"
	unpack_dir="$TEMP_DIR/unpacked"

	echo "Downloading $APP_NAME..."
	curl -fL --progress-bar "$zip_url" -o "$zip_path"

	mkdir -p "$unpack_dir"
	ditto -x -k "$zip_path" "$unpack_dir"

	app_bundle=$(find_app_bundle "$unpack_dir")
	verify_bundle_id "$app_bundle"

	ensure_install_dir_writable
	install_bundle "$app_bundle"

	cat <<EOF
Installed: $INSTALL_DIR/$APP_NAME

Padium needs Accessibility permission to post keyboard shortcuts.
On first launch macOS will prompt; grant access in
  System Settings > Privacy & Security > Accessibility
then relaunch Padium from /Applications.

Note: release builds are ad-hoc signed, so macOS may ask you to
re-grant Accessibility after each update.
EOF
}

main "$@"
