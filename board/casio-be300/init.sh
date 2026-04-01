#!/bin/sh
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null

hostname be300

echo
echo "=== Casio BE-300 Linux 4.2.9 ==="
echo

exec /bin/sh
