#!/bin/bash
set -e

ROOTFS="${1:?rootfs path required}"
MUSL_SPECS="${2:?musl specs path required}"
KHDRS="${3:?kernel headers path required}"

FLTK_VERSION="1.3.8"
DILLO_VERSION="3.2.0"
ARCHIVES="/work/archives"
FLTK_ARCHIVE="$ARCHIVES/fltk-${FLTK_VERSION}-source.tar.gz"
DILLO_ARCHIVE="$ARCHIVES/dillo-${DILLO_VERSION}.tar.gz"
FLTK_URL="https://www.fltk.org/pub/fltk/${FLTK_VERSION}/fltk-${FLTK_VERSION}-source.tar.gz"
DILLO_URL="https://github.com/dillo-browser/dillo/releases/download/v${DILLO_VERSION}/dillo-${DILLO_VERSION}.tar.gz"
FLTK_SRC="/work/fltk-${FLTK_VERSION}-be300"
DILLO_SRC="/work/dillo-${DILLO_VERSION}-be300"
BE300_LIBS="/tmp/be300-dillo-libs"
LOG_DIR="/work/build-dillo"
FLTK_BUILD_LOG="$LOG_DIR/be300_fltk_build.log"
DILLO_BUILD_LOG="$LOG_DIR/be300_dillo_build.log"
BE300_LIBC="${BE300_LIBC:-musl}"
DILLO_BUILD_STAMP="${BE300_DILLO_BUILD_STAMP:-.be300-dillo-built-v10-${BE300_LIBC}}"
DILLO_MAX_PAGE_BYTES="${BE300_DILLO_MAX_PAGE_BYTES:-524288}"
DILLO_MAX_INIT_BUF_BYTES="${BE300_DILLO_MAX_INIT_BUF_BYTES:-65536}"
DILLO_IOBUF_BYTES="${BE300_DILLO_IOBUF_BYTES:-2048}"
DILLO_MAX_IMAGE_PIXELS="${BE300_DILLO_MAX_IMAGE_PIXELS:-76800}"

CROSS="mipsel-linux-gnu-"
TARGET_CC="${BE300_TARGET_CC:-${CROSS}gcc}"
TARGET_AR="${BE300_TARGET_AR:-${CROSS}ar}"
TARGET_RANLIB="${BE300_TARGET_RANLIB:-${CROSS}ranlib}"
TARGET_STRIP="${BE300_TARGET_STRIP:-${CROSS}strip}"
CONFIG_CC="${BE300_CONFIG_CC:-${CROSS}gcc}"
CONFIG_CXX="${BE300_CONFIG_CXX:-${CROSS}g++}"
NX11_CFLAGS="-I/work/microwindows/src/nx11/X11-local"
DILLO_LOW_MEM_DEFS="-DBE300_DILLO_LOW_MEMORY=1 -DBE300_DILLO_NO_SPLASH_CACHE=1 -DBE300_DILLO_STOWAWAY_URL_KEYS=1 -DBE300_DILLO_DNS_NUMERIC_SERVICE=1 -DBE300_DILLO_HUGE_FILESIZE=${DILLO_MAX_PAGE_BYTES} -DBE300_DILLO_MAX_INIT_BUF=${DILLO_MAX_INIT_BUF_BYTES} -DBE300_DILLO_IOBUF_LEN=${DILLO_IOBUF_BYTES} -DBE300_DILLO_IMAGE_MAX_AREA=${DILLO_MAX_IMAGE_PIXELS}"
DEFAULT_LIBC_CFLAGS="-specs ${MUSL_SPECS} -isystem ${KHDRS}/include -B/tmp/libgcc_patched -L/tmp/libgcc_patched"
DEFAULT_LIBC_LDFLAGS="-static -Wl,--gc-sections -Wl,-s -B/tmp/libgcc_patched -L/tmp/libgcc_patched"
LIBC_CFLAGS="${BE300_LIBC_CFLAGS:-$DEFAULT_LIBC_CFLAGS}"
LIBC_LDFLAGS="${BE300_LIBC_LDFLAGS:-$DEFAULT_LIBC_LDFLAGS}"
ARCH_CFLAGS="${BE300_ARCH_CFLAGS:--march=mips2 -mfpxx}"
COMMON_CFLAGS="${ARCH_CFLAGS} -Os -fomit-frame-pointer -ffunction-sections -fdata-sections -fno-unwind-tables -fno-asynchronous-unwind-tables -DNDEBUG ${DILLO_LOW_MEM_DEFS} ${LIBC_CFLAGS} -I${BE300_LIBS}/include ${NX11_CFLAGS}"
COMMON_CXXFLAGS="${COMMON_CFLAGS} -nostdinc++ -std=gnu++98 -fno-exceptions -fno-rtti -fno-threadsafe-statics -fpermissive -Wno-write-strings"
COMMON_LDFLAGS="${LIBC_LDFLAGS} -L${BE300_LIBS}/lib"
COMMON_LIBS="-lbe300cxx -lbe300gcc"

# Configure scripts from these desktop projects probe the C++ standard library.
# The final BE-300 binaries do not use libstdc++; configure with the glibc
# cross environment, then rebuild with the selected target-libc flags above.
CONFIG_CFLAGS="-march=mips2 -mfpxx -Os -fomit-frame-pointer -I${BE300_LIBS}/include ${NX11_CFLAGS}"
CONFIG_CXXFLAGS="-march=mips2 -mfpxx -Os -fomit-frame-pointer -fpermissive -Wno-write-strings -I${BE300_LIBS}/include ${NX11_CFLAGS}"
CONFIG_LDFLAGS="-L${BE300_LIBS}/lib -L/work/microwindows/src/lib"

mkdir -p "$LOG_DIR"

unsupported_mips2_insn() {
	mipsel-linux-gnu-objdump -d "$1" 2>/dev/null \
		| awk '$3 ~ /^(mul|clz|clo|ext|ins|movf|movn|movt|movz|pref|seb|seh|wsbh|rdhwr)$/ {print; exit}' || true
}

check_target_mips2() {
	local file="$1"
	local bad

	bad="$(unsupported_mips2_insn "$file")"
	if [ -n "$bad" ]; then
		echo "ERROR: $file contains unsupported VR4131 instruction:" >&2
		echo "$bad" >&2
		exit 1
	fi
}

make_generated_tree_writable() {
	local path

	for path in "$@"; do
		if [ -d "$path" ]; then
			chmod -R a+rwX "$path" 2>/dev/null || true
		fi
	done
}

download_archive() {
	local url="$1"
	local out="$2"

	mkdir -p "$ARCHIVES"
	if [ ! -s "$out" ]; then
		echo "--- Downloading $(basename "$out") ---"
		if command -v curl >/dev/null 2>&1; then
			curl -L --fail "$url" -o "$out"
		else
			wget "$url" -O "$out"
		fi
	fi
}

prepare_support_libs() {
	echo "=== Building BE-300 Dillo support libraries ==="
	rm -rf "$BE300_LIBS"
	mkdir -p "$BE300_LIBS/include/X11" "$BE300_LIBS/lib"

	cat >"$BE300_LIBS/include/X11/Xmd.h" <<'XMD_H'
#ifndef XMD_H
#define XMD_H

#include <stdint.h>

typedef int8_t INT8;
typedef int16_t INT16;
typedef int32_t INT32;
typedef uint8_t CARD8;
typedef uint16_t CARD16;
typedef uint32_t CARD32;
typedef uint64_t CARD64;
typedef uint8_t BYTE;

#ifndef B16
#define B16
#endif
#ifndef B32
#define B32
#endif

#endif
XMD_H

	cat >"$BE300_LIBS/include/X11/cursorfont.h" <<'CURSORFONT_H'
#ifndef _X11_CURSORFONT_H_
#define _X11_CURSORFONT_H_

#define XC_bottom_left_corner 12
#define XC_bottom_right_corner 14
#define XC_bottom_side 16
#define XC_fleur 52
#define XC_hand2 60
#define XC_left_ptr 68
#define XC_left_side 70
#define XC_question_arrow 92
#define XC_right_side 96
#define XC_sb_h_double_arrow 108
#define XC_sb_v_double_arrow 116
#define XC_tcross 130
#define XC_top_left_corner 134
#define XC_top_right_corner 136
#define XC_top_side 138
#define XC_watch 150
#define XC_xterm 152

#endif
CURSORFONT_H

	${TARGET_CC} $COMMON_CFLAGS -fPIC -c \
		/work/board/opie/be300_cxx_abi.c -o /tmp/be300_dillo_cxx_abi.o
	${TARGET_AR} rcs "$BE300_LIBS/lib/libbe300cxx.a" /tmp/be300_dillo_cxx_abi.o
}

prepare_sources() {
	download_archive "$FLTK_URL" "$FLTK_ARCHIVE"
	download_archive "$DILLO_URL" "$DILLO_ARCHIVE"
	make_generated_tree_writable "$FLTK_SRC" "$DILLO_SRC"

	if [ -d "$FLTK_SRC" ] && [ ! -x "$FLTK_SRC/configure" ]; then
		echo "=== Re-extracting incomplete FLTK ${FLTK_VERSION} tree ==="
		rm -rf "$FLTK_SRC"
	fi

	if [ ! -d "$FLTK_SRC" ]; then
		echo "=== Extracting FLTK ${FLTK_VERSION} for BE-300 ==="
		rm -rf "$FLTK_SRC"
		tar xzf "$FLTK_ARCHIVE" -C /work
		mv "/work/fltk-${FLTK_VERSION}" "$FLTK_SRC"
	fi

	if [ ! -d "$DILLO_SRC" ]; then
		echo "=== Extracting Dillo ${DILLO_VERSION} for BE-300 ==="
		rm -rf "$DILLO_SRC"
		tar xzf "$DILLO_ARCHIVE" -C /work
		mv "/work/dillo-${DILLO_VERSION}" "$DILLO_SRC"
	fi
}

patch_fltk_source() {
	make_generated_tree_writable "$FLTK_SRC"
	if [ ! -f "$FLTK_SRC/.be300-fltk-patched-v1" ]; then
		echo "=== Applying FLTK/NXlib compatibility patch ==="
		(
			cd "$FLTK_SRC"
			patch -p1 < /work/microwindows/src/tools/patch-fltk-1.3.8
		)
		touch "$FLTK_SRC/.be300-fltk-patched-v1"
	fi
	if [ ! -f "$FLTK_SRC/.be300-fltk-nxlib-region-v1" ]; then
		echo "=== Applying FLTK/NXlib opaque-region patch ==="
		(
			cd "$FLTK_SRC"
			patch -p1 <<'PATCH'
--- a/src/Fl_Pixmap.cxx
+++ b/src/Fl_Pixmap.cxx
@@ -210,6 +210,9 @@ void Fl_Xlib_Graphics_Driver::draw(Fl_Pixmap *pxm, int XP, int YP, int WP, int
       // At this point, XYWH is the bounding box of the intersection between
       // the current clip region and the (portion of the) pixmap we have to draw.
       // The current clip region is often a rectangle. But, when a window with rounded
+#if defined(BE300_NXLIB_OPAQUE_REGION)
+      copy_offscreen(X, Y, W, H, pxm->id_, cx, cy);
+#else
       // corners is moved above another window, expose events may create a complex clip
       // region made of several (e.g., 10) rectangles. We have to draw only in the clip
       // region, and also to mask out the transparent pixels of the image. This can't
@@ -227,6 +230,7 @@ void Fl_Xlib_Graphics_Driver::draw(Fl_Pixmap *pxm, int XP, int YP, int WP, int
         copy_offscreen(X1, Y1, W1, H1, pxm->id_, cx + (X1 - X), cy + (Y1 - Y));
       }
       XDestroyRegion(r);
+#endif
     } else {
       copy_offscreen(X, Y, W, H, pxm->id_, cx, cy);
     }
PATCH
		)
		touch "$FLTK_SRC/.be300-fltk-nxlib-region-v1"
	fi
}

patch_dillo_source() {
	make_generated_tree_writable "$DILLO_SRC"
	if [ ! -f "$DILLO_SRC/.be300-dillo-lowmem-v1" ]; then
		if grep -q 'BE300_DILLO_' "$DILLO_SRC/src/cache.c" 2>/dev/null ||
		   find "$DILLO_SRC" -name '*.rej' -print -quit | grep -q .; then
			echo "=== Re-extracting partially patched Dillo ${DILLO_VERSION} tree ==="
			rm -rf "$DILLO_SRC"
			tar xzf "$DILLO_ARCHIVE" -C /work
			mv "/work/dillo-${DILLO_VERSION}" "$DILLO_SRC"
		fi
		echo "=== Applying Dillo BE-300 low-memory patch ==="
		(
			cd "$DILLO_SRC"
			patch -p1 <<'PATCH'
--- a/src/cache.c
+++ b/src/cache.c
@@ -37,10 +37,16 @@
 #include "timeout.hh"
 #include "uicmd.hh"
 
 /** Maximum initial size for the automatically-growing data buffer */
-#define MAX_INIT_BUF  1024*1024
+#ifndef BE300_DILLO_MAX_INIT_BUF
+#define BE300_DILLO_MAX_INIT_BUF (1024*1024)
+#endif
+#define MAX_INIT_BUF BE300_DILLO_MAX_INIT_BUF
 /** Maximum filesize for a URL, before offering a download */
-#define HUGE_FILESIZE 15*1024*1024
+#ifndef BE300_DILLO_HUGE_FILESIZE
+#define BE300_DILLO_HUGE_FILESIZE (15*1024*1024)
+#endif
+#define HUGE_FILESIZE BE300_DILLO_HUGE_FILESIZE
 
 /*
  *  Local data types
@@ -118,10 +124,17 @@ void a_Cache_init(void)
 {
+#if defined(BE300_DILLO_LOW_MEMORY) && BE300_DILLO_LOW_MEMORY
+   ClientQueue = dList_new(8);
+   DelayedQueue = dList_new(8);
+   CachedURLs = dList_new(32);
+#else
    ClientQueue = dList_new(32);
    DelayedQueue = dList_new(32);
    CachedURLs = dList_new(256);
+#endif
 
    /* inject the splash screen in the cache */
+#if !defined(BE300_DILLO_NO_SPLASH_CACHE) || !BE300_DILLO_NO_SPLASH_CACHE
    {
       DilloUrl *url = a_Url_new("about:splash", NULL);
       Dstr *ds = dStr_new(AboutSplash);
       Cache_entry_inject(url, ds);
@@ -131,5 +145,6 @@ void a_Cache_init(void)
       a_Url_free(url);
    }
+#endif
 }
 
 /* Client operations ------------------------------------------------------ */
@@ -929,5 +944,9 @@ bool_t a_Cache_process_dbuf(int Op, const char *buf, size_t buf_size,
          }
          dStr_append_l(entry->Data, str, len);
+         if (entry->Data->len > HUGE_FILESIZE) {
+            entry->Flags |= CA_HugeFile;
+            done = TRUE;
+         }
          if (entry->CharsetDecoder && entry->UTF8Data) {
             dstr3 = a_Decode_process(entry->CharsetDecoder, str, len);
             dStr_append_l(entry->UTF8Data, dstr3->str, dstr3->len);
--- a/src/dicache.c
+++ b/src/dicache.c
@@ -75,7 +75,11 @@ static uint_t dicache_size_total; /* invariant: dicache_size_total is
  */
 void a_Dicache_init(void)
 {
+#if defined(BE300_DILLO_LOW_MEMORY) && BE300_DILLO_LOW_MEMORY
+   CachedIMGs = dList_new(32);
+#else
    CachedIMGs = dList_new(256);
+#endif
    dicache_size_total = 0;
 
    if (prefs.ignore_image_formats) {
--- a/src/IO/IO.h
+++ b/src/IO/IO.h
@@ -14,7 +14,10 @@
 /*
  * IO constants
  */
-#define IOBufLen         8192
+#ifndef BE300_DILLO_IOBUF_LEN
+#define BE300_DILLO_IOBUF_LEN 8192
+#endif
+#define IOBufLen BE300_DILLO_IOBUF_LEN
 
 
 /*
--- a/src/image.hh
+++ b/src/image.hh
@@ -29,7 +29,10 @@
  */
 
 /** Arbitrary maximum for image size. To avoid image size-crafting attacks. */
-#define IMAGE_MAX_AREA (6000 * 6000)
+#ifndef BE300_DILLO_IMAGE_MAX_AREA
+#define BE300_DILLO_IMAGE_MAX_AREA (6000 * 6000)
+#endif
+#define IMAGE_MAX_AREA BE300_DILLO_IMAGE_MAX_AREA
 
 /*
  * Types
--- a/dw/fltkimgbuf.cc
+++ b/dw/fltkimgbuf.cc
@@ -24,7 +24,10 @@
 
 using namespace lout;
 
-#define IMAGE_MAX_AREA (6000 * 6000)
+#ifndef BE300_DILLO_IMAGE_MAX_AREA
+#define BE300_DILLO_IMAGE_MAX_AREA (6000 * 6000)
+#endif
+#define IMAGE_MAX_AREA BE300_DILLO_IMAGE_MAX_AREA
 
 namespace dw {
 namespace fltk {
--- a/src/web.cc
+++ b/src/web.cc
@@ -37,7 +37,11 @@ static Dlist *ValidWebs = NULL;
 
 void a_Web_init(void)
 {
+#if defined(BE300_DILLO_LOW_MEMORY) && BE300_DILLO_LOW_MEMORY
+   ValidWebs = dList_new(8);
+#else
    ValidWebs = dList_new(32);
+#endif
 }
 
 /*
PATCH
		)
		touch "$DILLO_SRC/.be300-dillo-lowmem-v1"
	fi
	if [ ! -f "$DILLO_SRC/.be300-dillo-stowaway-url-v1" ]; then
		echo "=== Applying Dillo BE-300 Stowaway URL entry patch ==="
		(
			cd "$DILLO_SRC"
			patch -p1 <<'PATCH'
--- a/src/ui.cc
+++ b/src/ui.cc
@@ -723,7 +723,19 @@ int UI::handle(int event)
       return 0; // Receive as shortcut
    } else if (event == FL_SHORTCUT) {
       KeysCommand_t cmd = Keys::getKeyCmd();
       if (cmd == KEYS_NOP) {
+#if defined(BE300_DILLO_STOWAWAY_URL_KEYS) && BE300_DILLO_STOWAWAY_URL_KEYS
+         const char *text = Fl::event_text();
+         int len = Fl::event_length();
+         unsigned char ch = (len > 0 && text) ? (unsigned char) text[0] : 0;
+         unsigned modifier = Fl::event_state() & (FL_CTRL | FL_ALT | FL_META);
+
+         if (modifier == 0 && ch >= 32 && ch < 127 && Fl::focus() != Location) {
+            focus_location();
+            Location->handle(FL_KEYBOARD);
+            ret = 1;
+         }
+#endif
          // Do nothing
       } else if (cmd == KEYS_SCREEN_UP || cmd == KEYS_SCREEN_DOWN ||
                  cmd == KEYS_SCREEN_LEFT || cmd == KEYS_SCREEN_RIGHT ||
                  cmd == KEYS_LINE_UP || cmd == KEYS_LINE_DOWN ||
PATCH
		)
		touch "$DILLO_SRC/.be300-dillo-stowaway-url-v1"
	fi
	if [ ! -f "$DILLO_SRC/.be300-dillo-url-enter-v1" ]; then
		echo "=== Applying Dillo BE-300 URL Enter-key patch ==="
		(
			cd "$DILLO_SRC"
			patch -p1 <<'PATCH'
--- a/src/ui.cc
+++ b/src/ui.cc
@@ -117,6 +117,17 @@ int CustInput::handle(int e)
       (k == FL_Up || k == FL_Down || k == FL_Left || k == FL_Right)) {
       return 0;
    } else if (e == FL_KEYBOARD) {
+#if defined(BE300_DILLO_STOWAWAY_URL_KEYS) && BE300_DILLO_STOWAWAY_URL_KEYS
+      const char *text = Fl::event_text();
+      int len = Fl::event_length();
+      unsigned char ch = (len > 0 && text) ? (unsigned char) text[0] : 0;
+
+      if (modifier == 0 &&
+          (k == FL_Enter || k == FL_KP_Enter || ch == '\r' || ch == '\n')) {
+         do_callback();
+         return 1;
+      }
+#endif
       if (k == FL_Escape && modifier == 0) {
          // Let the parent group handle this Esc key
          return 0;
@@ -729,10 +740,17 @@ int UI::handle(int event)
          int len = Fl::event_length();
          unsigned char ch = (len > 0 && text) ? (unsigned char) text[0] : 0;
          unsigned modifier = Fl::event_state() & (FL_CTRL | FL_ALT | FL_META);
+         int k = Fl::event_key();
 
-         if (modifier == 0 && ch >= 32 && ch < 127 && Fl::focus() != Location) {
-            focus_location();
-            Location->handle(FL_KEYBOARD);
+         if (modifier == 0 && Fl::focus() == Location &&
+             (k == FL_Enter || k == FL_KP_Enter || ch == '\r' || ch == '\n')) {
+            Location->do_callback();
+            ret = 1;
+         } else if (modifier == 0 && ch >= 32 && ch < 127 &&
+                    Fl::focus() != Location) {
+            focus_location();
+            if (Location->handle(FL_KEYBOARD))
+               Location->redraw();
             ret = 1;
          }
 #endif
PATCH
		)
		touch "$DILLO_SRC/.be300-dillo-url-enter-v1"
	fi
	if [ ! -f "$DILLO_SRC/.be300-dillo-dns-service-v1" ]; then
		echo "=== Applying Dillo BE-300 DNS service patch ==="
		(
			cd "$DILLO_SRC"
			patch -p1 <<'PATCH'
--- a/src/dns.c
+++ b/src/dns.c
@@ -284,7 +284,12 @@ static void *Dns_server(void *data)
    _MSG("Dns_server: starting...\n ch: %d host: %s\n",
         channel, dns_server[channel].hostname);
 
+#if defined(BE300_DILLO_DNS_NUMERIC_SERVICE) && BE300_DILLO_DNS_NUMERIC_SERVICE
+   /* Dillo ignores the returned port; match the working helper's service form. */
+   error = getaddrinfo(dns_server[channel].hostname, "80", &hints, &res0);
+#else
    error = getaddrinfo(dns_server[channel].hostname, NULL, &hints, &res0);
+#endif
 
    if (error != 0) {
       dns_server[channel].status = error;
PATCH
		)
		touch "$DILLO_SRC/.be300-dillo-dns-service-v1"
	fi
	if [ ! -f "$DILLO_SRC/.be300-dillo-dns-service-v2" ]; then
		echo "=== Applying Dillo BE-300 DNS service follow-up patch ==="
		(
			cd "$DILLO_SRC"
			patch -p1 <<'PATCH'
--- a/src/dns.c
+++ b/src/dns.c
@@ -287,9 +287,6 @@ static void *Dns_server(void *data)
 #if defined(BE300_DILLO_DNS_NUMERIC_SERVICE) && BE300_DILLO_DNS_NUMERIC_SERVICE
-#ifdef AI_NUMERICSERV
-   hints.ai_flags |= AI_NUMERICSERV;
-#endif
-   /* Dillo ignores the returned port; avoid uClibc getaddrinfo(NULL service). */
-   error = getaddrinfo(dns_server[channel].hostname, "0", &hints, &res0);
+   /* Dillo ignores the returned port; match the working helper's service form. */
+   error = getaddrinfo(dns_server[channel].hostname, "80", &hints, &res0);
 #else
    error = getaddrinfo(dns_server[channel].hostname, NULL, &hints, &res0);
 #endif
PATCH
		)
		touch "$DILLO_SRC/.be300-dillo-dns-service-v2"
	fi
}

build_fltk() {
	if [ -f "$FLTK_SRC/$DILLO_BUILD_STAMP" ] &&
	   [ -f "$FLTK_SRC/lib/libfltk.a" ] &&
	   [ -f "$FLTK_SRC/lib/libfltk_z.a" ]; then
		echo "--- FLTK already built for BE-300, skipping rebuild ---"
		chmod +x "$FLTK_SRC/fltk-config"
		cp "$FLTK_SRC/zlib/zlib.h" "$BE300_LIBS/include/zlib.h"
		cp "$FLTK_SRC/zlib/zconf.h" "$BE300_LIBS/include/zconf.h"
		cp "$FLTK_SRC/lib/libfltk_z.a" "$BE300_LIBS/lib/libz.a"
		return
	fi

	echo "=== Configuring FLTK ${FLTK_VERSION} for NXlib ==="
	(
		cd "$FLTK_SRC"
		make clean >/dev/null 2>&1 || true
		CC="$CONFIG_CC" \
		CXX="$CONFIG_CXX" \
		CFLAGS="$CONFIG_CFLAGS" \
		CXXFLAGS="$CONFIG_CXXFLAGS" \
		LDFLAGS="$CONFIG_LDFLAGS" \
		ac_cv_header_X11_Xregion_h=no \
		./configure \
			--host=mipsel-linux-gnu \
			--build="$(gcc -dumpmachine)" \
			--prefix=/usr \
			--disable-gl \
			--disable-shared \
			--disable-threads \
			--disable-xinerama \
			--disable-xft \
			--disable-xdbe \
			--disable-xfixes \
			--disable-xcursor \
			--disable-xrender \
			--enable-localzlib \
			--disable-localjpeg \
			--disable-localpng \
			--with-x \
			--x-includes=/work/microwindows/src/nx11/X11-local \
			--x-libraries=/work/microwindows/src/lib \
			>"$FLTK_BUILD_LOG" 2>&1
		/work/microwindows/src/nx11/replace-lX11.sh makeinclude || true
		/work/microwindows/src/nx11/replace-lX11.sh fltk-config || true
		chmod +x fltk-config
		make -C zlib -j"$(nproc)" \
			CC="$TARGET_CC" \
			AR="$TARGET_AR" \
			RANLIB="$TARGET_RANLIB" \
			CFLAGS="$COMMON_CFLAGS" \
			>>"$FLTK_BUILD_LOG" 2>&1
		make -C src -j"$(nproc)" \
			CC="$TARGET_CC" \
			CXX="$TARGET_CC" \
			AR="$TARGET_AR" \
			RANLIB="$TARGET_RANLIB" \
			CFLAGS="$COMMON_CFLAGS -DFL_LIBRARY -DBE300_NXLIB_OPAQUE_REGION" \
			CXXFLAGS="$COMMON_CXXFLAGS -DFL_LIBRARY -DBE300_NXLIB_OPAQUE_REGION" \
			LDFLAGS="$COMMON_LDFLAGS" \
			>>"$FLTK_BUILD_LOG" 2>&1
	)

	cp "$FLTK_SRC/zlib/zlib.h" "$BE300_LIBS/include/zlib.h"
	cp "$FLTK_SRC/zlib/zconf.h" "$BE300_LIBS/include/zconf.h"
	cp "$FLTK_SRC/lib/libfltk_z.a" "$BE300_LIBS/lib/libz.a"
	touch "$FLTK_SRC/$DILLO_BUILD_STAMP"
}

build_dillo() {
	if [ -f "$DILLO_SRC/$DILLO_BUILD_STAMP" ] &&
	   [ -x "$DILLO_SRC/src/dillo" ]; then
		echo "--- Dillo already built for BE-300, skipping rebuild ---"
		return
	fi

	echo "=== Configuring Dillo ${DILLO_VERSION} for FLTK/NXlib ==="
	(
		cd "$DILLO_SRC"
		make distclean >/dev/null 2>&1 || true
		PATH="$FLTK_SRC:$PATH" \
		FLTK_CONFIG="$FLTK_SRC/fltk-config" \
		CC="$CONFIG_CC" \
		CXX="$CONFIG_CXX" \
		CFLAGS="$CONFIG_CFLAGS" \
		CXXFLAGS="$CONFIG_CXXFLAGS" \
		CPPFLAGS="-I${BE300_LIBS}/include" \
		LDFLAGS="$CONFIG_LDFLAGS" \
		./configure \
			--host=mipsel-linux-gnu \
			--build="$(gcc -dumpmachine)" \
			--prefix=/usr \
			--sysconfdir=/etc \
			--disable-cookies \
			--disable-png \
			--disable-webp \
			--disable-jpeg \
			--disable-gif \
			--disable-svg \
			--disable-threaded-dns \
			--disable-xembed \
			--disable-tls \
			--disable-html-tests \
			>"$DILLO_BUILD_LOG" 2>&1

		make -j"$(nproc)" \
			FLTK_CONFIG="$FLTK_SRC/fltk-config" \
			CC="$TARGET_CC" \
			CXX="$TARGET_CC" \
			CXXLD="$TARGET_CC" \
			AR="$TARGET_AR" \
			RANLIB="$TARGET_RANLIB" \
			CFLAGS="$COMMON_CFLAGS" \
			CXXFLAGS="$COMMON_CXXFLAGS" \
			CPPFLAGS="-I${BE300_LIBS}/include" \
			LDFLAGS="$COMMON_LDFLAGS -L$FLTK_SRC/lib -L/work/microwindows/src/lib" \
			LIBS="$COMMON_LIBS" \
			>>"$DILLO_BUILD_LOG" 2>&1
	)
	touch "$DILLO_SRC/$DILLO_BUILD_STAMP"
}

install_dillo_rootfs() {
	echo "=== Installing Dillo into BE-300 rootfs ==="
	mkdir -p "$ROOTFS/usr/bin" "$ROOTFS/etc/dillo"
	cp "$DILLO_SRC/src/dillo" "$ROOTFS/usr/bin/dillo"
	${TARGET_STRIP} --strip-all \
		--remove-section=.comment \
		--remove-section=.note \
		"$ROOTFS/usr/bin/dillo" 2>/dev/null || ${TARGET_STRIP} --strip-all "$ROOTFS/usr/bin/dillo"
	chmod +x "$ROOTFS/usr/bin/dillo"
	check_target_mips2 "$ROOTFS/usr/bin/dillo"
	cat >"$ROOTFS/etc/dillo/dillorc" <<'DILLORC'
geometry=238x300+0+0
start_page="about:blank"
home="http://example.com/"
new_tab_page="about:blank"
save_dir=/tmp

load_images=NO
ignore_image_formats="gif png webp jpeg svg"
load_background_images=NO
load_stylesheets=NO
parse_embedded_css=NO
buffered_drawing=0

font_factor=0.85
font_min_size=7
font_max_size=32
limit_text_width=YES
adjust_min_width=YES
adjust_table_min_width=YES

http_strict_transport_security=NO
http_force_https=NO
http_persistent_conns=NO
http_max_conns=1

panel_size=tiny
small_icons=YES
show_save=NO
show_bookmarks=NO
show_tools=NO
show_filemenu=NO
show_search=NO
show_help=NO
show_progress_box=NO
show_ui_tooltip=NO
show_quit_dialog=NO
show_msg=NO
middle_click_opens_new_tab=NO
scroll_switches_tabs=NO
DILLORC
}

prepare_support_libs
prepare_sources
patch_fltk_source
patch_dillo_source
build_fltk
build_dillo
install_dillo_rootfs
