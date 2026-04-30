#!/bin/bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
	echo "usage: $0 <series-file> <target-tree>" >&2
	exit 2
fi

SERIES_FILE=$1
TARGET_TREE=$2

if [ ! -f "$SERIES_FILE" ]; then
	echo "ERROR: patch series not found: $SERIES_FILE" >&2
	exit 1
fi
if [ ! -d "$TARGET_TREE" ]; then
	echo "ERROR: target tree not found: $TARGET_TREE" >&2
	exit 1
fi

SERIES_DIR=$(cd "$(dirname "$SERIES_FILE")" && pwd)
TARGET_PARENT=$(cd "$TARGET_TREE/.." && pwd)

git_apply() {
	(
		cd "$TARGET_TREE"
		GIT_CEILING_DIRECTORIES="$TARGET_PARENT" git apply "$@"
	)
}

while IFS= read -r patch_name || [ -n "$patch_name" ]; do
	patch_name=${patch_name%%#*}
	patch_name=$(printf '%s' "$patch_name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
	[ -n "$patch_name" ] || continue

	patch_path="$SERIES_DIR/$patch_name"
	if [ ! -f "$patch_path" ]; then
		echo "ERROR: listed patch not found: $patch_path" >&2
		exit 1
	fi

	if git_apply --reverse --check "$patch_path" >/dev/null 2>&1; then
		echo "--- Patch already applied: $patch_name"
		continue
	fi

	echo "--- Applying patch: $patch_name"
	git_apply --check "$patch_path"
	git_apply "$patch_path"
done < "$SERIES_FILE"
