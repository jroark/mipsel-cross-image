#!/bin/bash
set -e

if [ -n "${BE300_LIBC:-}" ]; then export BE300_LIBC_EXPLICIT=1; fi
BE300_UI=tinyx exec ./build_be300_kernel.sh "$@"
