#!/usr/bin/env bash
# Activate version-controlled git hooks by pointing core.hooksPath at .githooks/.
# Re-run safely after clone or if local git config is reset.

set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel)"
HOOKS_DIR="$ROOT_DIR/.githooks"

if [[ ! -d "$HOOKS_DIR" ]]; then
	echo "No .githooks directory found at $HOOKS_DIR" >&2
	exit 1
fi

for hook_path in "$HOOKS_DIR"/*; do
	[[ -f "$hook_path" ]] || continue
	chmod 0755 "$hook_path"
done

git -C "$ROOT_DIR" config --local core.hooksPath .githooks

echo "Configured git core.hooksPath=$(git -C "$ROOT_DIR" config --local --get core.hooksPath)"
echo "Git will now run hooks directly from $HOOKS_DIR"
