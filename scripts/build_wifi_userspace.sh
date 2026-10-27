#!/bin/bash
# Build the PSK-only WEXT client with the same MIPS2 libc as the rootfs.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
WORK=${BE300_WPA_BUILD_DIR:-$REPO/build-wifi}
CC=${BE300_WPA_CC:?Set BE300_WPA_CC to the MIPS2 userspace compiler, including libc specs if needed}
HEADERS=${BE300_WPA_KERNEL_HEADERS:?Set BE300_WPA_KERNEL_HEADERS to an installed Linux UAPI headers prefix}
ARCHIVE=${BE300_WPA_ARCHIVE:-$WORK/wpa_2.11.orig.tar.xz}
SHA=4bc22d37533b53f0e9dfc4788cd7798457908dfb57e08ab5894a721061e66247
URL=https://deb.debian.org/debian/pool/main/w/wpa/wpa_2.11.orig.tar.xz
mkdir -p "$WORK"
if [[ ! -f "$ARCHIVE" ]]; then
    curl --fail --location --retry 2 "$URL" -o "$ARCHIVE.part"
    mv "$ARCHIVE.part" "$ARCHIVE"
fi
printf '%s  %s\n' "$SHA" "$ARCHIVE" | sha256sum -c -
if [[ ! -f "$WORK/wpa-2.11/wpa_supplicant/Makefile" ]]; then
    tar -xJf "$ARCHIVE" -C "$WORK"
fi
cp "$REPO/configs/be300_wpa_supplicant.config" "$WORK/wpa-2.11/wpa_supplicant/.config"
make -C "$WORK/wpa-2.11/wpa_supplicant" clean
CC="$CC" CFLAGS="-Os -march=mips2 -mfpxx -I$HEADERS/include ${BE300_WPA_CFLAGS:-}" \
    LDFLAGS="-static ${BE300_WPA_LDFLAGS:-}" \
    make -C "$WORK/wpa-2.11/wpa_supplicant" -j"${JOBS:-4}" wpa_supplicant wpa_cli
mkdir -p "$WORK/output"
for binary in wpa_supplicant wpa_cli; do
    cp "$WORK/wpa-2.11/wpa_supplicant/$binary" "$WORK/output/$binary"
    bad=$(mipsel-linux-gnu-objdump -d "$WORK/output/$binary" | \
        awk '$3 ~ /^(mul|clz|clo|ext|ins|movf|movn|movt|movz|pref|seb|seh|wsbh|rdhwr|ld|sd|daddu|daddiu|dsll|dsll32|dsrl|dsrl32|dsra|dsra32)$/ {if (!seen++) print}')
    if [[ -n "$bad" ]]; then
        printf 'ERROR: %s contains unsupported MIPS instructions:\n%s\n' "$binary" "$bad" >&2
        exit 1
    fi
    mipsel-linux-gnu-strip --strip-all "$WORK/output/$binary"
done
cp "$WORK/wpa-2.11/COPYING" "$WORK/output/COPYING"
cp "$WORK/wpa-2.11/README" "$WORK/output/README"
printf 'wpa_supplicant 2.11\nSource: %s\nSHA256: %s\n' "$URL" "$SHA" > "$WORK/output/SOURCE"
# Retain notices for the included upstream implementation sources.
python3 - "$WORK/wpa-2.11" "$WORK/output/SOURCE_NOTICES" <<'PY'
from pathlib import Path
import sys
source, dest = map(Path, sys.argv[1:])
notices = []
for path in sorted(source.rglob('*')):
    if path.suffix not in ('.c', '.h') or not path.is_file():
        continue
    text = path.read_text(errors='replace').lstrip()
    if text.startswith('/*'):
        end = text.find('*/')
        if end >= 0:
            notices.append(str(path.relative_to(source)) + '\n' + text[:end + 2])
dest.write_text('\n\n'.join(notices) + '\n')
PY
printf 'Built Wi-Fi userspace: %s/output\n' "$WORK"
