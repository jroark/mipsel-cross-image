#!/bin/bash
set -e

KERNEL_SOURCE_URL="http://distro.ibiblio.org/tinycorelinux/7.x/x86/release/src/kernel/linux-4.2.9-patched.tar.xz"
BUSYBOX_VERSION="1.24.2"
KERNEL_PATCH_SERIES="/work/patches/linux-4.2.9/be300/series"
KERNEL_DEFCONFIG="/work/configs/be300_defconfig"
BE300_UI="${BE300_UI:-microwindows}"
BE300_LIBC="${BE300_LIBC:-musl}"
KERNEL_CONFIG_FRAGMENTS=""
OPIE_CONFIG="/work/board/opie/opie-be300.config"
OPIE_BUILD_STAMP=".be300-opie-built-v100"
OPIE_PROFILE="base"
OPIE_EXTRA_DEFS=""

case "$BE300_LIBC" in
    musl|uclibc)
        ;;
    *)
        echo "ERROR: BE300_LIBC must be 'musl' or 'uclibc' (got '$BE300_LIBC')" >&2
        exit 1
        ;;
esac

case "$BE300_UI" in
    microwindows)
        ROOTFS="/work/rootfs_be300"
        ROOTFS_JFFS2_NAME="rootfs.jffs2"
        NAND_IMAGE_NAME="be300.nand"
        ;;
    opie)
        ROOTFS="/work/rootfs_be300_opie"
        ROOTFS_JFFS2_NAME="rootfs-opie.jffs2"
        NAND_IMAGE_NAME="be300-opie.nand"
        ;;
    opie64)
        ROOTFS="/work/rootfs_be300_opie64"
        ROOTFS_JFFS2_NAME="rootfs-opie64.jffs2"
        NAND_IMAGE_NAME="be300-opie64.nand"
        KERNEL_CONFIG_FRAGMENTS="/work/configs/be300_64m.config"
        OPIE_CONFIG="/work/board/opie/opie-be300-64m.config"
        OPIE_BUILD_STAMP=".be300-opie64-built-v6"
        OPIE_PROFILE="opie64"
        OPIE_EXTRA_DEFS="-DBE300_ENABLE_TASKBAR_PLUGINS"
        ;;
    picogui)
        ROOTFS="/work/rootfs_be300_picogui"
        ROOTFS_JFFS2_NAME="rootfs-picogui.jffs2"
        NAND_IMAGE_NAME="be300-picogui.nand"
        ;;
    tinyx)
        ROOTFS="/work/rootfs_be300_tinyx"
        ROOTFS_JFFS2_NAME="rootfs-tinyx.jffs2"
        NAND_IMAGE_NAME="be300-tinyx.nand"
        KERNEL_CONFIG_FRAGMENTS="/work/configs/be300_tinyx.config"
        ;;
    *)
        echo "ERROR: BE300_UI must be 'microwindows', 'opie', 'opie64', 'picogui', or 'tinyx' (got '$BE300_UI')" >&2
        exit 1
        ;;
esac

# The picogui and tinyx profiles default to uClibc-ng dynamic linking (see
# board/picogui/README.md and board/tinyx/README.md). The wrapper sets
# BE300_LIBC_EXPLICIT=1 only when the user pinned a libc on the command
# line; absent that we flip the default to uclibc here.
if { [ "$BE300_UI" = "picogui" ] || [ "$BE300_UI" = "tinyx" ]; } \
        && [ -z "${BE300_LIBC_EXPLICIT:-}" ]; then
    BE300_LIBC="uclibc"
fi

if [ "$BE300_LIBC" = "uclibc" ] && [ "$BE300_UI" = "opie64" ]; then
    echo "ERROR: BE300_LIBC=uclibc is currently supported only with BE300_UI=microwindows, opie, picogui, or tinyx" >&2
    exit 1
fi

###############################################################################
# Phase 0a: Rebuild musl with -march=mips2 (no SPECIAL2 mul instruction)
###############################################################################
# VR4131 is MIPS III, which predates MIPS32. It does NOT implement the
# SPECIAL2 opcode space (where MIPS32 `mul rd, rs, rt` lives). The stock
# musl-mipsel built with -march=mips32 uses `mul` throughout, which raises
# a Reserved Instruction exception on VR4131 (both emulator and real HW).
# Rebuild with -march=mips2 which uses only mult/mflo.

MUSL_MIPS2="/work/musl-mipsel"
MUSL_SRC="/work/musl-1.2.5"
MUSL_SPECS="${MUSL_MIPS2}/lib/musl-gcc.specs"
UCLIBC_NG_VERSION="1.0.51"
UCLIBC_SRC="/work/uClibc-ng-${UCLIBC_NG_VERSION}"
UCLIBC_ARCHIVE="/work/uClibc-ng-${UCLIBC_NG_VERSION}.tar.xz"
UCLIBC_URL="https://downloads.uclibc-ng.org/releases/${UCLIBC_NG_VERSION}/uClibc-ng-${UCLIBC_NG_VERSION}.tar.xz"
UCLIBC_SYSROOT="/work/uclibc-sysroot"
UCLIBC_KHDRS="/work/uclibc-kernel-headers"
UCLIBC_CC="/work/mipsel-uclibc-gcc"
UCLIBC_CXX="/work/mipsel-uclibc-g++"
LIBGCC_HELPER_FLOAT_CFLAGS="-mfpxx"
if [ "$BE300_LIBC" = "uclibc" ]; then
    LIBGCC_HELPER_FLOAT_CFLAGS="-msoft-float"
fi

prepare_be300_libgcc() {
    # Patched libgcc.a: the stock libgcc (from the mips32r2 cross toolchain)
    # uses MIPS32-only instructions in several helper routines.  VR4131 is
    # MIPS III and raises Reserved Instruction on those opcodes.  Create a
    # private libgcc archive that strips the offending objects and adds
    # MIPS2-compiled replacements.
    mkdir -p /tmp/libgcc_patched
    LIBGCC_ORIG=$(mipsel-linux-gnu-gcc -print-libgcc-file-name)
    cp "$LIBGCC_ORIG" /tmp/libgcc_patched/libgcc.a
    mipsel-linux-gnu-ar d /tmp/libgcc_patched/libgcc.a \
        _mulsc3.o _muldc3.o \
        eqsf2.o nesf2.o gesf2.o gtsf2.o lesf2.o ltsf2.o unordsf2.o \
        eqdf2.o nedf2.o gedf2.o gtdf2.o ledf2.o ltdf2.o unorddf2.o \
        _divdi3.o _moddi3.o _udivdi3.o _umoddi3.o \
        _fixdfdi.o _fixunsdfdi.o _floatdidf.o _floatundidf.o \
        _lshrdi3.o _ashldi3.o _ashrdi3.o _negdi2.o \
        _clz.o _clzsi2.o _clzdi2.o _ctzsi2.o _ctzdi2.o \
        _popcount_tab.o _popcountsi2.o _popcountdi2.o _paritysi2.o _paritydi2.o \
        _ffssi2.o _ffsdi2.o \
        _bswapsi2.o _bswapdi2.o \
        2>/dev/null || true
    mipsel-linux-gnu-gcc -march=mips2 $LIBGCC_HELPER_FLOAT_CFLAGS -O2 -fPIC -ffreestanding -fno-builtin \
        -c -o /tmp/libgcc_helpers.o /work/board/casio-be300/libgcc_helpers.c
    mipsel-linux-gnu-ar rcs /tmp/libgcc_patched/libgcc.a /tmp/libgcc_helpers.o
    mipsel-linux-gnu-ar rcs /tmp/libgcc_patched/libbe300gcc.a /tmp/libgcc_helpers.o
}

unsupported_mips2_insn() {
    mipsel-linux-gnu-objdump -d "$1" 2>/dev/null \
        | awk '$3 ~ /^(mul|clz|clo|ext|ins|movf|movn|movt|movz|pref|seb|seh|wsbh|rdhwr)$/ {print; exit}' || true
}

check_mips2_file() {
	local file="$1"
	local bad=""

    if [ ! -e "$file" ]; then
        echo "missing $file"
        return
    fi
    bad=$(unsupported_mips2_insn "$file")
    if [ -n "$bad" ]; then
        echo "$file: $bad"
	fi
}

check_rootfs_mips2() {
	local file
	local bad

	while IFS= read -r file; do
		bad="$(check_mips2_file "$file")"
		if [ -n "$bad" ]; then
			echo "$bad"
		fi
	done < <(find "$ROOTFS" -type f \( -perm /111 -o -name '*.so' -o -name '*.so.*' \) | sort)
}

be300_strip_binary() {
	for file in "$@"; do
		[ -e "$file" ] || continue
        mipsel-linux-gnu-strip --strip-all \
            --remove-section=.comment \
            --remove-section=.note \
            "$file" 2>/dev/null || mipsel-linux-gnu-strip --strip-all "$file"
    done
}

prepare_be300_libgcc

if [ "$BE300_LIBC" = "musl" ]; then
MUSL_BAD_INSN=""
MUSL_BAD_INSN="$(
    check_mips2_file "$MUSL_MIPS2/lib/libc.a"
    check_mips2_file "$MUSL_MIPS2/lib/libc.so"
)"

if [ -z "$MUSL_BAD_INSN" ] \
        && [ -f "$MUSL_SRC/arch/mips/pthread_arch.h" ] \
        && grep -q "__be300_mips_tp" "$MUSL_SRC/arch/mips/pthread_arch.h"; then
    echo "--- musl-mipsel already MIPS2-compatible, skipping rebuild ---"
else
    if [ -n "$MUSL_BAD_INSN" ]; then
        echo "--- musl-mipsel needs rebuild: $MUSL_BAD_INSN ---"
    fi
    echo "=== Phase 0a: Rebuilding musl-mipsel with -march=mips2 ==="
    if [ ! -d "$MUSL_SRC" ]; then
        cd /work
        tar xf musl-1.2.5.tar.gz
    fi
    cp /work/board/casio-be300/musl_mips_pthread_arch.h \
        "$MUSL_SRC/arch/mips/pthread_arch.h"
    cp /work/board/casio-be300/musl_mips_set_thread_area.c \
        "$MUSL_SRC/src/thread/__set_thread_area.c"
    cd "$MUSL_SRC"
    make distclean 2>/dev/null || true
    # Explicitly set cross tools so musl doesn't try mipsel-linux-musl-*
    CROSS=mipsel-linux-gnu-
    CC="${CROSS}gcc -march=mips2 -mfpxx -B/tmp/libgcc_patched -L/tmp/libgcc_patched" \
    LIBCC="/tmp/libgcc_patched/libgcc.a" \
    AR="${CROSS}ar" \
    RANLIB="${CROSS}ranlib" \
    LD="${CROSS}ld" \
        ./configure --target=mipsel-linux-gnu \
            --prefix="$MUSL_MIPS2" 2>&1 | tail -5
    make CC="${CROSS}gcc -march=mips2 -mfpxx -B/tmp/libgcc_patched -L/tmp/libgcc_patched" \
         LIBCC="/tmp/libgcc_patched/libgcc.a" \
         AR="${CROSS}ar" \
         RANLIB="${CROSS}ranlib" \
         -j$(nproc) 2>&1 | tail -5
    make install 2>&1 | tail -5
    cd /work
fi
if [ -e "$MUSL_MIPS2/lib/libc.so" ] && [ ! -e "$MUSL_MIPS2/lib/ld-musl-mipsel.so.1" ]; then
    ln -sf libc.so "$MUSL_MIPS2/lib/ld-musl-mipsel.so.1"
fi
MUSL_BAD_INSN="$(
    check_mips2_file "$MUSL_MIPS2/lib/libc.a"
    check_mips2_file "$MUSL_MIPS2/lib/libc.so"
)"
if [ -n "$MUSL_BAD_INSN" ]; then
    echo "ERROR: musl-mipsel still contains unsupported VR4131 instructions:" >&2
    echo "$MUSL_BAD_INSN" >&2
    exit 1
fi
else
    echo "--- BE300_LIBC=uclibc: skipping musl rebuild/check ---"
fi

###############################################################################
# Phase 0: Prepare sanitized Linux UAPI headers for target libc/userspace
###############################################################################

KHDRS="/work/musl-khdrs"
if [ ! -d "$KHDRS/include/linux" ]; then
    echo "=== Phase 0: Installing sanitized kernel headers for target libc ==="
    # Use a separate untar to avoid touching the kernel build tree we will
    # configure later (the kernel tree gets blown away in Phase 2).
    if [ ! -f /work/linux-4.2.9-patched.tar.xz ]; then
        (cd /work && wget "$KERNEL_SOURCE_URL")
    fi
    mkdir -p /tmp/khdrs_src
    rm -rf /tmp/khdrs_src/linux-4.2.9
    tar xf /work/linux-4.2.9-patched.tar.xz -C /tmp/khdrs_src
    /work/scripts/apply_patch_series.sh "$KERNEL_PATCH_SERIES" \
        /tmp/khdrs_src/linux-4.2.9
    rm -rf "$KHDRS"
    mkdir -p "$KHDRS"
    make -C /tmp/khdrs_src/linux-4.2.9 \
        ARCH=mips CROSS_COMPILE=mipsel-linux-gnu- \
        INSTALL_HDR_PATH="$KHDRS" headers_install 2>&1 | tail -5
fi

prepare_uclibc_headers() {
    if [ ! -d "$UCLIBC_KHDRS/include/linux" ]; then
        echo "=== Preparing uClibc-ng kernel headers ==="
        rm -rf "$UCLIBC_KHDRS"
        mkdir -p "$UCLIBC_KHDRS"
        cp -a "$KHDRS/include" "$UCLIBC_KHDRS/"
    fi
}

enable_uclibc_config() {
    cfg="$1"
    if grep -q "^# ${cfg} is not set" .config; then
        sed -i "s/^# ${cfg} is not set/${cfg}=y/" .config
    elif grep -q "^${cfg}=n" .config; then
        sed -i "s/^${cfg}=n/${cfg}=y/" .config
    elif ! grep -q "^${cfg}=" .config; then
        echo "${cfg}=y" >> .config
    fi
}

disable_uclibc_config() {
    cfg="$1"
    if grep -q "^${cfg}=" .config; then
        sed -i "s/^${cfg}=.*/# ${cfg} is not set/" .config
    elif ! grep -q "^# ${cfg} is not set" .config; then
        echo "# ${cfg} is not set" >> .config
    fi
}

set_uclibc_string_config() {
    cfg="$1"
    val="$2"
    if grep -q "^${cfg}=" .config; then
        sed -i "s@^${cfg}=.*@${cfg}=\"${val}\"@" .config
    elif grep -q "^# ${cfg} is not set" .config; then
        sed -i "s@^# ${cfg} is not set@${cfg}=\"${val}\"@" .config
    else
        echo "${cfg}=\"${val}\"" >> .config
    fi
}

check_uclibc_mips2() {
    local file
    local bad=""

    while IFS= read -r file; do
        bad="$(check_mips2_file "$file")"
        if [ -n "$bad" ]; then
            echo "$bad"
        fi
    done < <(find "$UCLIBC_SYSROOT" -type f \( -name '*.a' -o -name '*.so' -o -name '*.so.*' \) 2>/dev/null)
}

prepare_uclibc_ng() {
    local bad=""
    local build_src="/tmp/uclibc-ng-${UCLIBC_NG_VERSION}-be300"

    prepare_uclibc_headers
    if [ ! -f "$UCLIBC_ARCHIVE" ]; then
        echo "--- Downloading uClibc-ng ${UCLIBC_NG_VERSION} ---"
        if command -v curl >/dev/null 2>&1; then
            curl -L --fail "$UCLIBC_URL" -o "$UCLIBC_ARCHIVE"
        else
            wget "$UCLIBC_URL" -O "$UCLIBC_ARCHIVE"
        fi
    fi

    echo "=== Phase 0b: Building dynamic uClibc-ng ${UCLIBC_NG_VERSION} for MIPS2 ==="
    rm -rf "$build_src" "/tmp/uClibc-ng-${UCLIBC_NG_VERSION}"
    tar xf "$UCLIBC_ARCHIVE" -C /tmp
    mv "/tmp/uClibc-ng-${UCLIBC_NG_VERSION}" "$build_src"
    cd "$build_src"
    chmod -R a+rwX "$build_src" 2>/dev/null || true
    python3 - <<'PY'
from pathlib import Path

path = Path("ldso/ldso/mips/elfinterp.c")
text = path.read_text()
text = text.replace(
    "\t\ttmp_lazy = lazy && !tpnt->dynamic_info[DT_BIND_NOW];\n",
    "\t\t/* BE-300/Linux 2.4: avoid the MIPS lazy resolver path entirely.\n"
    "\t\t * The resolver returns bad targets for Qt/OPIE PLT stubs on the\n"
    "\t\t * 16 MiB image, so resolve global GOT function entries at load time.\n"
    "\t\t */\n"
    "\t\ttmp_lazy = 0;\n",
    1,
)
if "BE-300/Linux 2.4: avoid the MIPS lazy resolver path entirely" not in text:
    raise SystemExit("uClibc-ng MIPS lazy relocation context not found")
old = """\t\t\telse if (ELF_ST_TYPE(sym->st_info) == STT_FUNC &&\n\t\t\t\t*got_entry != sym->st_value && tmp_lazy) {\n\t\t\t\t*got_entry += (unsigned long) tpnt->loadaddr;\n\t\t\t}\n\t\t\telse if (ELF_ST_TYPE(sym->st_info) == STT_SECTION) {\n\t\t\t\tif (sym->st_other == 0)\n\t\t\t\t\t*got_entry += (unsigned long) tpnt->loadaddr;\n\t\t\t}\n\t\t\telse {\n\t\t\t\tstruct symbol_ref sym_ref;\n\t\t\t\tsym_ref.sym = sym;\n\t\t\t\tsym_ref.tpnt = NULL;\n\t\t\t\t*got_entry = (unsigned long) _dl_find_hash(strtab +\n\t\t\t\t\tsym->st_name, &_dl_loaded_modules->symbol_scope, tpnt, ELF_RTYPE_CLASS_PLT, &sym_ref);\n\t\t\t}\n"""
new = """\t\t\telse if (tpnt->libtype == elf_executable ||\n\t\t\t\t(tpnt->dynamic_info[DT_FLAGS] & DF_SYMBOLIC)) {\n\t\t\t\t*got_entry += (unsigned long) tpnt->loadaddr;\n\t\t\t}\n\t\t\telse if (ELF_ST_TYPE(sym->st_info) == STT_FUNC &&\n\t\t\t\t*got_entry != sym->st_value && tmp_lazy) {\n\t\t\t\t*got_entry += (unsigned long) tpnt->loadaddr;\n\t\t\t}\n\t\t\telse if (ELF_ST_TYPE(sym->st_info) == STT_SECTION) {\n\t\t\t\tif (sym->st_other == 0)\n\t\t\t\t\t*got_entry += (unsigned long) tpnt->loadaddr;\n\t\t\t}\n\t\t\telse {\n\t\t\t\tstruct symbol_ref sym_ref;\n\t\t\t\tsym_ref.sym = sym;\n\t\t\t\tsym_ref.tpnt = NULL;\n\t\t\t\t*got_entry = (unsigned long) _dl_find_hash(strtab +\n\t\t\t\t\tsym->st_name, &_dl_loaded_modules->symbol_scope, tpnt, ELF_RTYPE_CLASS_PLT, &sym_ref);\n\t\t\t}\n"""
if old not in text:
    raise SystemExit("uClibc-ng MIPS GOT relocation context not found")
path.write_text(text.replace(old, new, 1))
PY
    make distclean >/tmp/uclibc-ng-distclean.log 2>&1 || true
    make ARCH=mips defconfig >/tmp/uclibc-ng-config.log 2>&1

    set_uclibc_string_config KERNEL_HEADERS "$UCLIBC_KHDRS/include"
    set_uclibc_string_config CROSS_COMPILER_PREFIX "mipsel-linux-gnu-"
    set_uclibc_string_config UCLIBC_EXTRA_CFLAGS "-march=mips2 -msoft-float -fno-stack-protector"
    set_uclibc_string_config RUNTIME_PREFIX "/"
    set_uclibc_string_config DEVEL_PREFIX "/usr/"
    set_uclibc_string_config MULTILIB_DIR "lib"

    disable_uclibc_config ARCH_WANTS_BIG_ENDIAN
    enable_uclibc_config ARCH_WANTS_LITTLE_ENDIAN
    enable_uclibc_config UCLIBC_HAS_FLOATS
    disable_uclibc_config UCLIBC_HAS_FPU
    enable_uclibc_config DO_C99_MATH
    enable_uclibc_config HAVE_SHARED
    enable_uclibc_config DOPIC
    enable_uclibc_config UCLIBC_CTOR_DTOR
    enable_uclibc_config UCLIBC_HAS_NETWORK_SUPPORT
    enable_uclibc_config UCLIBC_HAS_SOCKET
    enable_uclibc_config UCLIBC_HAS_IPV4
    enable_uclibc_config UCLIBC_HAS_RESOLVER_SUPPORT
    enable_uclibc_config UCLIBC_HAS_COMPAT_RES_STATE
    enable_uclibc_config UCLIBC_HAS_WCHAR
    enable_uclibc_config UCLIBC_HAS_LIBICONV
    enable_uclibc_config UCLIBC_HAS_LOCALE
    enable_uclibc_config UCLIBC_BUILD_MINIMAL_LOCALE
    enable_uclibc_config UCLIBC_HAS_XLOCALE
    enable_uclibc_config UCLIBC_HAS_GNU_GETOPT
    enable_uclibc_config UCLIBC_HAS_REGEX
    enable_uclibc_config UCLIBC_HAS_FNMATCH
    enable_uclibc_config UCLIBC_HAS_GLOB
    enable_uclibc_config UCLIBC_HAS_PTY
    enable_uclibc_config UCLIBC_HAS_REALTIME
    enable_uclibc_config UCLIBC_SUSV3_LEGACY
    enable_uclibc_config MALLOC_STANDARD
    disable_uclibc_config HAS_NO_THREADS
    enable_uclibc_config UCLIBC_HAS_LINUXTHREADS
    disable_uclibc_config UCLIBC_HAS_THREADS_NATIVE

    disable_uclibc_config UCLIBC_USE_MIPS_PREFETCH
    disable_uclibc_config DO_XSI_MATH
    disable_uclibc_config UCLIBC_HAS_LONG_DOUBLE_MATH
    disable_uclibc_config LDSO_LDD_SUPPORT
    disable_uclibc_config LDSO_CACHE_SUPPORT
    disable_uclibc_config LDSO_PRELOAD_ENV_SUPPORT
    disable_uclibc_config LDSO_PRELOAD_FILE_SUPPORT
    disable_uclibc_config LDSO_RUNPATH
    disable_uclibc_config UCLIBC_STATIC_LDCONFIG
    disable_uclibc_config UCLIBC_HAS_SSP
    disable_uclibc_config UCLIBC_USE_TIME64
    disable_uclibc_config UCLIBC_HAS_PROFILING
    disable_uclibc_config UCLIBC_HAS_XATTR
    disable_uclibc_config UCLIBC_HAS_IPV6
    disable_uclibc_config UCLIBC_HAS_CRYPT_IMPL
    disable_uclibc_config UCLIBC_HAS_CRYPT
    disable_uclibc_config UCLIBC_HAS_UTMP
    disable_uclibc_config UCLIBC_HAS_UTMPX
    disable_uclibc_config UCLIBC_BUILD_ALL_LOCALE
    set_uclibc_string_config UCLIBC_BUILD_MINIMAL_LOCALES "en_US"

    yes "" | make ARCH=mips oldconfig >>/tmp/uclibc-ng-config.log 2>&1
    # uClibc-ng 1.0.51's shared libc archive rule references these .oS
    # objects without reliably ordering their pattern builds on this host make.
    # Build them explicitly before the full library pass.
    make -j1 \
        libc/misc/elf/dl-iterate-phdr.oS \
        libc/misc/internals/__uClibc_main.oS \
        libc/stdlib/system.oS \
        ldso/libdl/libdl.oS \
        LIBGCC=/tmp/libgcc_patched/libgcc.a \
        >/tmp/uclibc-ng-shared-objs.log 2>&1 || {
        tail -80 /tmp/uclibc-ng-shared-objs.log
        exit 1
    }
    make -j1 LIBGCC=/tmp/libgcc_patched/libgcc.a \
        >/tmp/uclibc-ng-build.log 2>&1 || {
        tail -80 /tmp/uclibc-ng-build.log
        exit 1
    }

    rm -rf "$UCLIBC_SYSROOT"
    mkdir -p "$UCLIBC_SYSROOT"
    make PREFIX="$UCLIBC_SYSROOT" install_runtime install_dev \
        >/tmp/uclibc-ng-install.log 2>&1 || {
        tail -80 /tmp/uclibc-ng-install.log
        exit 1
    }
    for script in "$UCLIBC_SYSROOT"/usr/lib/*.so; do
        [ -f "$script" ] || continue
        if grep -q "GNU ld script" "$script"; then
            sed -i \
                -e "s@ /lib/@ $UCLIBC_SYSROOT/lib/@g" \
                -e "s@(/lib/@($UCLIBC_SYSROOT/lib/@g" \
                -e "s@ /usr/lib/@ $UCLIBC_SYSROOT/usr/lib/@g" \
                -e "s@(/usr/lib/@($UCLIBC_SYSROOT/usr/lib/@g" \
                "$script"
        fi
    done
    cd /work

    mipsel-linux-gnu-gcc -dumpspecs > /work/uclibc-gcc.specs
    UCLIBC_CRTBEGIN="$(mipsel-linux-gnu-gcc -print-file-name=crtbegin.o)"
    UCLIBC_CRTEND="$(mipsel-linux-gnu-gcc -print-file-name=crtend.o)"
    UCLIBC_CRTBEGIN_S="$(mipsel-linux-gnu-gcc -print-file-name=crtbeginS.o)"
    UCLIBC_CRTEND_S="$(mipsel-linux-gnu-gcc -print-file-name=crtendS.o)"
    UCLIBC_GCC_INCLUDE="$(mipsel-linux-gnu-gcc -print-file-name=include)"
    UCLIBC_GCC_INCLUDE_FIXED="$(mipsel-linux-gnu-gcc -print-file-name=include-fixed)"
    cat > "$UCLIBC_CC" <<UCLIBC_GCC
#!/bin/sh
linking=true
shared=false
for arg in "\$@"; do
    case "\$arg" in
        -c|-E|-S|-r)
            linking=false
            break
            ;;
        -shared)
            shared=true
            ;;
    esac
done

COMMON="-march=mips2 -msoft-float -mabi=32 -fno-stack-protector -fno-pie"
EXE_FLAGS="-no-pie"
INCLUDES="-nostdinc -isystem $UCLIBC_SYSROOT/usr/include -isystem $UCLIBC_KHDRS/include -isystem $UCLIBC_GCC_INCLUDE -isystem $UCLIBC_GCC_INCLUDE_FIXED"

if \$linking; then
    if \$shared; then
        exec mipsel-linux-gnu-gcc \$COMMON \$INCLUDES -nostdlib \
            -Wl,-Bsymbolic \
            -Wl,-rpath-link,$UCLIBC_SYSROOT/lib \
            -Wl,-rpath-link,$UCLIBC_SYSROOT/usr/lib \
            $UCLIBC_SYSROOT/usr/lib/crti.o \
            $UCLIBC_CRTBEGIN_S \
            -L$UCLIBC_SYSROOT/usr/lib \
            -L$UCLIBC_SYSROOT/lib \
            -L/tmp/libgcc_patched \
            "\$@" \
            -lc \
            /tmp/libgcc_patched/libgcc.a \
            $UCLIBC_CRTEND_S \
            $UCLIBC_SYSROOT/usr/lib/crtn.o
    else
        exec mipsel-linux-gnu-gcc \$COMMON \$EXE_FLAGS \$INCLUDES -nostdlib \
            -Wl,-dynamic-linker,/lib/ld-uClibc.so.0 \
            -Wl,-rpath-link,$UCLIBC_SYSROOT/lib \
            -Wl,-rpath-link,$UCLIBC_SYSROOT/usr/lib \
            $UCLIBC_SYSROOT/usr/lib/crt1.o \
            $UCLIBC_SYSROOT/usr/lib/crti.o \
            $UCLIBC_CRTBEGIN \
            -L$UCLIBC_SYSROOT/usr/lib \
            -L$UCLIBC_SYSROOT/lib \
            -L/tmp/libgcc_patched \
            "\$@" \
            -lc \
            /tmp/libgcc_patched/libgcc.a \
            $UCLIBC_CRTEND \
            $UCLIBC_SYSROOT/usr/lib/crtn.o
    fi
else
    exec mipsel-linux-gnu-gcc \$COMMON \$INCLUDES "\$@"
fi
UCLIBC_GCC
    chmod +x "$UCLIBC_CC"
    cat > "$UCLIBC_CXX" <<UCLIBC_CXX_WRAPPER
#!/bin/sh
linking=true
shared=false
for arg in "\$@"; do
    case "\$arg" in
        -c|-E|-S|-r)
            linking=false
            break
            ;;
        -shared)
            shared=true
            ;;
    esac
done

COMMON="-march=mips2 -msoft-float -mabi=32 -fno-stack-protector -fno-pie"
EXE_FLAGS="-no-pie"
INCLUDES="-nostdinc -isystem $UCLIBC_SYSROOT/usr/include -isystem $UCLIBC_KHDRS/include -isystem $UCLIBC_GCC_INCLUDE -isystem $UCLIBC_GCC_INCLUDE_FIXED"

if \$linking; then
    if \$shared; then
        exec mipsel-linux-gnu-gcc \$COMMON \$INCLUDES -nostdlib \
            -Wl,-Bsymbolic \
            -Wl,-rpath-link,$UCLIBC_SYSROOT/lib \
            -Wl,-rpath-link,$UCLIBC_SYSROOT/usr/lib \
            $UCLIBC_SYSROOT/usr/lib/crti.o \
            $UCLIBC_CRTBEGIN_S \
            -L$UCLIBC_SYSROOT/usr/lib \
            -L$UCLIBC_SYSROOT/lib \
            -L/tmp/libgcc_patched \
            "\$@" \
            -lc \
            /tmp/libgcc_patched/libgcc.a \
            $UCLIBC_CRTEND_S \
            $UCLIBC_SYSROOT/usr/lib/crtn.o
    else
        exec mipsel-linux-gnu-gcc \$COMMON \$EXE_FLAGS \$INCLUDES -nostdlib \
            -Wl,-dynamic-linker,/lib/ld-uClibc.so.0 \
            -Wl,-rpath-link,$UCLIBC_SYSROOT/lib \
            -Wl,-rpath-link,$UCLIBC_SYSROOT/usr/lib \
            $UCLIBC_SYSROOT/usr/lib/crt1.o \
            $UCLIBC_SYSROOT/usr/lib/crti.o \
            $UCLIBC_CRTBEGIN \
            -L$UCLIBC_SYSROOT/usr/lib \
            -L$UCLIBC_SYSROOT/lib \
            -L/tmp/libgcc_patched \
            "\$@" \
            -lc \
            /tmp/libgcc_patched/libgcc.a \
            $UCLIBC_CRTEND \
            $UCLIBC_SYSROOT/usr/lib/crtn.o
    fi
else
    exec mipsel-linux-gnu-g++ \$COMMON \$INCLUDES "\$@"
fi
UCLIBC_CXX_WRAPPER
    chmod +x "$UCLIBC_CXX"
    for tool in ar ranlib strip objcopy objdump readelf nm; do
        cat > "/work/mipsel-uclibc-${tool}" <<UCLIBC_TOOL
#!/bin/sh
exec mipsel-linux-gnu-${tool} "\$@"
UCLIBC_TOOL
        chmod +x "/work/mipsel-uclibc-${tool}"
    done

    bad="$(check_uclibc_mips2)"
    if [ -n "$bad" ]; then
        echo "ERROR: uClibc-ng contains unsupported VR4131 instructions:" >&2
        echo "$bad" >&2
        exit 1
    fi
}

install_uclibc_runtime() {
    local lib

    echo "=== Installing uClibc-ng shared runtime into rootfs ==="
    mkdir -p "$ROOTFS/lib" "$ROOTFS/usr/lib"
    for lib in "$UCLIBC_SYSROOT"/lib/*.so*; do
        [ -e "$lib" ] || continue
        cp -a "$lib" "$ROOTFS/lib/"
    done
    for lib in "$UCLIBC_SYSROOT"/usr/lib/*.so*; do
        [ -e "$lib" ] || continue
        cp -a "$lib" "$ROOTFS/usr/lib/"
    done
    if [ ! -e "$ROOTFS/lib/ld-uClibc.so.0" ]; then
        echo "ERROR: uClibc-ng runtime did not install /lib/ld-uClibc.so.0" >&2
        exit 1
    fi
    while IFS= read -r lib; do
        mipsel-linux-gnu-strip --strip-unneeded \
            --remove-section=.comment \
            --remove-section=.note \
            "$lib" 2>/dev/null || true
    done < <(find "$ROOTFS/lib" "$ROOTFS/usr/lib" -type f -name '*.so*')
}

TARGET_CC="mipsel-linux-gnu-gcc"
TARGET_CXX="mipsel-linux-gnu-g++"
TARGET_AR="mipsel-linux-gnu-ar"
TARGET_RANLIB="mipsel-linux-gnu-ranlib"
TARGET_STRIP="mipsel-linux-gnu-strip"
TARGET_CROSS_COMPILE="mipsel-linux-gnu-"
TARGET_ARCH_CFLAGS="-march=mips2 -mfpxx"
TARGET_STATIC_LDFLAGS="-static"
TARGET_LIBC_CFLAGS="-specs $MUSL_SPECS -isystem $KHDRS/include"
TARGET_LIBC_LDFLAGS="-B/tmp/libgcc_patched -L/tmp/libgcc_patched"
TARGET_LIBC_NAME="musl"

if [ "$BE300_LIBC" = "uclibc" ]; then
    prepare_uclibc_ng
    TARGET_CC="$UCLIBC_CC"
    TARGET_CXX="$UCLIBC_CXX"
    TARGET_AR="/work/mipsel-uclibc-ar"
    TARGET_RANLIB="/work/mipsel-uclibc-ranlib"
    TARGET_STRIP="/work/mipsel-uclibc-strip"
    TARGET_CROSS_COMPILE="/work/mipsel-uclibc-"
    TARGET_ARCH_CFLAGS="-march=mips2 -msoft-float"
    TARGET_STATIC_LDFLAGS=""
    TARGET_LIBC_NAME="uClibc-ng"
    TARGET_LIBC_CFLAGS="-isystem $UCLIBC_SYSROOT/usr/include -isystem $UCLIBC_KHDRS/include"
    TARGET_LIBC_LDFLAGS="-Wl,-rpath-link,$UCLIBC_SYSROOT/lib -Wl,-rpath-link,$UCLIBC_SYSROOT/usr/lib"
fi

###############################################################################
# Phase 1: Build BusyBox, install into the JFFS2 rootfs source tree
###############################################################################

echo "=== Phase 1: Building BusyBox with ${TARGET_LIBC_NAME} ==="

BBOX_DIR="/work/busybox-${BUSYBOX_VERSION}"
if [ ! -d "$BBOX_DIR" ]; then
    echo "ERROR: $BBOX_DIR not found — extract busybox-${BUSYBOX_VERSION}.tar.bz2 first"
    exit 1
fi

# Rebuild busybox from scratch with the selected libc + mips2.
cd "$BBOX_DIR"
make ARCH=mips CROSS_COMPILE="$TARGET_CROSS_COMPILE" distclean || true
make ARCH=mips CROSS_COMPILE="$TARGET_CROSS_COMPILE" defconfig

enable_busybox_config() {
    cfg="$1"
    if grep -q "^# ${cfg} is not set" .config; then
        sed -i "s/^# ${cfg} is not set/${cfg}=y/" .config
    elif grep -q "^${cfg}=n" .config; then
        sed -i "s/^${cfg}=n/${cfg}=y/" .config
    elif ! grep -q "^${cfg}=" .config; then
        echo "${cfg}=y" >> .config
    fi
}

disable_busybox_config() {
    cfg="$1"
    if grep -q "^${cfg}=" .config; then
        sed -i "s/^${cfg}=.*/# ${cfg} is not set/" .config
    elif ! grep -q "^# ${cfg} is not set" .config; then
        echo "# ${cfg} is not set" >> .config
    fi
}

set_busybox_int_config() {
    cfg="$1"
    val="$2"
    if grep -q "^${cfg}=" .config; then
        sed -i "s@^${cfg}=.*@${cfg}=${val}@" .config
    else
        echo "${cfg}=${val}" >> .config
    fi
}

set_busybox_string_config() {
    cfg="$1"
    val="$2"
    if grep -q "^${cfg}=" .config; then
        sed -i "s@^${cfg}=.*@${cfg}=\"${val}\"@" .config
    else
        echo "${cfg}=\"${val}\"" >> .config
    fi
}

# Musl stays static for the known-good image.  uClibc-ng is normally dynamic
# so browser-style profiles can share libc/libm pages across processes, but
# TinyX keeps BusyBox static: the interactive ash running under rxvt otherwise
# hits the same fragile MIPS/uClibc dynamic-loader call path as early X bring-up.
if [ "$BE300_LIBC" = "musl" ] || [ "$BE300_UI" = "tinyx" ]; then
    enable_busybox_config CONFIG_STATIC
else
    disable_busybox_config CONFIG_STATIC
fi
sed -i 's/^# CONFIG_USE_BB_CRYPT is not set/CONFIG_USE_BB_CRYPT=y/' .config
sed -i 's/^# CONFIG_USE_BB_CRYPT_SHA is not set/CONFIG_USE_BB_CRYPT_SHA=y/' .config
# Disable WTMP (musl's _PATH_WTMP not auto-included in libbb)
sed -i 's/^CONFIG_FEATURE_WTMP=y/CONFIG_FEATURE_WTMP=n/' .config
sed -i 's/^CONFIG_FEATURE_UTMP=y/CONFIG_FEATURE_UTMP=n/' .config
# Keep the NE2000 boot smoke test available on clean BusyBox rebuilds.
for cfg in CONFIG_ARP CONFIG_ARPING CONFIG_IFCONFIG CONFIG_IP \
    CONFIG_FEATURE_IP_ADDRESS CONFIG_FEATURE_IP_LINK CONFIG_FEATURE_IP_ROUTE \
    CONFIG_IPADDR CONFIG_IPLINK CONFIG_IPROUTE CONFIG_NSLOOKUP CONFIG_PING \
    CONFIG_ROUTE CONFIG_UDHCPC CONFIG_WGET; do
    enable_busybox_config "$cfg"
done
sed -i 's@^CONFIG_UDHCPC_DEFAULT_SCRIPT=.*@CONFIG_UDHCPC_DEFAULT_SCRIPT="/usr/share/udhcpc/default.script"@' .config
# Phase 0's libc-compat.h sed teaches the linux UAPI to keep its hands off
# struct definitions when musl already provides them, so most networking
# applets compile against -isystem $KHDRS/include now. Keep disabled only
# the applets that need niche kernel headers (linux/pkt_sched.h, if_vlan.h,
# if_bridge.h, if_tunnel.h, …) or runtime support we don't have (NFS/RPC,
# nanosleep — gettimeofday_ns).
for cfg in CONFIG_BRCTL CONFIG_DNSD CONFIG_FAKEIDENTD CONFIG_FTPD \
    CONFIG_HTTPD CONFIG_IFENSLAVE CONFIG_IFPLUGD CONFIG_IFUPDOWN \
    CONFIG_INETD CONFIG_IPTUNNEL CONFIG_NBDCLIENT CONFIG_NTPD \
    CONFIG_PSCAN CONFIG_SLATTACH CONFIG_TCPSVD CONFIG_TELNETD \
    CONFIG_TFTPD CONFIG_UDHCPD CONFIG_UDPSVD CONFIG_VCONFIG \
    CONFIG_ZCIP CONFIG_TUNCTL CONFIG_TC CONFIG_FEATURE_MOUNT_NFS \
    CONFIG_FEATURE_HAVE_RPC CONFIG_FEATURE_INETD_RPC \
    CONFIG_FEATURE_SYSLOGD_CFG CONFIG_RUNSV CONFIG_RUNSVDIR CONFIG_SV \
    CONFIG_SVLOGD CONFIG_CHPST CONFIG_ENVDIR CONFIG_ENVUIDGID \
    CONFIG_SETUIDGID CONFIG_SOFTLIMIT; do
    sed -i "s/^${cfg}=y/${cfg}=n/" .config
done
# Keep BusyBox to the applets needed by init scripts, network setup, and a
# usable rescue shell. The full defconfig costs disk, JFFS2 metadata, and shell
# RSS that the 16 MiB browser profile needs more.
for cfg in CONFIG_DD CONFIG_OD CONFIG_HEXDUMP CONFIG_FEATURE_HEXDUMP_REVERSE \
    CONFIG_VI CONFIG_FEATURE_VI_COLON CONFIG_FEATURE_VI_YANKMARK \
    CONFIG_FEATURE_VI_SEARCH CONFIG_FEATURE_VI_USE_SIGNALS \
    CONFIG_FEATURE_VI_DOT_CMD CONFIG_FEATURE_VI_READONLY \
    CONFIG_FEATURE_VI_SETOPTS CONFIG_FEATURE_VI_SET \
    CONFIG_FEATURE_VI_WIN_RESIZE CONFIG_FEATURE_VI_ASK_TERMINAL \
    CONFIG_FEATURE_VI_UNDO CONFIG_FEATURE_VI_UNDO_QUEUE \
    CONFIG_LESS CONFIG_MORE CONFIG_FINDFS CONFIG_MOUNTPOINT \
    CONFIG_IPCRM CONFIG_IPCS CONFIG_PSTREE CONFIG_FEATURE_SHOW_THREADS \
    CONFIG_NC CONFIG_NC_SERVER CONFIG_NC_EXTRA CONFIG_TELNET \
    CONFIG_FTPGET CONFIG_FTPPUT CONFIG_TRACEROUTE CONFIG_TRACEROUTE6 \
    CONFIG_PING6 CONFIG_FEATURE_IPV6 CONFIG_NETSTAT CONFIG_NAMEIF \
    CONFIG_IPCALC CONFIG_FEATURE_IPCALC_FANCY \
    CONFIG_FEATURE_IPCALC_LONG_OPTIONS CONFIG_FEATURE_IP_TUNNEL \
    CONFIG_FEATURE_IP_RULE CONFIG_IPTUNNEL CONFIG_IPRULE \
    CONFIG_WGET CONFIG_FEATURE_WGET_STATUSBAR \
    CONFIG_FEATURE_WGET_AUTHENTICATION CONFIG_FEATURE_WGET_LONG_OPTIONS \
    CONFIG_FEATURE_WGET_TIMEOUT CONFIG_FEATURE_WGET_OPENSSL \
    CONFIG_FEATURE_WGET_SSL_HELPER CONFIG_FEATURE_FANCY_PING \
    CONFIG_FEATURE_IFCONFIG_SLIP CONFIG_FEATURE_IFCONFIG_MEMSTART_IOADDR_IRQ \
    CONFIG_FEATURE_IFCONFIG_HW \
    CONFIG_FEATURE_IPC_SYSLOG CONFIG_FEATURE_EDITING_SAVEHISTORY \
    CONFIG_FEATURE_TAB_COMPLETION CONFIG_FEATURE_EDITING_FANCY_PROMPT \
    CONFIG_MKTEMP CONFIG_CHATTR CONFIG_CHAT CONFIG_CRONTAB CONFIG_DC \
    CONFIG_FEATURE_DC_LIBM CONFIG_DEVMEM CONFIG_EJECT CONFIG_FEATURE_EJECT_SCSI \
    CONFIG_FBSPLASH CONFIG_HDPARM CONFIG_FEATURE_HDPARM_GET_IDENTITY \
    CONFIG_FEATURE_HDPARM_HDIO_SCAN_HWIF CONFIG_FEATURE_HDPARM_HDIO_UNREGISTER_HWIF \
    CONFIG_FEATURE_HDPARM_HDIO_DRIVE_RESET CONFIG_FEATURE_HDPARM_HDIO_TRISTATE_HWIF \
    CONFIG_FEATURE_HDPARM_HDIO_GETSET_DMA CONFIG_IONICE CONFIG_MAN \
    CONFIG_MICROCOM CONFIG_MT CONFIG_RAIDAUTORUN CONFIG_READAHEAD CONFIG_RX \
    CONFIG_STRINGS CONFIG_TIME CONFIG_TIMEOUT CONFIG_TTYSIZE CONFIG_VOLNAME \
    CONFIG_WATCHDOG CONFIG_WHOIS CONFIG_TFTP CONFIG_FEATURE_TFTP_GET \
    CONFIG_FEATURE_TFTP_PUT CONFIG_FEATURE_TFTP_BLOCKSIZE \
    CONFIG_FEATURE_TFTP_PROGRESS_BAR CONFIG_LPD CONFIG_LPR CONFIG_LPQ \
    CONFIG_MAKEMIME CONFIG_POPMAILDIR CONFIG_FEATURE_POPMAILDIR_DELIVERY \
    CONFIG_REFORMIME CONFIG_FEATURE_REFORMIME_COMPAT CONFIG_SENDMAIL \
    CONFIG_IOSTAT CONFIG_LSOF CONFIG_MPSTAT CONFIG_NMETER CONFIG_PMAP \
    CONFIG_POWERTOP CONFIG_PWDX CONFIG_SMEMCAP CONFIG_TOP \
    CONFIG_FEATURE_TOP_CPU_USAGE_PERCENTAGE CONFIG_FEATURE_TOP_CPU_GLOBAL_PERCENTS \
    CONFIG_FEATURE_TOP_SMP_CPU CONFIG_FEATURE_TOP_DECIMALS \
    CONFIG_FEATURE_TOP_SMP_PROCESS CONFIG_FEATURE_TOPMEM CONFIG_FUSER \
    CONFIG_PGREP CONFIG_PIDOF CONFIG_FEATURE_PIDOF_SINGLE \
    CONFIG_FEATURE_PIDOF_OMIT CONFIG_PKILL CONFIG_BB_SYSCTL CONFIG_WATCH \
    CONFIG_HUSH_BASH_COMPAT CONFIG_HUSH_BRACE_EXPANSION \
    CONFIG_HUSH_HELP CONFIG_HUSH_MODE_X CONFIG_HUSH_TICK \
    CONFIG_SYSLOGD CONFIG_FEATURE_ROTATE_LOGFILE \
    CONFIG_FEATURE_REMOTE_LOG CONFIG_FEATURE_SYSLOGD_DUP CONFIG_KLOGD \
    CONFIG_FEATURE_KLOGD_KLOGCTL CONFIG_LOGGER; do
    disable_busybox_config "$cfg"
done
# Enable hush as an alternative shell to ash.  hush has a simpler signal
# model and is being used as a workaround for the MIPS pc=0 SEGV bug
# that hits ash when launched from rxvt on a pty (task #13).  Keep ash
# available too so the serial shell on ttyVR0 still works as before.
# CONFIG_HUSH_JOB is DELIBERATELY OFF: enabling it brings back the same
# SIGTSTP/SIGTTIN/SIGTTOU signal-frame bug we're trying to dodge in ash.
# Ctrl-C still works because SIGINT delivery is unaffected.
for cfg in CONFIG_HUSH CONFIG_HUSH_INTERACTIVE \
    CONFIG_HUSH_IF CONFIG_HUSH_LOOPS CONFIG_HUSH_CASE \
    CONFIG_HUSH_FUNCTIONS CONFIG_HUSH_LOCAL CONFIG_HUSH_EXPORT_N \
    CONFIG_HUSH_RANDOM_SUPPORT; do
    enable_busybox_config "$cfg"
done
disable_busybox_config CONFIG_HUSH_JOB
# Disable ash job control globally for the same reason.
sed -i 's/^CONFIG_ASH_JOB_CONTROL=y/CONFIG_ASH_JOB_CONTROL=n/' .config
# FEATURE_EDITING is RE-ENABLED now that the kernel VDSO sigreturn
# trampoline is restored (patch 0003 no longer stubs
# arch_setup_additional_pages, so signal handlers can return cleanly).
# Arrow-key history is back.
enable_busybox_config CONFIG_FEATURE_EDITING
enable_busybox_config CONFIG_FEATURE_EDITING_HISTORY
set_busybox_int_config CONFIG_FEATURE_EDITING_MAX_LEN 256
set_busybox_int_config CONFIG_FEATURE_EDITING_HISTORY 16

set_busybox_string_config CONFIG_EXTRA_CFLAGS "$TARGET_ARCH_CFLAGS -Os -fomit-frame-pointer -ffunction-sections -fdata-sections -fno-unwind-tables -fno-asynchronous-unwind-tables $TARGET_LIBC_CFLAGS"
set_busybox_string_config CONFIG_EXTRA_LDFLAGS "-Wl,--gc-sections -Wl,-s $TARGET_LIBC_LDFLAGS"
set_busybox_string_config CONFIG_EXTRA_LDLIBS ""

yes "" | make ARCH=mips CROSS_COMPILE="$TARGET_CROSS_COMPILE" oldconfig

# Build with the selected target libc + mips2.  The libc-specific flags above
# supply either musl specs or the uClibc-ng sysroot.
prepare_be300_libgcc

if ! grep -q 'BE300_FORCE_OBJECTS' scripts/trylink; then
    sed -i '/\$START_GROUP \$O_FILES \$A_FILES \$END_GROUP \\/a\
		$BE300_FORCE_OBJECTS \\' scripts/trylink
fi

export BE300_FORCE_OBJECTS="/tmp/libgcc_helpers.o"
make ARCH=mips CROSS_COMPILE="$TARGET_CROSS_COMPILE" busybox -j$(nproc) 2>&1 | tail -5
unset BE300_FORCE_OBJECTS
ls -l busybox
be300_strip_binary busybox

# Populate full rootfs (this becomes the JFFS2 mtd3 partition).
rm -rf "$ROOTFS"
mkdir -p "$ROOTFS"/{bin,sbin,usr/bin,usr/sbin,proc,sys,dev,tmp,etc,root,mnt,usr/share/udhcpc}
cp busybox "$ROOTFS/bin/busybox"
chmod +x "$ROOTFS/bin/busybox"
if [ "$BE300_LIBC" = "uclibc" ]; then
    install_uclibc_runtime
fi

# Phase A smoke test: a userspace mmap of /dev/fb0 that draws a checkerboard.
# Sanity-checks the sfb_mmap() path before any real GUI lib (Microwindows,
# Qt/E, SDL) tries to use it.
$TARGET_CC $TARGET_ARCH_CFLAGS -O2 $TARGET_STATIC_LDFLAGS \
    $TARGET_LIBC_CFLAGS $TARGET_LIBC_LDFLAGS \
    /work/board/casio-be300/fb_mmap_test.c \
    /tmp/libgcc_helpers.o \
    -o /tmp/fb_mmap_test
be300_strip_binary /tmp/fb_mmap_test
if [ "${BE300_INSTALL_DIAGNOSTICS:-0}" = "1" ]; then
    cp /tmp/fb_mmap_test "$ROOTFS/bin/fb_mmap_test"
    chmod +x "$ROOTFS/bin/fb_mmap_test"
fi

# Phase B smoke test: query the PIU touchscreen input_dev capabilities.
$TARGET_CC $TARGET_ARCH_CFLAGS -O2 $TARGET_STATIC_LDFLAGS \
    $TARGET_LIBC_CFLAGS $TARGET_LIBC_LDFLAGS \
    /work/board/casio-be300/touch_query_test.c \
    /tmp/libgcc_helpers.o \
    -o /tmp/touch_query_test
be300_strip_binary /tmp/touch_query_test
if [ "${BE300_INSTALL_DIAGNOSTICS:-0}" = "1" ]; then
    cp /tmp/touch_query_test "$ROOTFS/bin/touch_query_test"
    chmod +x "$ROOTFS/bin/touch_query_test"
fi

# VT mode helper used by framebuffer-owning GUIs. KD_GRAPHICS leaves fbcon
# active for boot/crash text but prevents it from repainting over /dev/fb0
# while Qt/Embedded or Nano-X owns the screen.
$TARGET_CC $TARGET_ARCH_CFLAGS -Os $TARGET_STATIC_LDFLAGS \
    $TARGET_LIBC_CFLAGS $TARGET_LIBC_LDFLAGS \
    /work/board/opie/be300_vtmode.c \
    /tmp/libgcc_helpers.o \
    -o /tmp/be300-vtmode
be300_strip_binary /tmp/be300-vtmode
cp /tmp/be300-vtmode "$ROOTFS/bin/be300-vtmode"
chmod +x "$ROOTFS/bin/be300-vtmode"

if [ "$BE300_UI" = "tinyx" ]; then
    $TARGET_CC $TARGET_ARCH_CFLAGS -Os $TARGET_STATIC_LDFLAGS \
        $TARGET_LIBC_CFLAGS $TARGET_LIBC_LDFLAGS \
        /work/board/casio-be300/fb_refresh_be300.c \
        /tmp/libgcc_helpers.o \
        -o /tmp/be300-fbrefresh
    be300_strip_binary /tmp/be300-fbrefresh
    cp /tmp/be300-fbrefresh "$ROOTFS/bin/be300-fbrefresh"
    chmod +x "$ROOTFS/bin/be300-fbrefresh"
fi

# Phase C' — optional GUI profile.  The default Microwindows / Nano-X path
# builds Nano-X plus an FLTK/NXlib Dillo browser. The OPIE profile replaces it
# with Qt/Embedded + curated OPIE apps.
if [ "$BE300_UI" = "microwindows" ]; then
# Microwindows / Nano-X (builds against musl + mips2, no distro libstdc++).
# Builds the nano-X server plus a small client app set (launcher, terminal,
# browser, soft keyboard, and diagnostics). Input devices are discovered by
# evdev device name so optional keyboards do not change the touchscreen event
# path.
#
# Source tree layout: microwindows/ is a fresh extraction of
# ghaerr/microwindows; our overlays live at /work/board/microwindows/ and
# are copied + patched in here so the upstream tree stays clean.
echo "=== Building Microwindows / Nano-X for BE-300 ==="
if [ ! -f microwindows-master.tar.gz ]; then
    wget -q "https://github.com/ghaerr/microwindows/archive/refs/heads/master.tar.gz" \
        -O microwindows-master.tar.gz
fi
if [ ! -d microwindows ]; then
    tar xzf microwindows-master.tar.gz
    mv microwindows-master microwindows
fi
# Overlay our config + evdev drivers, idempotently
cp /work/board/microwindows/config.be300 \
   /work/microwindows/src/Configs/config.be300
cp /work/board/microwindows/kbd_evdev.c \
   /work/microwindows/src/drivers/kbd_evdev.c
cp /work/board/microwindows/mou_evdev.c \
   /work/microwindows/src/drivers/mou_evdev.c
cp /work/board/microwindows/nxweb.c \
   /work/microwindows/src/demos/nanox/nxweb.c
python3 - <<'PY'
from pathlib import Path

root = Path("/work/microwindows/src/demos/nanox")

path = root / "nxlaunch.h"
text = path.read_text()
text = text.replace("#define ITEM_WIDTH 100\n", "#define ITEM_WIDTH 112\n")
text = text.replace("#define ITEM_HEIGHT 60\n", "#define ITEM_HEIGHT 58\n")
text = text.replace("#define TEXT_Y_POSITION (ITEM_HEIGHT - 6)\n",
                    "#define TEXT_Y_POSITION (ITEM_HEIGHT - 8)\n")
path.write_text(text)

path = root / "nxlaunch.c"
text = path.read_text()
text = text.replace("""\
void reaper(int signum) {
\tpid_t pid;

\tsignal(SIGCHLD, &reaper);
\twhile((pid = waitpid(-1, NULL, WNOHANG) > 0))
\t\tif(pid == sspid) sspid = -1;
}
""", """\
void reaper(int signum) {
\tpid_t pid;

\t(void)signum;
\twhile((pid = waitpid(-1, NULL, WNOHANG)) > 0)
\t\tif(pid == sspid) sspid = -1;
}
""")
text = text.replace("case GR_EVENT_TYPE_BUTTON_DOWN:\n\t\t\thandle_mouse_event(state);\n\t\t\tbreak;",
                    "case GR_EVENT_TYPE_BUTTON_UP:\n\t\t\thandle_mouse_event(state);\n\t\t\tbreak;")
text = text.replace("GrSelectEvents(i->wid, GR_EVENT_MASK_EXPOSURE | GR_EVENT_MASK_BUTTON_DOWN);",
                    "GrSelectEvents(i->wid, GR_EVENT_MASK_EXPOSURE | GR_EVENT_MASK_BUTTON_UP);")
text = text.replace("\tsignal(SIGCHLD, &reaper);\n", "\tsignal(SIGCHLD, SIG_IGN);\n")
path.write_text(text)

path = root / "nxterm.c"
text = path.read_text()
old = """\
    col = stdcol;
    row = stdrow;
    scrolltop=0;
    scrollbottom = row;

    regFont = GrCreateFontEx(GR_FONT_SYSTEM_FIXED, 0, 0, NULL);
    /*regFont = GrCreateFontEx(GR_FONT_OEM_FIXED, 0, 0, NULL);*/
    /*boldFont = GrCreateFontEx(GR_FONT_SYSTEM_FIXED, 0, 0, NULL);*/
    GrGetFontInfo(regFont, &fi);
    winw = col*fi.maxwidth;
    winh = row*fi.height;
    w1 = GrNewWindowEx(GR_WM_PROPS_APPWINDOW, TITLE, GR_ROOT_WINDOW_ID, -1,-1,winw,winh,
\t\tstdbackground);
"""
new = """\
    col = stdcol;
    row = stdrow;
    scrolltop=0;

    regFont = GrCreateFontEx(GR_FONT_SYSTEM_FIXED, 0, 0, NULL);
    /*regFont = GrCreateFontEx(GR_FONT_OEM_FIXED, 0, 0, NULL);*/
    /*boldFont = GrCreateFontEx(GR_FONT_SYSTEM_FIXED, 0, 0, NULL);*/
    GrGetFontInfo(regFont, &fi);
#if BE300_TOUCHSCREEN
    {
        int fw = fi.maxwidth ? fi.maxwidth : 6;
        int fh = fi.height ? fi.height : 13;
        int maxcol = (si.cols - 12) / fw;
        int maxrow = (si.rows - 56) / fh;

        if (maxcol < 20)
            maxcol = 20;
        if (maxrow < 8)
            maxrow = 8;
        if (maxcol < col)
            col = maxcol;
        if (maxrow < row)
            row = maxrow;
    }
#endif
    scrollbottom = row;
    winw = col*fi.maxwidth;
    winh = row*fi.height;
    w1 = GrNewWindowEx(GR_WM_PROPS_APPWINDOW, TITLE, GR_ROOT_WINDOW_ID, 0, 0, winw, winh,
\t\tstdbackground);
"""
if old in text:
    text = text.replace(old, new)
path.write_text(text)

path = root / "nxclock.c"
text = path.read_text()
text = text.replace("#define CWIDTH\t\t200\n", "#define CWIDTH\t\t180\n")
text = text.replace("#define CHEIGHT\t\t200\n", "#define CHEIGHT\t\t180\n")
text = text.replace('GR_ROOT_WINDOW_ID,\n\t\t-1, -1, CWIDTH, CHEIGHT',
                    'GR_ROOT_WINDOW_ID,\n\t\t0, 0, CWIDTH, CHEIGHT')
path.write_text(text)

path = root / "nxcalc.c"
text = path.read_text()
text = text.replace('GR_ROOT_WINDOW_ID,\n                        10, 10, WIN_W, WIN_H',
                    'GR_ROOT_WINDOW_ID,\n                        0, 0, WIN_W, WIN_H')
path.write_text(text)

path = Path("/work/microwindows/src/nanox/wmevents.c")
text = path.read_text()
old = """\
\tswitch(window->type) {
\t\tcase WINDOW_TYPE_CONTAINER:
\t\t\twm_container_buttondown(window, event);
\t\t\treturn 1; \t/* eat event*/
\t\tdefault:
\t\t\tDprintf(\"Unhandled button down on window %d \"
\t\t\t\t\"(type %d)\\n\", window->wid, window->type);
\t\t\tbreak;
\t}
"""
new = """\
\tswitch(window->type) {
\t\tcase WINDOW_TYPE_CONTAINER:
\t\t\twm_container_buttondown(window, event);
\t\t\treturn 1; \t/* eat event*/
\t\tcase WINDOW_TYPE_CLIENT:
\t\t\t/*
\t\t\t * BE-300 touch/stowaway use: clicking inside an FLTK/NXlib client
\t\t\t * must also move Nano-X keyboard focus. Otherwise hardware keys
\t\t\t * keep going to the last mapped/focused client, commonly nxterm.
\t\t\t */
\t\t\tGrSetFocus(window->wid);
\t\t\treturn 0;\t/* keep delivering the click to the client */
\t\tdefault:
\t\t\tDprintf(\"Unhandled button down on window %d \"
\t\t\t\t\"(type %d)\\n\", window->wid, window->type);
\t\t\tbreak;
\t}
"""
if "BE-300 touch/stowaway use" not in text:
    if old not in text:
        raise SystemExit("NanoWM client focus patch context not found")
    text = text.replace(old, new)
path.write_text(text)

path = Path("/work/microwindows/src/nanox/srvevent.c")
text = path.read_text()
helper = """\
/*
 * BE-300 touch/stowaway use: a tap inside a client should move keyboard
 * focus before the resulting click is delivered. Without this, hardware
 * keys can stay routed to the previously focused app after Dillo's URL
 * entry has accepted the touch and changed FLTK's internal focus.
 */
static void
GsFocusPointerWindowForKeyboard(void)
{
\tGR_WINDOW\t\t*wp;
\tGR_EVENT_CLIENT\t\t*ecp;

\tfor (wp = mousewp; wp; wp = wp->parent) {
\t\tif (!(wp->props & GR_WM_PROPS_NOFOCUS)) {
\t\t\tfor (ecp = wp->eventclients; ecp; ecp = ecp->next) {
\t\t\t\tif (ecp->eventmask & GR_EVENT_MASK_KEY_DOWN) {
\t\t\t\t\tfocusfixed = (wp != rootwp);
\t\t\t\t\tGsSetFocus(wp);
\t\t\t\t\treturn;
\t\t\t\t}
\t\t\t}
\t\t}

\t\tif (wp == rootwp || (wp->nopropmask & GR_EVENT_MASK_KEY_DOWN))
\t\t\treturn;
\t}
}

"""
marker = "BE-300 touch/stowaway use: a tap inside a client"
if marker not in text:
    anchor = "void GsDeliverButtonEvent(GR_EVENT_TYPE type, int buttons, int changebuttons,\n"
    if anchor not in text:
        raise SystemExit("Nano-X button focus helper anchor not found")
    text = text.replace(anchor, helper + anchor)
old = """\
\teventmask = GR_EVENTMASK(type);
\tif (eventmask == 0)
\t\treturn;

\t/*
\t * If the pointer is implicitly grabbed, then the only window
"""
new = """\
\teventmask = GR_EVENTMASK(type);
\tif (eventmask == 0)
\t\treturn;

\tif (type == GR_EVENT_TYPE_BUTTON_DOWN)
\t\tGsFocusPointerWindowForKeyboard();

\t/*
\t * If the pointer is implicitly grabbed, then the only window
"""
if "GsFocusPointerWindowForKeyboard();" not in text:
    if old not in text:
        raise SystemExit("Nano-X button focus call context not found")
    text = text.replace(old, new)
path.write_text(text)
PY
# Patch Objects.rules to register EVDEVKBD and EVDEVMOUSE driver hooks
# (idempotent — only inserts when the marker line is absent)
if ! grep -q "MOUSE.*EVDEVMOUSE" /work/microwindows/src/drivers/Objects.rules; then
    sed -i '/^# FBE mouse driver$/i\
# Linux evdev mouse driver (touchscreen via /dev/input/eventN)\
ifeq ($(MOUSE), EVDEVMOUSE)\
MW_CORE_OBJS += $(MW_DIR_OBJ)/drivers/mou_evdev.o\
endif\
' /work/microwindows/src/drivers/Objects.rules
fi
if ! grep -q "KEYBOARD.*EVDEVKBD" /work/microwindows/src/drivers/Objects.rules; then
    sed -i '/^# FBE keyboard driver$/i\
# Linux evdev keyboard driver (/dev/input/eventN, BE-300 buttons / Stowaway)\
ifeq ($(KEYBOARD), EVDEVKBD)\
MW_CORE_OBJS += $(MW_DIR_OBJ)/drivers/kbd_evdev.o\
endif\
' /work/microwindows/src/drivers/Objects.rules
fi
if ! grep -q "BE300_TOUCHSCREEN hides the software cursor" /work/microwindows/src/nanox/srvmain.c; then
    sed -i '/^	GsRedrawScreen();$/a\
#if BE300_TOUCHSCREEN\
\t/* BE300_TOUCHSCREEN hides the software cursor for touch-only input. */\
\tGdHideCursor(psd);\
#endif\
' /work/microwindows/src/nanox/srvmain.c
fi
if ! grep -q "BE300_TOUCHSCREEN keeps Nano-X cursor hidden" /work/microwindows/src/engine/devmouse.c; then
    sed -i '/^GdShowCursor(PSD psd)$/,/^{$/{
/^{$/a\
#if BE300_TOUCHSCREEN\
\t/* BE300_TOUCHSCREEN keeps Nano-X cursor hidden for absolute touch. */\
\tcurvisible = 0;\
\tcurneedsrestore = FALSE;\
\treturn 0;\
#endif
}' /work/microwindows/src/engine/devmouse.c
    sed -i '/^GdHideCursor(PSD psd)$/,/^{$/{
/^{$/a\
#if BE300_TOUCHSCREEN\
\t/* BE300_TOUCHSCREEN keeps Nano-X cursor hidden for absolute touch. */\
\tcurvisible = 0;\
\tcurneedsrestore = FALSE;\
\treturn 0;\
#endif
}' /work/microwindows/src/engine/devmouse.c
fi
python3 - <<'PY'
from pathlib import Path

path = Path("/work/microwindows/src/nanox/srvmain.c")
text = path.read_text()

old_poll_marker = """\
#if BE300_TOUCHSCREEN
\t/* BE300_TOUCHSCREEN polls evdev input even if select() misses readiness. */
\twhile (GsCheckMouseEvent())
\t\tcontinue;
\twhile (GsCheckKeyboardEvent())
\t\tcontinue;
#endif

"""
old_timeout_marker = """\
#if BE300_TOUCHSCREEN
\t/*
\t * The BE-300 evdev input nodes can miss select() wakeups under this
\t * vintage kernel/emulator combination. Keep the server loop periodic so
\t * the polling block above drains touch and keyboard events.
\t */
\tif (to == NULL || tout.tv_sec != 0 || tout.tv_usec > 10000) {
\t\tto = &tout;
\t\ttout.tv_sec = 0;
\t\ttout.tv_usec = 10000;
\t}
#endif

"""
text = text.replace(old_poll_marker, "")
text = text.replace(old_timeout_marker, "")
logged_start = "\t/* BE300 active evdev polling: drain input even if select() misses readiness. */\n\t{\n\t\tstatic int be300_poll_logged;"
logged_end = "\twhile (GsCheckKeyboardEvent())\n\t\tcontinue;\n\n"
logged_pos = text.find(logged_start)
if logged_pos >= 0:
    logged_end_pos = text.find(logged_end, logged_pos)
    if logged_end_pos >= 0:
        text = text[:logged_pos] + text[logged_end_pos + len(logged_end):]

poll_marker = """\
\t/* BE300 active evdev polling: drain input even if select() misses readiness. */
\twhile (GsCheckMouseEvent())
\t\tcontinue;
\twhile (GsCheckKeyboardEvent())
\t\tcontinue;

"""
needle = "\t/* Set up the FDs for use in the main select(): */\n"
if poll_marker not in text:
    text = text.replace(needle, poll_marker + needle, 1)

timeout_marker = """\
\t/*
\t * The BE-300 evdev input nodes can miss select() wakeups under this
\t * vintage kernel/emulator combination. Keep the server loop periodic so
\t * the polling block above drains touch and keyboard events.
\t */
\tif (to == NULL || tout.tv_sec != 0 || tout.tv_usec > 10000) {
\t\tto = &tout;
\t\ttout.tv_sec = 0;
\t\ttout.tv_usec = 10000;
\t}

"""
needle = "\tif (updatecount) --updatecount;\n\n\t/* Wait for some input on any of the fds in the set or a timeout*/\n"
if timeout_marker not in text:
    text = text.replace(needle, timeout_marker + needle, 1)

path.write_text(text)
PY
if ! grep -q "nxweb" /work/microwindows/src/demos/nanox/Makefile; then
    sed -i '/$(MW_DIR_BIN)\/nxev \\/a\
\t$(MW_DIR_BIN)/nxweb \\
' /work/microwindows/src/demos/nanox/Makefile
fi

cd /work/microwindows/src
cp Configs/config.be300 config
make clean >/dev/null 2>&1 || true
make -C demos/nanox MW_DIR_SRC=/work/microwindows/src clean >/dev/null 2>&1 || true
rm -rf /work/microwindows/src/obj /work/microwindows/src/lib /work/microwindows/src/bin
mkdir -p /work/microwindows/src/obj /work/microwindows/src/lib /work/microwindows/src/bin
MW_CC="$TARGET_CC"
MW_LDFLAGS="-Wl,--gc-sections -Wl,-s $TARGET_STATIC_LDFLAGS $TARGET_LIBC_LDFLAGS"
MW_EXTRAFLAGS="$TARGET_ARCH_CFLAGS $TARGET_LIBC_CFLAGS -DBE300_TOUCHSCREEN=1 -DFLIP_MOUSE_IN_PORTRAIT_MODE=0 -DX11_RGBTXT=\\\"/usr/share/microwindows/rgb.txt\\\""
MW_BUILD_LOG=/tmp/microwindows_be300_build.log
MW_MAKE_JOBS="${BE300_MICROWINDOWS_JOBS:-1}"
if ! make -j"$MW_MAKE_JOBS" default MIPSTOOLSPREFIX="" \
        COMPILER=gcc \
        CC="$MW_CC" \
        AR="$TARGET_AR" \
        LDFLAGS="$MW_LDFLAGS" \
        EXTRAFLAGS="$MW_EXTRAFLAGS" \
        >"$MW_BUILD_LOG" 2>&1; then
    tail -160 "$MW_BUILD_LOG"
    exit 1
fi
MW_APPS="${BE300_MICROWINDOWS_APPS:-nano-X demo-hello nxlaunch nxterm nxkbd nxweb}"
MW_NANOX_TARGETS=""
for app in $MW_APPS; do
    if [ "$app" != "nano-X" ]; then
        MW_NANOX_TARGETS="$MW_NANOX_TARGETS /work/microwindows/src/bin/$app"
    fi
done
if ! make -C demos/nanox -j"$MW_MAKE_JOBS" $MW_NANOX_TARGETS MIPSTOOLSPREFIX="" \
        MW_DIR_SRC=/work/microwindows/src \
        COMPILER=gcc \
        CC="$MW_CC" \
        AR="$TARGET_AR" \
        LDFLAGS="$MW_LDFLAGS" \
        EXTRAFLAGS="$MW_EXTRAFLAGS" \
        >>"$MW_BUILD_LOG" 2>&1; then
    tail -160 "$MW_BUILD_LOG"
    exit 1
fi
tail -3 "$MW_BUILD_LOG"
echo "--- Microwindows artifacts ---"
for app in $MW_APPS; do
    ls -la "/work/microwindows/src/bin/$app"
    be300_strip_binary "/work/microwindows/src/bin/$app"
    cp "/work/microwindows/src/bin/$app" "$ROOTFS/bin/$app"
    chmod +x "$ROOTFS/bin/$app"
done
# Stage a minimal font set so MWFONTDIR-less demos can fall back to disk if
# the built-in font picker misses.
mkdir -p "$ROOTFS/usr/share/microwindows/pcf"
for font in 6x13.pcf.gz 6x13B.pcf.gz 7x14.pcf.gz 9x15.pcf.gz cursor.pcf.gz vga.pcf.gz; do
    cp "/work/microwindows/src/fonts/pcf/$font" "$ROOTFS/usr/share/microwindows/pcf/" 2>/dev/null || true
done
cp /work/microwindows/src/fonts/rgb.txt "$ROOTFS/usr/share/microwindows/rgb.txt"

if [ "${BE300_BUILD_DILLO:-1}" != "0" ]; then
    BE300_LIBC="$BE300_LIBC" \
    BE300_TARGET_CC="$TARGET_CC" \
    BE300_TARGET_AR="$TARGET_AR" \
    BE300_TARGET_RANLIB="$TARGET_RANLIB" \
    BE300_TARGET_STRIP="$TARGET_STRIP" \
    BE300_ARCH_CFLAGS="$TARGET_ARCH_CFLAGS" \
    BE300_LIBC_CFLAGS="$TARGET_LIBC_CFLAGS" \
    BE300_LIBC_LDFLAGS="$MW_LDFLAGS" \
        /work/board/microwindows/build_dillo_rootfs.sh "$ROOTFS" "$MUSL_SPECS" "$KHDRS"
fi

cat > "$ROOTFS/etc/nxlaunch.cnf" << 'NXLAUNCH_CNF'
# BE-300 Nano-X launcher. Use '-' for iconless buttons to save rootfs space.
$window_background_colour BLACK
Terminal - /bin/mw-terminal
Browser - /bin/mw-browser
Keyboard - /bin/mw-keyboard
NXLAUNCH_CNF

cat > "$ROOTFS/bin/mw-terminal" << 'MW_TERMINAL'
#!/bin/sh
exec /bin/nxterm "$@"
MW_TERMINAL
chmod +x "$ROOTFS/bin/mw-terminal"

cat > "$ROOTFS/bin/mw-browser" << 'MW_BROWSER'
#!/bin/sh
url="${1:-}"
export HOME=/root
export DISPLAY="${DISPLAY:-:0}"
wait_for_network() {
    case "$url" in
        http://*|https://*)
            count=0
            while [ ! -s /tmp/resolv.conf ] && [ "$count" -lt 20 ]; do
                count=$((count + 1))
                /bin/sleep 1
            done
            ;;
    esac
}
if [ -x /usr/bin/dillo ] && [ "${MW_BROWSER_ENGINE:-dillo}" != "nxweb" ]; then
    if [ -n "$url" ]; then
        wait_for_network
        exec /usr/bin/dillo -g 238x300+0+0 "$url"
    fi
    exec /usr/bin/dillo -g 238x300+0+0
fi
if [ -n "$url" ]; then
    wait_for_network
    exec /bin/nxweb "$url"
fi
exec /bin/nxweb
MW_BROWSER
chmod +x "$ROOTFS/bin/mw-browser"

cat > "$ROOTFS/bin/mw-keyboard" << 'MW_KEYBOARD'
#!/bin/sh
exec /bin/nxkbd "$@"
MW_KEYBOARD
chmod +x "$ROOTFS/bin/mw-keyboard"

if [ -x "$ROOTFS/bin/nxev" ]; then
cat > "$ROOTFS/bin/mw-events" << 'MW_EVENTS'
#!/bin/sh
exec /bin/nxev "$@"
MW_EVENTS
chmod +x "$ROOTFS/bin/mw-events"
fi

if [ -x "$ROOTFS/bin/nxclock" ]; then
cat > "$ROOTFS/bin/mw-clock" << 'MW_CLOCK'
#!/bin/sh
exec /bin/nxclock "$@"
MW_CLOCK
chmod +x "$ROOTFS/bin/mw-clock"
fi

if [ -x "$ROOTFS/bin/nxcalc" ]; then
cat > "$ROOTFS/bin/mw-calc" << 'MW_CALC'
#!/bin/sh
exec /bin/nxcalc "$@"
MW_CALC
chmod +x "$ROOTFS/bin/mw-calc"
fi

cat > "$ROOTFS/bin/start-microwindows" << 'MW_START'
#!/bin/sh
export HOME=/root
export DISPLAY="${DISPLAY:-:0}"
export MWFONTDIR=/usr/share/microwindows/pcf

/bin/be300-vtmode graphics >/dev/null 2>&1 || true
printf '\033[?25l' >/dev/tty0 2>/dev/null || true
exec </dev/null >/tmp/microwindows.log 2>&1
/bin/rm -f /tmp/.nano-X

/bin/nano-X &
server_pid=$!
client_pids=

cleanup() {
    for pid in $client_pids; do
        kill "$pid" 2>/dev/null
    done
    kill "$server_pid" 2>/dev/null
    /bin/be300-vtmode text >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

wait_server() {
    count=0
    while [ ! -e /tmp/.nano-X ]; do
        kill -0 "$server_pid" 2>/dev/null || return 1
        count=$((count + 1))
        [ "$count" -lt 2000000 ] || return 1
    done
    return 0
}

if ! wait_server; then
    echo "nano-X did not create /tmp/.nano-X" >&2
    exit 1
fi

case "$1" in
terminal)
    /bin/nxterm
    ;;
browser)
    if [ "${MW_START_KEYBOARD:-0}" = "1" ]; then
        /bin/nxkbd &
        client_pids="$client_pids $!"
    fi
    if [ -n "$2" ]; then
        /bin/mw-browser "$2"
    else
        /bin/mw-browser
    fi
    ;;
keyboard)
    /bin/nxkbd
    ;;
all)
    /bin/nxkbd &
    kb_pid=$!
    client_pids="$client_pids $kb_pid"
    if [ -n "$2" ]; then
        /bin/mw-browser "$2" &
    else
        /bin/mw-browser &
    fi
    web_pid=$!
    client_pids="$client_pids $web_pid"
    /bin/nxterm &
    term_pid=$!
    client_pids="$client_pids $term_pid"
    wait "$web_pid" "$term_pid"
    kill "$kb_pid" 2>/dev/null
    ;;
launcher|"")
    while :; do
        /bin/nxlaunch /etc/nxlaunch.cnf
        echo "nxlaunch exited; restarting"
    done
    ;;
*)
    echo "usage: start-microwindows [launcher|terminal|browser [url]|keyboard|all [url]]" >&2
    exit 2
    ;;
esac
MW_START
chmod +x "$ROOTFS/bin/start-microwindows"
cd /work
elif [ "$BE300_UI" = "picogui" ]; then
echo "=== Building PicoGUI for BE-300 ==="
BE300_LIBC="$BE300_LIBC" \
BE300_TARGET_CC="$TARGET_CC" \
BE300_TARGET_CXX="$TARGET_CXX" \
BE300_TARGET_AR="$TARGET_AR" \
BE300_TARGET_RANLIB="$TARGET_RANLIB" \
BE300_TARGET_STRIP="$TARGET_STRIP" \
BE300_TARGET_CROSS_COMPILE="$TARGET_CROSS_COMPILE" \
BE300_ARCH_CFLAGS="$TARGET_ARCH_CFLAGS" \
BE300_LIBC_CFLAGS="$TARGET_LIBC_CFLAGS" \
BE300_LIBC_LDFLAGS="$TARGET_LIBC_LDFLAGS" \
    /work/board/picogui/build_picogui_rootfs.sh "$ROOTFS" "$MUSL_SPECS" "$KHDRS"

# /bin/start-picogui — heredoc'd in line with start-microwindows above so
# this script remains the canonical source for inittab launcher contents.
cat > "$ROOTFS/bin/start-picogui" << 'PG_START'
#!/bin/sh
# BE-300 PicoGUI launcher — production form.
#
# pgserver auto-launches /usr/bin/pg-demo as its `session = ...` (see
# /etc/picogui/pgserverrc).  pg-demo renders a label + tappable button.
#
# The pgserverrc's `[timers] cursorhide = 0` line is load-bearing: the
# default 5000ms cursor-hide timer schedules a SIGALRM that fires during
# net_iteration's select(), and on the BE-300 + uClibc-ng + soft-float
# MIPS build the sigreturn path SEGVs at NULL+8.  Setting cursorhide=0
# prevents the timer from arming, so SIGALRM never fires.  See the
# `patch_signals_kmsg_dump` transform in patch_picogui_sources.py for
# the diagnostic plumbing that pinned this down.
#
# If pgserver does crash (e.g. via a future regression), the
# `patch_fbdev_close_no_clear` patch in patch_picogui_sources.py keeps
# the last-rendered frame on /dev/fb0 instead of zeroing it.  This
# script then sleeps forever instead of returning, preventing inittab
# from respawning us into an OOM loop on the 16 MiB box.
#
# To recover an interactive shell, attach the serial console (--debug-uart
# in the emulator, or the real Stowaway dock) and press Enter on ttyVR0.
log() { echo "[start-picogui] $*" >/dev/kmsg 2>/dev/null; }

log "entry"
export HOME=/root
export PATH=/usr/bin:/bin:/sbin:/usr/sbin
# pgserver hardcodes the Unix socket at /var/tmp/.pgui (PG_REQUEST_SERVER
# in pg1/server/net/request.c).  Clients read PGSERVER for the path and
# strcpy(sun_path, hostname) — no `local:` prefix handling.
export PGSERVER=/var/tmp/.pgui
export PG_THEME_PATH=/usr/share/picogui/themes
export LD_LIBRARY_PATH=/usr/lib:/lib

/bin/be300-vtmode graphics >/dev/null 2>&1 || true
printf '\033[?25l' >/dev/tty0 2>/dev/null || true
/bin/mkdir -p /var/tmp
/bin/rm -f /var/tmp/.pgui

# Bring up eth0 + udhcpc so atomicnav (the picogui web browser launcher
# in /usr/share/picogui/appmenu/atomicnav.app) can resolve hostnames.
# Boot with `--ne2000 --net-mac 02:de:ad:be:ef:01` to actually have an
# ethernet device; without it the interface just won't appear and DHCP
# silently fails — atomicnav will then say "Connection failed" until
# the user types an IP-form URL.
if [ -e /sys/class/net/eth0 ]; then
    /sbin/ifconfig eth0 up >/dev/null 2>&1 || true
    /sbin/udhcpc -i eth0 -s /usr/share/udhcpc/default.script -t 3 -T 1 \
        -b -q >/dev/null 2>&1 || true
    log "eth0 up; ifconfig says: $(/sbin/ifconfig eth0 2>/dev/null | awk '/inet addr/ {print $2}')"
else
    log "eth0 not present (boot with --ne2000 to enable atomicnav)"
fi

log "launching pgserver"
/usr/bin/pgserver -c /etc/picogui/pgserverrc > /tmp/picogui.log 2>&1 &
server_pid=$!

i=0
while [ ! -S /var/tmp/.pgui ] && [ "$i" -lt 50 ]; do
    kill -0 "$server_pid" 2>/dev/null || break
    i=$((i + 1)); /bin/sleep 0.1
done
log "socket=$(test -S /var/tmp/.pgui && echo yes || echo no) after $i ticks"

# omnibar provides the launcher: Applications menu + System menu +
# clock + CPU load along the top toolbar (PG_APP_TOOLBAR).
if [ -x /usr/bin/omnibar ]; then
    /usr/bin/omnibar >/tmp/omnibar.log 2>&1 &
    log "omnibar pid=$!"
fi
# pg-desktop is a 24px primer for a known pgserver layout bug: the
# FIRST PG_APP_NORMAL registered after a toolbar-only divtree fails
# to render correctly.  It takes a thin strip at the top so that
# pterm (also PG_APP_NORMAL) becomes the second NORMAL and renders
# in the main area.
if [ -x /usr/bin/pg-desktop ]; then
    /usr/bin/pg-desktop >/tmp/pg-desktop.log 2>&1 &
    log "pg-desktop pid=$!"
fi
# pterm is the BE-300 PicoGUI terminal.  Auto-launch it as the
# primary user-facing app: from a shell prompt you can `wget URL`,
# edit files with `vi`, etc.  More reliable than atomicnav because
# it's a single TERMINAL widget instead of the layered toolbar /
# textbox / scroll widget stack atomicnav uses.
if [ -x /usr/bin/pterm ]; then
    /usr/bin/pterm >/tmp/pterm.log 2>&1 &
    log "pterm pid=$!"
fi

wait "$server_pid"
rc=$?
log "pgserver exited rc=$rc; UI frozen on framebuffer"
log "log size $(wc -c </tmp/picogui.log 2>/dev/null)"
while IFS= read -r line; do log "log: $line"; done < /tmp/picogui.log
for f in /tmp/omnibar.log /tmp/atomicnav.log /tmp/pgboard.log \
         /tmp/canvastst.log /tmp/pg-keytest.log; do
    [ -f "$f" ] || continue
    log "$(basename "$f"):"
    while IFS= read -r line; do log "  $line"; done < "$f"
done

log "sleeping; press serial Enter on ttyVR0 for a shell"
while :; do /bin/sleep 3600; done
PG_START
chmod +x "$ROOTFS/bin/start-picogui"
cd /work
elif [ "$BE300_UI" = "tinyx" ]; then
echo "=== Building TinyX (kdrive Xfbdev + matchbox + terminal) for BE-300 ==="
BE300_LIBC="$BE300_LIBC" \
BE300_TARGET_CC="$TARGET_CC" \
BE300_TARGET_CXX="$TARGET_CXX" \
BE300_TARGET_AR="$TARGET_AR" \
BE300_TARGET_RANLIB="$TARGET_RANLIB" \
BE300_TARGET_STRIP="$TARGET_STRIP" \
BE300_TARGET_CROSS_COMPILE="$TARGET_CROSS_COMPILE" \
BE300_ARCH_CFLAGS="$TARGET_ARCH_CFLAGS" \
BE300_LIBC_CFLAGS="$TARGET_LIBC_CFLAGS" \
BE300_LIBC_LDFLAGS="$TARGET_LIBC_LDFLAGS" \
    /work/board/tinyx/build_tinyx_rootfs.sh "$ROOTFS" "$MUSL_SPECS" "$KHDRS"

# A tiny login shell wrapper gives the fullscreen terminal a visible prompt
# even when BusyBox ash would otherwise inherit a minimal environment.
cat > "$ROOTFS/bin/tinyx-shell" << 'TINYX_SHELL'
#!/bin/sh
echo "[tinyx-shell] pid=$$ entered" >/dev/kmsg 2>/dev/null
echo "[tinyx-shell] tty=$(tty 2>&1) term=$TERM" >/dev/kmsg 2>/dev/null
export HOME=/root
export PS1='be300# '
export TERM=rxvt
cd /root 2>/dev/null || cd /
printf '\033[H\033[J'
echo 'BE-300 TinyX'
echo "[tinyx-shell] printf banner done, about to exec hush" >/dev/kmsg 2>/dev/null
if [ "${BE300_TINYX_CAT_TEST:-0}" = "1" ]; then
    echo 'cat test mode — type to echo back'
    exec /bin/cat
fi
# Prefer hush over ash on this profile.  Both have job control disabled
# in the BusyBox build, plus FEATURE_EDITING is off, removing the
# SIGWINCH handler that triggers the kernel signal-frame bug (task #13).
if [ -x /bin/hush ]; then
    exec /bin/hush -i
else
    exec /bin/sh +m -i
fi
TINYX_SHELL
chmod +x "$ROOTFS/bin/tinyx-shell"

# /bin/start-tinyx — heredoc'd in line with start-picogui above so this
# script remains the canonical source for inittab launcher contents.
cat > "$ROOTFS/bin/start-tinyx" << 'TINYX_START'
#!/bin/sh
# BE-300 TinyX launcher.
#
# Boots kdrive Xfbdev with evdev input, waits for the X socket, launches
# matchbox-window-manager as a single-client fullscreen WM, and respawns a
# terminal running /bin/sh. Touchscreen and Stowaway keyboard event nodes are
# pinned by device name so optional keyboards do not change the touch path.
# log: only writes to /tmp/tinyx.log by default.  In debug mode (BE300_TINYX_DEBUG=1)
# also writes to /dev/kmsg so the serial console sees boot status.  Default-off
# because the X dispatch logging patches generate a firehose; we don't want
# anything user-visible unless explicitly requested.
log() {
    echo "[start-tinyx] $*" >>/tmp/tinyx.log
    if [ "${BE300_TINYX_DEBUG:-0}" = "1" ]; then
        echo "[start-tinyx] $*" >/dev/kmsg 2>/dev/null
    fi
}

# Optional runtime config: edit /etc/tinyx.conf from the ttyVR0 serial shell to
# flip toggles like BE300_TINYX_DEBUG=1 without rebuilding the image.
if [ -f /etc/tinyx.conf ]; then
    . /etc/tinyx.conf
fi
export BE300_TINYX_DEBUG BE300_TINYX_DEBUG_INPUT BE300_TINYX_DEBUG_SIGSEGV \
       BE300_TINYX_ENABLE_TERMINAL BE300_TINYX_DISPLAY \
       BE300_FBREFRESH_MS BE300_FBREFRESH_SAMPLE \
       BE300_TINYX_CAT_TEST

SERVER_DISPLAY=:0
export DISPLAY="${BE300_TINYX_DISPLAY:-:0}"
export HOME=/root
export XDG_RUNTIME_DIR=/tmp
export PATH=/usr/bin:/bin:/sbin:/usr/sbin
export LD_LIBRARY_PATH=/usr/lib:/lib
# Force the uClibc-ng dynamic loader to resolve every GOT entry at process
# startup instead of lazily on first use.  Lazy resolution on MIPS goes
# through a PLT trampoline that, on uClibc-ng under our PIC + hidden-symbol
# mix, can leave entries pointing at 0 — producing the `pc=0` SEGV we see in
# Xfbdev's first dispatch loop iteration.
export LD_BIND_NOW=1

/bin/be300-vtmode graphics >/dev/null 2>&1 || true
printf '\033[?25l' >/dev/tty0 2>/dev/null || true
mkdir -p /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix
/bin/rm -f /tmp/.X11-unix/X0 /tmp/.X0-lock /tmp/.Xauthority \
    /tmp/Xfbdev.log /tmp/matchbox.log /tmp/tinyx-client.log \
    /tmp/be300-fbrefresh.log /tmp/tinyx-rootpaint.log \
    /tmp/tinyx-xstatus.log /tmp/tinyx-launcher.log /tmp/tinyx-osk.log \
    /tmp/be300-tinyx-osk.pid

fbrefresh_pid=""
# fbrefresh: VRC4173 display-engine poker, useful for emulator + LCD refresh
# diagnostics but eats ~270 KiB resident.  Opt-in on the 16 MiB profile to
# keep memory headroom for matchbox + rxvt.  Re-enable with
# BE300_FBREFRESH=1 in /etc/tinyx.conf when debugging framebuffer refresh.
if [ "${BE300_FBREFRESH:-0}" = "1" ] && [ -x /bin/be300-fbrefresh ]; then
    fbrefresh_ms="${BE300_FBREFRESH_MS:-100}"
    fbrefresh_sample="${BE300_FBREFRESH_SAMPLE:-128}"
    /bin/be300-fbrefresh -i "$fbrefresh_ms" -s "$fbrefresh_sample" >/dev/null 2>&1 &
    fbrefresh_pid=$!
fi

touch_event=""
button_event=""
kbd_event=""
for i in 0 1 2 3 4 5 6 7; do
    name=$(cat /sys/class/input/event${i}/device/name 2>/dev/null || echo "")
    case "$name" in
        "BE-300 Buttons")
            button_event="/dev/input/event${i}"
            ln -sf "event${i}" /dev/input/buttons0
            ;;
        "BE-300 PIU touchscreen")
            touch_event="/dev/input/event${i}"
            ln -sf "event${i}" /dev/input/touchscreen0
            ;;
        "Stowaway Keyboard")
            kbd_event="/dev/input/event${i}"
            ln -sf "event${i}" /dev/input/keyboard0
            ;;
    esac
done

# be300-tinyx: opt-in input forensics.  Set BE300_TINYX_DEBUG_INPUT=1 in
# /etc/tinyx.conf to copy raw 16-byte evdev wire records into /tmp/*.raw before
# Xfbdev opens the nodes.  Useful for splitting "kernel never emitted" from
# "X never received" when input appears broken.  Linux's evdev driver delivers
# each event to every open client, so kdrive still receives the same events;
# `cat` is used because busybox's hexdump/od/dd applets are trimmed.  After a
# tap or keypress, `ls -l /tmp/touch.raw` should show a non-zero file size
# (each event = 16 bytes on this kernel ABI).
if [ "${BE300_TINYX_DEBUG_INPUT:-0}" = "1" ]; then
    log "BE300_TINYX_DEBUG_INPUT=1: capturing raw evdev to /tmp/*.raw"
    if [ -n "$touch_event" ]; then
        cat <"$touch_event" >>/tmp/touch.raw 2>>/tmp/tinyx-debug.log &
        log "touch raw-capture pid=$!"
    fi
    if [ -n "$kbd_event" ]; then
        cat <"$kbd_event" >>/tmp/kbd.raw 2>>/tmp/tinyx-debug.log &
        log "kbd raw-capture pid=$!"
    fi
    if [ -n "$button_event" ]; then
        cat <"$button_event" >>/tmp/buttons.raw 2>>/tmp/tinyx-debug.log &
        log "buttons raw-capture pid=$!"
    fi
fi

# kdrive's evdev drivers open the named event nodes read-write and read
# EV_ABS/EV_KEY directly.  -kb disables runtime xkbcomp execution; the evdev
# keycodes map cleanly through kdrive's built-in table.  -wr makes a live
# server visually distinct from a stale all-black framebuffer while clients
# are starting.
set -- /usr/bin/Xfbdev "$SERVER_DISPLAY" -fb /dev/fb0 -ac -kb -noreset -wr -softCursor
if [ -n "$touch_event" ]; then
    set -- "$@" -mouse "evdev,,device=$touch_event,rawcoord"
else
    log "WARNING: touchscreen evdev node not found"
fi
if [ -n "$kbd_event" ]; then
    set -- "$@" -keybd "evdev,,device=$kbd_event"
else
    log "WARNING: Stowaway evdev node not found; boot with --stowaway-keyboard for host typing"
fi
if [ -n "$button_event" ]; then
    set -- "$@" -keybd "evdev,,device=$button_event"
else
    log "WARNING: BE-300 button evdev node not found"
fi

# Xfbdev stderr -> /dev/null by default — the patched X dispatch logging
# (see patch_xorg_sources.py) is extremely verbose and would either fill
# tmpfs or, if we tail it to /dev/kmsg, drown the serial console.  Set
# BE300_TINYX_DEBUG=1 to redirect to /tmp/Xfbdev.log instead.
if [ "${BE300_TINYX_DEBUG:-0}" = "1" ]; then
    "$@" </dev/null >/tmp/Xfbdev.log 2>&1 &
else
    "$@" </dev/null >/dev/null 2>&1 &
fi
xpid=$!

# 90 sec timeout; Xfbdev's first init can be slow on a 166 MHz MIPS.
i=0
while [ ! -S /tmp/.X11-unix/X0 ] && [ "$i" -lt 900 ]; do
    kill -0 "$xpid" 2>/dev/null || break
    i=$((i + 1)); /bin/sleep 0.1
done
if [ ! -S /tmp/.X11-unix/X0 ]; then
    log "Xfbdev failed to start"
    kill -KILL "$xpid" 2>/dev/null || true
    [ -n "$fbrefresh_pid" ] && kill "$fbrefresh_pid" 2>/dev/null || true
    while :; do /bin/sleep 3600; done
fi
# Create an empty .Xauthority so libX11 doesn't fail to open it
: > /tmp/.Xauthority
chmod 600 /tmp/.Xauthority
export XAUTHORITY=/tmp/.Xauthority

# matchbox WM (single-fullscreen).  Stderr -> /dev/null to keep the kernel
# log clean; set BE300_TINYX_DEBUG=1 to redirect to /tmp/matchbox.log instead.
if [ "${BE300_TINYX_DEBUG:-0}" = "1" ]; then
    /usr/bin/matchbox-window-manager \
        -theme Default -use_titlebar no -use_cursor yes \
        > /tmp/matchbox.log 2>&1 &
else
    /usr/bin/matchbox-window-manager \
        -theme Default -use_titlebar no -use_cursor yes \
        >/dev/null 2>&1 &
fi
mb_pid=$!
/bin/sleep 1
kill -0 "$mb_pid" 2>/dev/null || log "matchbox EXITED"

# be300-xstatus is the persistent visible client.  Without a mapped top-level
# the LCD collapses to matchbox's root fill; xstatus draws banner + clock +
# uptime + eth0 IP and gets respawned if it ever exits.  The terminal (when
# present) stacks above this window because matchbox always raises the most
# recent map; on terminal exit, xstatus is what the user falls back to.
xstatus_pid=""
xstatus_supervisor() {
    if [ ! -x /usr/bin/be300-xstatus ]; then
        return
    fi
    while kill -0 "$xpid" 2>/dev/null; do
        /usr/bin/be300-xstatus -display "$DISPLAY" >/dev/null 2>&1
        /bin/sleep 2
    done
}
# be300-tinyx-launcher: top dock with [Term][Stat][Kbd] buttons.  Maps as
# _NET_WM_WINDOW_TYPE_DOCK + _NET_WM_STRUT_PARTIAL so matchbox reserves the
# top 18px; the fullscreen client below fills the remaining 240x302.
# Spawned BEFORE the xstatus supervisor so matchbox computes the strut
# before deciding the fullscreen geometry of the first xstatus map.
launcher_pid=""
if [ -x /usr/bin/be300-tinyx-launcher ]; then
    /usr/bin/be300-tinyx-launcher -display "$DISPLAY" \
        >>/tmp/tinyx-launcher.log 2>&1 &
    launcher_pid=$!
    /bin/sleep 1
fi

# be300-tinyx-osk: on-screen keyboard daemon.  Costs ~1.4 MiB resident while
# idle, so on the 16 MiB profile we default to lazy launch: the dock's [Kbd]
# button spawns the OSK the first time it's tapped, then subsequent taps
# SIGUSR1-toggle it.  Re-enable eager spawn with
# BE300_TINYX_AUTOSTART_OSK=1 in /etc/tinyx.conf when memory is not a
# constraint (e.g. --sdram 64 testing).
osk_pid=""
if [ "${BE300_TINYX_AUTOSTART_OSK:-0}" = "1" ] && [ -x /usr/bin/be300-tinyx-osk ]; then
    /usr/bin/be300-tinyx-osk -display "$DISPLAY" \
        >>/tmp/tinyx-osk.log 2>&1 &
    osk_pid=$!
fi

# xstatus auto-launch costs ~1.4 MiB resident.  Default off; user taps
# [Stat] on the dock to bring it up on demand.  Re-enable with
# BE300_TINYX_AUTOSTART_XSTATUS=1 in /etc/tinyx.conf when memory is not
# the constraint (e.g. --sdram 64 testing).
if [ "${BE300_TINYX_AUTOSTART_XSTATUS:-0}" = "1" ]; then
    xstatus_supervisor &
    xstatus_pid=$!
fi

# be300-tinyx: terminal respawn (xterm/rxvt under matchbox).  Default OFF
# on the 16 MiB profile: a single rxvt costs ~720 KiB and the busybox sh
# inside it sporadically pc=0-segfaults, which triggers the respawn loop;
# the launch transient of the new rxvt pushes the system past the OOM
# threshold (matchbox needs ~540 KiB headroom for its next allocation).
# The dock's [Term] button calls launch_term() on tap which forks rxvt
# at that moment, so the user can still get a shell — they just don't
# get one automatically.  Re-enable the respawn loop with
# BE300_TINYX_ENABLE_TERMINAL=1 in /etc/tinyx.conf when memory is not
# the constraint (e.g. --sdram 64 testing).
# Single-shot terminal launch at boot when ENABLE_TERMINAL=1.  Avoids the
# respawn-loop overlap that previously pushed the 16 MiB profile into OOM
# when the shell crashed quickly.  Dock's [Term] button handles re-launch
# on demand — that path has visual confirmation the previous rxvt is dead.
if [ "${BE300_TINYX_ENABLE_TERMINAL:-0}" = "1" ]; then
    if [ -x /usr/bin/xterm ]; then
        /usr/bin/xterm -display "$DISPLAY" -geometry 40x22 -fn 6x13 \
            -bg '#d8d8d8' -fg '#000000' -cr '#0044ff' \
            -e /bin/tinyx-shell \
            >/dev/null 2>&1 &
    elif [ -x /usr/bin/rxvt ]; then
        /usr/bin/rxvt -display "$DISPLAY" -geometry 40x22 -fn 6x13 \
            -bg '#d8d8d8' -fg '#000000' -cr '#0044ff' \
            -e /bin/tinyx-shell \
            >/dev/null 2>&1 &
    fi
fi

# Wait on Xfbdev AND the launcher (if running): if the dock crashes,
# exit so init respawns start-tinyx with a fresh session.  Falls back
# to a bare Xfbdev join when the launcher is absent.
if [ -n "$launcher_pid" ]; then
    while kill -0 "$xpid" 2>/dev/null && kill -0 "$launcher_pid" 2>/dev/null; do
        /bin/sleep 5
    done
else
    while kill -0 "$xpid" 2>/dev/null; do /bin/sleep 30; done
fi

[ -n "$fbrefresh_pid" ] && kill "$fbrefresh_pid" 2>/dev/null || true
[ -n "$xstatus_pid" ] && kill "$xstatus_pid" 2>/dev/null || true
[ -n "$launcher_pid" ] && kill "$launcher_pid" 2>/dev/null || true
[ -n "$osk_pid" ]      && kill "$osk_pid"      2>/dev/null || true
while :; do /bin/sleep 3600; done
TINYX_START
chmod +x "$ROOTFS/bin/start-tinyx"

# Default /etc/tinyx.conf — enable the terminal respawn loop so the user
# lands at a hush prompt right after boot.  Edit this file from the
# serial shell on ttyVR0 to flip individual toggles without rebuilding.
mkdir -p "$ROOTFS/etc"
cat > "$ROOTFS/etc/tinyx.conf" << 'TINYX_CONF'
# BE-300 TinyX runtime config — sourced by /bin/start-tinyx.
# Each line is `VAR=value`; the file is POSIX shell.

# Respawn an rxvt terminal on top of the dock.
BE300_TINYX_ENABLE_TERMINAL=1

# Diagnostic: run /bin/cat in rxvt instead of a shell.  Used to test the
# pc=0 SEGV hypothesis.  Verified May 14, 2026: cat survives where ash and
# hush crash, confirming the bug is in shell signal handling.  Default off
# now; flip to 1 if you ever need to re-verify.
# BE300_TINYX_CAT_TEST=1

# Verbose serial-console logging.  Off by default — start-tinyx
# normally writes only to /tmp/tinyx.log (tmpfs), keeping the kernel
# log clean.  Set to 1 to also pipe log lines to /dev/kmsg and have
# Xfbdev/matchbox/rxvt stderr land in /tmp/*.log.
# BE300_TINYX_DEBUG=1

# Eager-spawn the on-screen keyboard at boot instead of waiting for the
# first [Kbd] tap.  Costs ~1.4 MiB resident; off on the 16 MiB profile.
# BE300_TINYX_AUTOSTART_OSK=1

# Auto-launch be300-xstatus at boot.  Costs ~1.4 MiB resident; off on
# the 16 MiB profile.  Tap [Stat] on the dock to bring it up on demand.
# BE300_TINYX_AUTOSTART_XSTATUS=1

# Run /bin/be300-fbrefresh to poke the VRC4173 display engine.  Off by
# default; useful when chasing emulator framebuffer refresh bugs.
# BE300_FBREFRESH=1
TINYX_CONF
chmod 0644 "$ROOTFS/etc/tinyx.conf"

cd /work
else
echo "=== Building Qt/Embedded + OPIE for BE-300 ==="
OPIE_CONFIG="$OPIE_CONFIG" \
OPIE_BUILD_STAMP="$OPIE_BUILD_STAMP" \
OPIE_PROFILE="$OPIE_PROFILE" \
OPIE_EXTRA_DEFS="$OPIE_EXTRA_DEFS" \
BE300_LIBC="$BE300_LIBC" \
BE300_TARGET_CC="$TARGET_CC" \
BE300_TARGET_CXX="$TARGET_CXX" \
BE300_TARGET_AR="$TARGET_AR" \
BE300_TARGET_RANLIB="$TARGET_RANLIB" \
BE300_TARGET_STRIP="$TARGET_STRIP" \
BE300_TARGET_CROSS_COMPILE="$TARGET_CROSS_COMPILE" \
BE300_ARCH_CFLAGS="$TARGET_ARCH_CFLAGS" \
BE300_LIBC_CFLAGS="$TARGET_LIBC_CFLAGS" \
BE300_LIBC_LDFLAGS="$TARGET_LIBC_LDFLAGS" \
    /work/board/opie/build_opie_rootfs.sh "$ROOTFS" "$MUSL_SPECS" "$KHDRS"
cd /work
fi

# Create standard busybox symlinks. We can't run ./busybox on the host
# (different arch), so use a hardcoded list of the applets we need.
for applet in sh ash hush mount umount echo cat ls ln cp mv rm mkdir rmdir \
              pwd chmod chown uname date ps kill sleep \
              dmesg true false clear printf head tail wc grep sed awk \
              mknod sync poweroff reboot halt which env test \
              ifconfig ip route arp arping ping hostname \
              nslookup udhcpc; do
    ln -sf /bin/busybox "$ROOTFS/bin/$applet"
done

# BusyBox 1.24.2's wget applet faults on this VR4131/musl build after DNS.
# Keep BusyBox for the rest of the network tools, but replace /bin/wget with a
# small static HTTP fetcher so the boot smoke test can verify TCP/HTTP.
$TARGET_CC $TARGET_ARCH_CFLAGS -Os $TARGET_STATIC_LDFLAGS \
    $TARGET_LIBC_CFLAGS $TARGET_LIBC_LDFLAGS \
    -o /tmp/be300-wget /work/board/casio-be300/be300_wget.c \
    /tmp/libgcc_helpers.o
be300_strip_binary /tmp/be300-wget
/bin/rm -f "$ROOTFS/bin/wget"
cp /tmp/be300-wget "$ROOTFS/bin/wget"
chmod +x "$ROOTFS/bin/wget"

# busybox-as-init reads /etc/inittab. The kernel mounts JFFS2 as `/` and execs
# /sbin/init.
ln -sf /bin/busybox "$ROOTFS/sbin/init"

mkdir -p "$ROOTFS/etc"
ln -sf /tmp/resolv.conf "$ROOTFS/etc/resolv.conf"

cat > "$ROOTFS/usr/share/udhcpc/default.script" << 'UDHCPC_SCRIPT'
#!/bin/sh

RESOLV_CONF=/tmp/resolv.conf

case "$1" in
deconfig)
    /bin/ifconfig "$interface" 0.0.0.0
    ;;

bound|renew)
    if [ -n "$broadcast" ]; then
        /bin/ifconfig "$interface" "$ip" netmask "$subnet" broadcast "$broadcast"
    else
        /bin/ifconfig "$interface" "$ip" netmask "$subnet"
    fi

    while /bin/route del default gw 0.0.0.0 dev "$interface" 2>/dev/null; do
        :
    done

    metric=0
    for gw in $router; do
        /bin/route add default gw "$gw" dev "$interface" metric "$metric"
        metric=$(($metric + 1))
    done

    tmp_resolv="${RESOLV_CONF}.$$"
    : > "$tmp_resolv"
    if [ -n "$domain" ]; then
        echo "search $domain" >> "$tmp_resolv"
    fi
    if [ -n "$dns" ]; then
        for ns in $dns; do
            echo "nameserver $ns" >> "$tmp_resolv"
        done
    else
        echo "nameserver 10.0.0.254" >> "$tmp_resolv"
    fi
    /bin/mv "$tmp_resolv" "$RESOLV_CONF"
    ;;
esac
UDHCPC_SCRIPT
chmod +x "$ROOTFS/usr/share/udhcpc/default.script"

cat > "$ROOTFS/bin/start-network" << 'NET_START'
#!/bin/sh

LOG=/tmp/network.log

log() {
    echo "[net] $*"
    echo "[net] $*" >>"$LOG"
    echo "[net] $*" >/dev/kmsg 2>/dev/null || true
}

: >"$LOG"
/bin/ifconfig lo 127.0.0.1 up 2>>"$LOG" || true

if [ ! -d /sys/class/net/eth0 ]; then
    log "eth0 not present; boot with --ne2000 to enable networking"
    exit 0
fi

log "bringing up eth0"
if ! /bin/ifconfig eth0 up >>"$LOG" 2>&1; then
    log "could not bring eth0 up"
    exit 0
fi

log "starting DHCP on eth0"
(
    /bin/udhcpc -i eth0 -s /usr/share/udhcpc/default.script \
        -p /tmp/udhcpc.eth0.pid -q -t 5 -T 3
    rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "[net] DHCP configured eth0" >>"$LOG"
        echo "[net] DHCP configured eth0" >/dev/kmsg 2>/dev/null || true
    else
        echo "[net] DHCP failed on eth0 rc=$rc" >>"$LOG"
        echo "[net] DHCP failed on eth0 rc=$rc" >/dev/kmsg 2>/dev/null || true
    fi
) &

exit 0
NET_START
chmod +x "$ROOTFS/bin/start-network"

cat > "$ROOTFS/bin/ne2000-net-test" << 'NET_TEST'
#!/bin/sh

log() {
    echo "[net] $*"
    echo "[net] $*" >/dev/kmsg 2>/dev/null || true
}

fail() {
    log "FAIL $*"
    exit 1
}

log "starting NE2000 DHCP/wget smoke test"
/bin/ifconfig lo 127.0.0.1 up 2>/dev/null || true

[ -d /sys/class/net/eth0 ] || fail "eth0 not present; boot with --ne2000"

log "bringing up eth0"
/bin/ifconfig eth0 up || fail "could not bring eth0 up"

log "requesting DHCP lease on eth0"
/bin/udhcpc -i eth0 -s /usr/share/udhcpc/default.script \
    -p /tmp/udhcpc.eth0.pid -q -n -t 5 -T 3 || fail "DHCP lease failed"

log "eth0 configuration"
/bin/ifconfig eth0 || true
/bin/route -n || true
[ -f /etc/resolv.conf ] && /bin/cat /etc/resolv.conf

log "checking DNS"
/bin/nslookup google.com || fail "nslookup google.com failed"

log "fetching google.com"
/bin/rm -f /tmp/google.html
/bin/wget -T 30 -O /tmp/google.html google.com || fail "wget google.com failed"
[ -s /tmp/google.html ] || fail "wget google.com produced an empty file"

log "PASS wget google.com"
NET_TEST
chmod +x "$ROOTFS/bin/ne2000-net-test"

if [ "$BE300_UI" = "opie" ] || [ "$BE300_UI" = "opie64" ]; then
cat > "$ROOTFS/etc/inittab" << 'INITTAB'
::sysinit:/bin/mount -t proc proc /proc
::sysinit:/bin/mount -t sysfs sysfs /sys
::sysinit:/bin/mkdir -p /dev/pts
::sysinit:/bin/mount -t devpts devpts /dev/pts
::sysinit:/bin/mount -t tmpfs tmpfs /tmp
::sysinit:/bin/mount -t tmpfs -o size=768k tmpfs /root
::sysinit:/bin/mkdir -p /root/Settings /root/Applications /root/Documents
::sysinit:/bin/echo "=== Casio BE-300 Linux 4.2.9 (BusyBox + OPIE) ==="
::sysinit:/bin/echo "  OPIE on tty0; serial shell: ttyVR0 (--serial0-bridge) or ttyS0 (--serial1-bridge)."
::sysinit:/bin/start-network
tty0::once:/bin/start-opie
ttyVR0::askfirst:/bin/sh
ttyS0::askfirst:/bin/sh
::ctrlaltdel:/bin/umount -a -r
::shutdown:/bin/umount -a -r
INITTAB
elif [ "$BE300_UI" = "picogui" ]; then
cat > "$ROOTFS/etc/inittab" << 'INITTAB'
::sysinit:/bin/mount -t proc proc /proc
::sysinit:/bin/mount -t sysfs sysfs /sys
::sysinit:/bin/mount -o remount,rw /
::sysinit:/bin/mkdir -p /dev/pts
::sysinit:/bin/mount -t devpts devpts /dev/pts
::sysinit:/bin/mount -t tmpfs tmpfs /tmp
::sysinit:/bin/mkdir -p /var/tmp
::sysinit:/bin/echo "=== Casio BE-300 Linux 4.2.9 (BusyBox + PicoGUI) ==="
::sysinit:/bin/echo "  PicoGUI on tty0; serial shell: ttyVR0 (--serial0-bridge) or ttyS0 (--serial1-bridge)."
::sysinit:/bin/start-network
tty0::respawn:/bin/start-picogui
ttyVR0::askfirst:/bin/sh
ttyS0::askfirst:/bin/sh
::ctrlaltdel:/bin/umount -a -r
::shutdown:/bin/umount -a -r
INITTAB
elif [ "$BE300_UI" = "tinyx" ]; then
cat > "$ROOTFS/etc/inittab" << 'INITTAB'
::sysinit:/bin/mount -t proc proc /proc
::sysinit:/bin/mount -t sysfs sysfs /sys
::sysinit:/bin/mount -o remount,rw /
::sysinit:/bin/mkdir -p /dev/pts
::sysinit:/bin/mount -t devpts devpts /dev/pts
::sysinit:/bin/mount -t tmpfs tmpfs /tmp
::sysinit:/bin/mkdir -p /tmp/.X11-unix
::sysinit:/bin/chmod 1777 /tmp/.X11-unix
::sysinit:/bin/echo "=== Casio BE-300 Linux 4.2.9 (BusyBox + TinyX) ==="
::sysinit:/bin/echo "  Xfbdev + matchbox on tty0; serial shell: ttyVR0 (--serial0-bridge) or ttyS0 (--serial1-bridge)."
::sysinit:/bin/start-network
tty0::respawn:/bin/start-tinyx
ttyVR0::askfirst:/bin/sh
ttyS0::askfirst:/bin/sh
::ctrlaltdel:/bin/umount -a -r
::shutdown:/bin/umount -a -r
INITTAB
else
cat > "$ROOTFS/etc/inittab" << 'INITTAB'
::sysinit:/bin/mount -t proc proc /proc
::sysinit:/bin/mount -t sysfs sysfs /sys
::sysinit:/bin/mount -o remount,rw /
::sysinit:/bin/mkdir -p /dev/pts
::sysinit:/bin/mount -t devpts devpts /dev/pts
::sysinit:/bin/mount -t tmpfs tmpfs /tmp
::sysinit:/bin/echo "=== Casio BE-300 Linux 4.2.9 (BusyBox + Nano-X) ==="
::sysinit:/bin/echo "  Microwindows on tty0; serial shell: ttyVR0 (--serial0-bridge) or ttyS0 (--serial1-bridge)."
::sysinit:/bin/start-network
tty0::respawn:/bin/start-microwindows
ttyVR0::askfirst:/bin/sh
ttyS0::askfirst:/bin/sh
::ctrlaltdel:/bin/umount -a -r
::shutdown:/bin/umount -a -r
INITTAB
fi

ROOTFS_BAD_INSN="$(check_rootfs_mips2)"
if [ -n "$ROOTFS_BAD_INSN" ]; then
	echo "ERROR: rootfs contains unsupported VR4131 instructions:" >&2
	echo "$ROOTFS_BAD_INSN" >&2
	exit 1
fi

# The kernel boots straight off the JFFS2 rootfs in NAND mtd3 — no embedded
# initramfs. Clean up artifacts from older runs that did build one.
rm -rf /work/initramfs_be300 /work/initramfs_list.txt

cd /work

# Keep the old ramdisk init approach commented out for reference.
# To revert, replace the above with the ramdisk_init.S approach.
if false; then
cat > /dev/null << 'INITASM_DISABLED'
	.set noreorder
	.text
	.globl __start
	.type __start, @function

#define __NR_read       4003
#define __NR_write      4004
#define __NR_open       4005
#define __NR_close      4006
#define __NR_mount      4021
#define __NR_mkdir      4039
#define __NR_chdir      4012
#define __NR_pivot_root 4216
#define __NR_chroot     4061
#define __NR_execve     4011
#define __NR_pause      4029
#define __NR_dup        4041

__start:
	/* Print banner */
	li	$v0, __NR_write
	li	$a0, 1
	la	$a1, msg_banner
	li	$a2, msg_banner_len
	syscall
	nop

	/* mount devtmpfs on /dev */
	li	$v0, __NR_mount
	la	$a0, s_devtmpfs
	la	$a1, s_dev
	la	$a2, s_devtmpfs
	li	$a3, 0
	addiu	$sp, $sp, -16
	sw	$zero, 16($sp)
	syscall
	nop
	addiu	$sp, $sp, 16

	/* Print B */
	li	$v0, __NR_write
	li	$a0, 1
	la	$a1, msg_b
	li	$a2, 2
	syscall
	nop

	/* open /ramdisk.gz */
	li	$v0, __NR_open
	la	$a0, s_ramdisk_gz
	li	$a1, 0		/* O_RDONLY */
	syscall
	nop
	move	$s0, $v0
	bltz	$s0, err1
	nop

	/* Print C */
	li	$v0, __NR_write
	li	$a0, 1
	la	$a1, msg_c
	li	$a2, 2
	syscall
	nop

	/* open /dev/ram0 */
	li	$v0, __NR_open
	la	$a0, s_ram0
	li	$a1, 1		/* O_WRONLY */
	syscall
	nop
	move	$s1, $v0
	bltz	$s1, err2
	nop

	/* Print D */
	li	$v0, __NR_write
	li	$a0, 1
	la	$a1, msg_d
	li	$a2, 2
	syscall
	nop

	/* Copy loop: ramdisk.gz -> /dev/ram0 */
	addiu	$sp, $sp, -512
	move	$s2, $sp
copy_loop:
	li	$v0, __NR_read
	move	$a0, $s0
	move	$a1, $s2
	li	$a2, 512
	syscall
	nop
	move	$s3, $v0
	blez	$s3, copy_done
	nop

	li	$v0, __NR_write
	move	$a0, $s1
	move	$a1, $s2
	move	$a2, $s3
	syscall
	nop
	b	copy_loop
	nop

copy_done:
	li	$v0, __NR_close
	move	$a0, $s0
	syscall
	nop
	li	$v0, __NR_close
	move	$a0, $s1
	syscall
	nop

	/* Print E */
	li	$v0, __NR_write
	li	$a0, 1
	la	$a1, msg_e
	li	$a2, 2
	syscall
	nop

	/* mkdir /mnt */
	li	$v0, __NR_mkdir
	la	$a0, s_mnt
	li	$a1, 0755
	syscall
	nop

	/* mount /dev/ram0 as ext2 on /mnt */
	li	$v0, __NR_mount
	la	$a0, s_ram0
	la	$a1, s_mnt
	la	$a2, s_ext2
	li	$a3, 0
	addiu	$sp, $sp, -16
	sw	$zero, 16($sp)
	syscall
	nop
	addiu	$sp, $sp, 16
	bnez	$v0, err3
	nop

	/* Print F */
	li	$v0, __NR_write
	li	$a0, 1
	la	$a1, msg_f
	li	$a2, 2
	syscall
	nop

	/* chdir /mnt, pivot_root, chroot */
	li	$v0, __NR_chdir
	la	$a0, s_mnt
	syscall
	nop

	li	$v0, __NR_mkdir
	la	$a0, s_oldroot
	li	$a1, 0755
	syscall
	nop

	li	$v0, __NR_pivot_root
	la	$a0, s_dot
	la	$a1, s_oldroot
	syscall
	nop

	li	$v0, __NR_chroot
	la	$a0, s_dot
	syscall
	nop

	/* Print G */
	li	$v0, __NR_write
	li	$a0, 1
	la	$a1, msg_g
	li	$a2, 2
	syscall
	nop

	/* Reopen console in new root */
	li	$v0, __NR_close
	li	$a0, 0
	syscall
	nop
	li	$v0, __NR_close
	li	$a0, 1
	syscall
	nop
	li	$v0, __NR_close
	li	$a0, 2
	syscall
	nop
	li	$v0, __NR_open
	la	$a0, s_dev_console
	li	$a1, 2		/* O_RDWR */
	syscall
	nop
	li	$v0, __NR_dup
	li	$a0, 0
	syscall
	nop
	li	$v0, __NR_dup
	li	$a0, 0
	syscall
	nop

	/* Print H + newline */
	li	$v0, __NR_write
	li	$a0, 1
	la	$a1, msg_h
	li	$a2, 3
	syscall
	nop

	/* exec /sbin/init */
	li	$v0, __NR_execve
	la	$a0, s_sbin_init
	la	$a1, argv_init
	li	$a2, 0
	syscall
	nop

	/* exec /bin/sh fallback */
	li	$v0, __NR_execve
	la	$a0, s_bin_sh
	la	$a1, argv_sh
	li	$a2, 0
	syscall
	nop

	/* Print X = exec failed */
	li	$v0, __NR_write
	li	$a0, 1
	la	$a1, msg_x
	li	$a2, 3
	syscall
	nop
	b	hang
	nop

err1:
	li	$v0, __NR_write
	li	$a0, 1
	la	$a1, msg_e1
	li	$a2, msg_e1_len
	syscall
	nop
	b	hang
	nop

err2:
	li	$v0, __NR_write
	li	$a0, 1
	la	$a1, msg_e2
	li	$a2, msg_e2_len
	syscall
	nop
	b	hang
	nop

err3:
	li	$v0, __NR_write
	li	$a0, 1
	la	$a1, msg_e3
	li	$a2, msg_e3_len
	syscall
	nop
	b	hang
	nop

hang:
1:	li	$v0, __NR_pause
	syscall
	nop
	b	1b
	nop

	.data
	.align 2
msg_banner:	.ascii "\n=== BE-300 Linux 4.2.9 ===\nInit: "
msg_banner_len = . - msg_banner
msg_b:	.ascii "B "
msg_c:	.ascii "C "
msg_d:	.ascii "D "
msg_e:	.ascii "E "
msg_f:	.ascii "F "
msg_g:	.ascii "G "
msg_h:	.ascii "H\n"
msg_x:	.ascii "X\n"
msg_e1:	.ascii "ERR: open ramdisk.gz\n"
msg_e1_len = . - msg_e1
msg_e2:	.ascii "ERR: open /dev/ram0\n"
msg_e2_len = . - msg_e2
msg_e3:	.ascii "ERR: mount ext2 (expected)\n"
msg_e3_len = . - msg_e3
s_devtmpfs:	.asciz "devtmpfs"
s_dev:		.asciz "/dev"
s_dev_console:	.asciz "/dev/console"
s_ramdisk_gz:	.asciz "/ramdisk.gz"
s_ram0:		.asciz "/dev/ram0"
s_mnt:		.asciz "/mnt"
s_oldroot:	.asciz "oldroot"
s_dot:		.asciz "."
s_ext2:		.asciz "ext2"
s_sbin_init:	.asciz "/sbin/init"
s_bin_sh:	.asciz "/bin/sh"
s_proc:		.asciz "/proc"
s_procfs:	.asciz "proc"
	.align 2
argv_init:	.word s_sbin_init, 0
argv_sh:	.word s_bin_sh, 0

	/* no BSS - use stack for copy buffer */
INITASM_DISABLED
fi
# End of disabled ramdisk init approach

###############################################################################
# BE300_ROOTFS_ONLY=1 short-circuit: leave the populated $ROOTFS in place and
# stop before Phase 2 (kernel build). Used by build_be300_2_4_kernel.sh to
# borrow the BusyBox + GUI rootfs pipeline without rebuilding the 4.2.9
# kernel — the 2.4.18 path supplies its own vmlinux and packs its own NAND.
###############################################################################
if [ "${BE300_ROOTFS_ONLY:-0}" = "1" ]; then
    echo "=== BE300_ROOTFS_ONLY=1: rootfs ready at ${ROOTFS}; skipping 4.2.9 kernel build ==="
    exit 0
fi

###############################################################################
# Phase 2: Download and extract kernel
###############################################################################

echo "=== Phase 2: Preparing kernel source ==="

echo "--- Downloading kernel source ---"
if [ ! -f linux-4.2.9-patched.tar.xz ]; then
    wget "$KERNEL_SOURCE_URL"
fi

echo "--- Extracting kernel (clean) ---"
rm -rf linux-4.2.9
tar xf linux-4.2.9-patched.tar.xz

cd linux-4.2.9

###############################################################################
# Phase 3: Apply BE-300 kernel patch series
###############################################################################

echo "=== Phase 3: Applying BE-300 kernel patch series ==="
/work/scripts/apply_patch_series.sh "$KERNEL_PATCH_SERIES" /work/linux-4.2.9
cp "$KERNEL_DEFCONFIG" /work/linux-4.2.9/arch/mips/configs/be300_defconfig
cp /work/board/casio-be300/setup.c \
   /work/linux-4.2.9/arch/mips/vr41xx/casio-be300/setup.c
cp /work/board/casio-be300/touch_be300.c \
   /work/linux-4.2.9/arch/mips/vr41xx/casio-be300/touch_be300.c
cp /work/board/casio-be300/logo_linux4be_clut224.ppm \
   /work/linux-4.2.9/drivers/video/logo/logo_linux4be_clut224.ppm

###############################################################################
# Phase 5: Configure kernel
###############################################################################

echo "=== Phase 5: Configuring kernel ==="

# Generate .config
make ARCH=mips CROSS_COMPILE=mipsel-linux-gnu- be300_defconfig

for fragment in $KERNEL_CONFIG_FRAGMENTS; do
    if [ ! -f "$fragment" ]; then
        echo "ERROR: kernel config fragment not found: $fragment" >&2
        exit 1
    fi
    ./scripts/kconfig/merge_config.sh -m .config "$fragment"
done

# Resolve any missing options
make ARCH=mips CROSS_COMPILE=mipsel-linux-gnu- olddefconfig

if [ "${BE300_LOW_RAM_KERNEL:-1}" = "1" ]; then
    ./scripts/config \
        --disable AIO \
        --disable EPOLL \
        --disable SIGNALFD \
        --disable TIMERFD \
        --disable EVENTFD \
        --disable SECCOMP \
        --disable SECCOMP_FILTER \
        --disable ELF_CORE \
        --disable CORE_DUMP_DEFAULT_ELF_HEADERS \
        --disable VM_EVENT_COUNTERS \
        --disable SYSFS_SYSCALL \
        --disable SLABINFO \
        --disable INET_XFRM_MODE_TRANSPORT \
        --disable INET_XFRM_MODE_TUNNEL \
        --disable INET_XFRM_MODE_BEET \
        --disable XFRM \
        --disable HW_RANDOM \
        --disable BLK_DEV_BSG \
        --disable LBDAF \
        --disable UEVENT_HELPER \
        --set-str UEVENT_HELPER_PATH ""
fi

# cfb helpers are now selected by CASIO_BE300 in Kconfig

###############################################################################
# Phase 6: Build kernel
###############################################################################

echo "=== Phase 6: Building kernel ==="

# Using -j1 to avoid "Too many open files" in constrained environments
make ARCH=mips CROSS_COMPILE=mipsel-linux-gnu- vmlinux -j1 || true

if [ -f vmlinux ]; then
    echo "=== SUCCESS: vmlinux created ==="
    ls -l vmlinux
else
    echo "=== FAILURE: vmlinux NOT created ==="
    exit 1
fi

###############################################################################
# Phase 7: Build the stage-1 SPL and pack it together with the kernel into a
# NAND image bootable through `./bin/be300 --nand`.
#
# The boot ROM's record walker is sized for a small SPL (empirical limit
# around 352 KB of NAND traffic per run), so we don't try to package a 3 MB
# kernel as a single B000FF container. Instead:
#   - Stage-1 SPL (board/casio-be300/spl.c + spl_start.S, linked at
#     0x80F00000) is wrapped as the B000FF container at NAND offset 0x4000
#     and is what the boot ROM actually loads.
#   - The kernel is laid out raw at NAND offset 0x14000 (partition 2). The
#     SPL reads it page-by-page via the VRC4173 SPL transfer engine and
#     jumps to kernel_entry.
###############################################################################

echo ""
echo "=== Phase 7: Building stage-1 SPL ==="

cd /work/board/casio-be300
SPL_DIR=/work/linux-4.2.9/spl_build
mkdir -p "$SPL_DIR"

# Extract kernel constants from vmlinux for the SPL to embed.
python3 - <<'PYEOF' >"$SPL_DIR/kernel_consts.txt"
import struct, sys
data = open('/work/linux-4.2.9/vmlinux','rb').read()
e_entry = struct.unpack_from('<I', data, 24)[0]
e_phoff = struct.unpack_from('<I', data, 28)[0]
e_phnum = struct.unpack_from('<H', data, 44)[0]
loads = []
for i in range(e_phnum):
    o = e_phoff + i*32
    p_type, p_offset, p_vaddr, p_paddr, p_filesz, *_ = struct.unpack_from("<IIIIIIII", data, o)
    if p_type == 1 and p_filesz:
        loads.append((p_vaddr, p_filesz))
base = min(a for a, _ in loads)
end = max(a + s for a, s in loads)
print(f"KERNEL_LOAD_VA=0x{base:08X}")
print(f"KERNEL_ENTRY_VA=0x{e_entry:08X}")
print(f"KERNEL_SIZE=0x{end - base:X}")
PYEOF

# shellcheck disable=SC1091
. "$SPL_DIR/kernel_consts.txt"

echo "  KERNEL_LOAD_VA=$KERNEL_LOAD_VA"
echo "  KERNEL_ENTRY_VA=$KERNEL_ENTRY_VA"
echo "  KERNEL_SIZE=$KERNEL_SIZE"

CC=mipsel-linux-gnu-gcc
LD=mipsel-linux-gnu-ld
SPL_CFLAGS="-march=mips2 -mabi=32 -mno-abicalls -fno-pic -nostdlib \
    -fno-builtin -ffreestanding -Os -g -fno-stack-protector \
    -DKERNEL_LOAD_VA=${KERNEL_LOAD_VA}u \
    -DKERNEL_ENTRY_VA=${KERNEL_ENTRY_VA}u \
    -DKERNEL_SIZE=${KERNEL_SIZE}u"

$CC $SPL_CFLAGS -c -o "$SPL_DIR/spl_start.o" /work/board/casio-be300/spl_start.S
$CC $SPL_CFLAGS -c -o "$SPL_DIR/spl.o"      /work/board/casio-be300/spl.c
$LD -m elf32ltsmip -T /work/board/casio-be300/spl.lds \
    -o "$SPL_DIR/spl.elf" "$SPL_DIR/spl_start.o" "$SPL_DIR/spl.o"

ls -l "$SPL_DIR/spl.elf"

cd /work

echo ""
echo "=== Phase 7b: Building JFFS2 rootfs image ==="
# mtd3 is 0xB00000 bytes (11 MiB) starting at NAND offset 0x500000.
# NAND geometry: 32 pages × 512 B = 16 KiB erase block; 512 B page.
# --no-cleanmarkers is the right call for NAND (mtd's NAND wbuf path
# regenerates them at runtime). --little-endian matches the kernel.
ROOTFS_JFFS2="/work/linux-4.2.9/${ROOTFS_JFFS2_NAME}"
mkfs.jffs2 \
    --root="$ROOTFS" \
    --output="$ROOTFS_JFFS2" \
    --eraseblock=16384 \
    --pagesize=512 \
    --no-cleanmarkers \
    --pad=0xB00000 \
    --little-endian
ls -l "$ROOTFS_JFFS2"

echo ""
echo "=== Phase 7c: Packing NAND image ==="

python3 /work/tools/mk_be300_nand.py \
    --vmlinux /work/linux-4.2.9/vmlinux \
    --spl "$SPL_DIR/spl.elf" \
    --rootfs "$ROOTFS_JFFS2" \
    --out "/work/linux-4.2.9/${NAND_IMAGE_NAME}"

ls -l "/work/linux-4.2.9/${NAND_IMAGE_NAME}"
echo ""
echo "Test with:"
if [ "$BE300_UI" = "opie64" ]; then
    echo "  ./bin/be300 --sdram 64 --nand linux-4.2.9/${NAND_IMAGE_NAME} --speed 0"
    echo "  ./bin/be300 --sdram 64 --nand linux-4.2.9/${NAND_IMAGE_NAME} --ne2000 --net-mac 02:de:ad:be:ef:01"
    echo "  ./bin/be300 --restore --cf linux-4.2.9/linux_cf.img --speed 0  # after ./build_be300_cf_image.sh"
elif [ "$BE300_UI" = "picogui" ]; then
    echo "  ./bin/be300 --nand linux-4.2.9/${NAND_IMAGE_NAME} --speed 0 --detect-stall"
    echo "  ./bin/be300 --nand linux-4.2.9/${NAND_IMAGE_NAME} --ne2000 --net-mac 02:de:ad:be:ef:01"
elif [ "$BE300_UI" = "tinyx" ]; then
    echo "  ./bin/be300 --sdram 64 --nand linux-4.2.9/${NAND_IMAGE_NAME} --speed 0 --detect-stall --stowaway-keyboard"
    echo "  ./bin/be300 --sdram 64 --nand linux-4.2.9/${NAND_IMAGE_NAME} --ne2000 --net-mac 02:de:ad:be:ef:01 --stowaway-keyboard"
else
    echo "  ./bin/be300 --nand linux-4.2.9/${NAND_IMAGE_NAME}"
    echo "  ./bin/be300 --nand linux-4.2.9/${NAND_IMAGE_NAME} --ne2000 --net-mac 02:de:ad:be:ef:01"
    echo "  ./bin/be300 --restore --cf linux-4.2.9/linux_cf.img --speed 0  # after ./build_be300_cf_image.sh"
fi
