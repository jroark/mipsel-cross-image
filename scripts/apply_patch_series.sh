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

# Collect ordered patch list (strip comments + blanks).
mapfile -t SERIES < <(sed -e 's/#.*//' -e 's/^[[:space:]]*//;s/[[:space:]]*$//' "$SERIES_FILE" | grep -v '^$')

# Find the topmost-already-applied patch by walking the series from the
# end. The naive per-patch reverse-check is fooled when a later patch
# also touches files modified by an earlier one — a clean reverse of the
# earlier patch then fails even though it is conceptually applied,
# because the later patch sits on top of those same hunks. Walking in
# reverse order, the first patch whose reverse-check passes is the
# topmost-applied patch; everything before it in the series is applied
# too, and everything after it needs forward-application.
TOPMOST_APPLIED_IDX=-1
for ((i=${#SERIES[@]}-1; i>=0; i--)); do
	patch_path="$SERIES_DIR/${SERIES[i]}"
	if [ ! -f "$patch_path" ]; then
		echo "ERROR: listed patch not found: $patch_path" >&2
		exit 1
	fi
	if git_apply --reverse --check "$patch_path" >/dev/null 2>&1; then
		TOPMOST_APPLIED_IDX=$i
		break
	fi
done

for ((i=0; i<${#SERIES[@]}; i++)); do
	patch_name=${SERIES[i]}
	patch_path="$SERIES_DIR/$patch_name"
	if [ $i -le $TOPMOST_APPLIED_IDX ]; then
		echo "--- Patch already applied: $patch_name"
		continue
	fi
	echo "--- Applying patch: $patch_name"
	git_apply --check "$patch_path"
	git_apply "$patch_path"
done
