#!/usr/bin/env bash
# Install version-controlled git hooks from .githooks/ into .git/hooks/.
# Re-run safely to refresh hooks after pulls that change them.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="$ROOT_DIR/.githooks"
TARGET_DIR="$ROOT_DIR/.git/hooks"

if [[ ! -d "$TARGET_DIR" ]]; then
	echo "No .git/hooks directory found; run inside a git checkout." >&2
	exit 1
fi

for hook_path in "$SOURCE_DIR"/*; do
	[[ -f "$hook_path" ]] || continue
	hook_name="$(basename "$hook_path")"
	install -m 0755 "$hook_path" "$TARGET_DIR/$hook_name"
	echo "Installed hook: $hook_name"
done
