#!/bin/bash
set -e

ROOTFS="${1:?rootfs path required}"
MUSL_SPECS="${2:?musl specs path required}"
KHDRS="${3:?kernel headers path required}"

QT_VERSION="2.3.10"
OPIE_VERSION="1.2.5"
ARCHIVES="/work/archives"
QT_ARCHIVE="$ARCHIVES/qt-embedded-${QT_VERSION}-free.tar.gz"
OPIE_ARCHIVE="$ARCHIVES/opie-${OPIE_VERSION}.tar.bz2"
QT_URL="https://download.qt.io/archive/qt/2/qt-embedded-${QT_VERSION}-free.tar.gz"
OPIE_URL="https://downloads.sourceforge.net/project/opie/opie-${OPIE_VERSION}.tar.bz2"
QT_HOST_SRC="/work/qt-${QT_VERSION}-host"
BE300_LIBS="/tmp/be300-opie-libs"
LOG_DIR="/work/build-opie"
QT_BUILD_LOG="$LOG_DIR/be300_qte_build.log"
QT_HOST_BUILD_LOG="$LOG_DIR/be300_qte_host_tools.log"
OPIE_BUILD_LOG="$LOG_DIR/be300_opie_build.log"
BE300_LIBC="${BE300_LIBC:-musl}"
OPIE_CONFIG="${OPIE_CONFIG:-/work/board/opie/opie-be300.config}"
OPIE_BUILD_STAMP="${OPIE_BUILD_STAMP:-.be300-opie-built-v100}"
OPIE_PROFILE="${OPIE_PROFILE:-base}"
OPIE_EXTRA_DEFS="${OPIE_EXTRA_DEFS:-}"

CROSS="mipsel-linux-gnu-"
TARGET_CC="${BE300_TARGET_CC:-${CROSS}gcc}"
TARGET_CXX="${BE300_TARGET_CXX:-${CROSS}g++}"
TARGET_AR="${BE300_TARGET_AR:-${CROSS}ar}"
TARGET_RANLIB="${BE300_TARGET_RANLIB:-${CROSS}ranlib}"
TARGET_STRIP="${BE300_TARGET_STRIP:-${CROSS}strip}"
TARGET_CROSS_COMPILE="${BE300_TARGET_CROSS_COMPILE:-${CROSS}}"
ARCH_CFLAGS="${BE300_ARCH_CFLAGS:--march=mips2 -mfpxx}"
DEFAULT_LIBC_CFLAGS="-specs ${MUSL_SPECS} -isystem ${KHDRS}/include -B/tmp/libgcc_patched -L/tmp/libgcc_patched"
DEFAULT_LIBC_LDFLAGS="-specs ${MUSL_SPECS} -B/tmp/libgcc_patched -L/tmp/libgcc_patched"
LIBC_CFLAGS="${BE300_LIBC_CFLAGS:-$DEFAULT_LIBC_CFLAGS}"
LIBC_LDFLAGS="${BE300_LIBC_LDFLAGS:-$DEFAULT_LIBC_LDFLAGS}"
OPIE_BIND_NOW_LDFLAGS="${BE300_OPIE_BIND_NOW_LDFLAGS:-}"
if [ "$BE300_LIBC" = "uclibc" ] && [ -z "$OPIE_BIND_NOW_LDFLAGS" ]; then
	OPIE_BIND_NOW_LDFLAGS="-Wl,-z,now"
fi
OPIE_NO_RELAX_CFLAGS="${BE300_OPIE_NO_RELAX_CFLAGS:-}"
if [ "$BE300_LIBC" = "uclibc" ] && [ -z "$OPIE_NO_RELAX_CFLAGS" ]; then
	OPIE_NO_RELAX_CFLAGS="-mno-relax-pic-calls"
fi
OPIE_NO_RELAX_LDFLAGS="${BE300_OPIE_NO_RELAX_LDFLAGS:-}"
if [ "$BE300_LIBC" = "uclibc" ] && [ -z "$OPIE_NO_RELAX_LDFLAGS" ]; then
	OPIE_NO_RELAX_LDFLAGS="-Wl,--no-relax"
fi
if [ "$BE300_LIBC" = "musl" ]; then
	QT_SRC="/work/qt-${QT_VERSION}-be300"
	OPIE_SRC="/work/opie-${OPIE_VERSION}-be300"
else
	QT_SRC="/work/qt-${QT_VERSION}-be300-${BE300_LIBC}"
	OPIE_SRC="/work/opie-${OPIE_VERSION}-be300-${BE300_LIBC}"
fi
COMMON_CFLAGS="${ARCH_CFLAGS} -DQT_QWS_CASSIOPEIA ${OPIE_EXTRA_DEFS} ${OPIE_NO_RELAX_CFLAGS} -Os -fomit-frame-pointer ${LIBC_CFLAGS} -I${BE300_LIBS}/include"
COMMON_CXXFLAGS="${COMMON_CFLAGS} -nostdinc++ -std=gnu++98 -fno-exceptions -fno-rtti -fpermissive -Wno-write-strings"
COMMON_LFLAGS="${LIBC_LDFLAGS} ${OPIE_BIND_NOW_LDFLAGS} ${OPIE_NO_RELAX_LDFLAGS} -L${BE300_LIBS}/lib"
COMMON_LIBS="-lbe300cxx -lbe300gcc"

mkdir -p "$LOG_DIR"

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
	echo "=== Building BE-300 OPIE support libraries ==="
	rm -rf "$BE300_LIBS"
	mkdir -p "$BE300_LIBS/include/sysfs" "$BE300_LIBS/lib"
	cp /work/board/opie/libsysfs.h "$BE300_LIBS/include/sysfs/libsysfs.h"

	${TARGET_CC} $COMMON_CFLAGS -fPIC -c \
		/work/board/opie/be300_cxx_abi.c -o /tmp/be300_cxx_abi.o
	${TARGET_AR} rcs "$BE300_LIBS/lib/libbe300cxx.a" /tmp/be300_cxx_abi.o

	${TARGET_CC} $COMMON_CFLAGS -fPIC -c \
		/work/board/opie/be300_sysfs_stub.c -o /tmp/be300_sysfs_stub.o
	${TARGET_AR} rcs "$BE300_LIBS/lib/libsysfs.a" /tmp/be300_sysfs_stub.o
}

prepare_qt_source() {
	download_archive "$QT_URL" "$QT_ARCHIVE"
	download_archive "$OPIE_URL" "$OPIE_ARCHIVE"
	make_generated_tree_writable "$QT_SRC" "$OPIE_SRC"

	if [ ! -d "$QT_SRC" ]; then
		echo "=== Extracting Qt/Embedded ${QT_VERSION} for BE-300 ==="
		rm -rf "$QT_SRC"
		tar xzf "$QT_ARCHIVE" -C /work
		mv "/work/qt-${QT_VERSION}" "$QT_SRC"
	fi

	if [ ! -d "$OPIE_SRC" ]; then
		echo "=== Extracting OPIE ${OPIE_VERSION} for BE-300 ==="
		rm -rf "$OPIE_SRC"
		tar xjf "$OPIE_ARCHIVE" -C /work
		mv "/work/opie-${OPIE_VERSION}" "$OPIE_SRC"
	fi
}

write_qt_config() {
	cat >"$QT_SRC/configs/linux-be300-g++-shared" <<EOF
# BE-300 mipsel/${BE300_LIBC} shared Qt/Embedded build.
INTERFACE_DECL_PATH = .
SYSCONF_CXX = ${TARGET_CXX}
SYSCONF_CC = ${TARGET_CC}
DASHCROSS =
SYSCONF_CXXFLAGS_X11 =
SYSCONF_CXXFLAGS_QT = -I\$(QTDIR)/include
SYSCONF_CXXFLAGS_QTOPIA = -I\$(QPEDIR)/include
SYSCONF_CXXFLAGS_OPENGL =
SYSCONF_CXXFLAGS_YACC = -Wno-unused -Wno-parentheses
SYSCONF_RPATH_X11 =
SYSCONF_RPATH_QT =
SYSCONF_RPATH_QTOPIA =
SYSCONF_RPATH_OPENGL =
SYSCONF_LFLAGS_X11 =
SYSCONF_LIBS_X11 =
SYSCONF_LFLAGS_QT = -L\$(QTDIR)/lib
SYSCONF_LFLAGS_QTOPIA = -L\$(QPEDIR)/lib
SYSCONF_LIBS_QT = -lqte\$(QT_THREAD_SUFFIX)
SYSCONF_LIBS_QT_OPENGL =
SYSCONF_LFLAGS_OPENGL =
SYSCONF_LIBS_OPENGL =
SYSCONF_LIBS_YACC =
SYSCONF_LINK = ${TARGET_CC}
SYSCONF_LFLAGS = ${COMMON_LFLAGS}
SYSCONF_LIBS = ${COMMON_LIBS}
SYSCONF_LFLAGS_SHOBJ = -shared
SYSCONF_CFLAGS_THREAD = -D_REENTRANT
SYSCONF_CXXFLAGS_THREAD = -D_REENTRANT
SYSCONF_LFLAGS_THREAD =
SYSCONF_LIBS_THREAD = -lpthread
SYSCONF_MOC = \$(QTDIR)/bin/moc
SYSCONF_UIC = \$(QTDIR)/bin/uic
SYSCONF_LINK_SHLIB = ${TARGET_CC}
SYSCONF_LINK_TARGET_SHARED = lib\$(TARGET).so.\$(VER_MAJ).\$(VER_MIN).\$(VER_PATCH)
SYSCONF_LINK_LIB_SHARED = \$(SYSCONF_LINK_SHLIB) -shared -Wl,-soname,lib\$(TARGET).so.\$(VER_MAJ) \\
				     \$(LFLAGS) -o \$(SYSCONF_LINK_TARGET_SHARED) \\
				     \$(OBJECTS) \$(OBJMOC) \$(LIBS) ${COMMON_LIBS} && \\
				 mv \$(SYSCONF_LINK_TARGET_SHARED) \$(DESTDIR); \\
				 cd \$(DESTDIR) && \\
				 rm -f lib\$(TARGET).so lib\$(TARGET).so.\$(VER_MAJ) lib\$(TARGET).so.\$(VER_MAJ).\$(VER_MIN); \\
				 ln -s \$(SYSCONF_LINK_TARGET_SHARED) lib\$(TARGET).so; \\
				 ln -s \$(SYSCONF_LINK_TARGET_SHARED) lib\$(TARGET).so.\$(VER_MAJ); \\
				 ln -s \$(SYSCONF_LINK_TARGET_SHARED) lib\$(TARGET).so.\$(VER_MAJ).\$(VER_MIN)
SYSCONF_AR = ${TARGET_AR} cqs
SYSCONF_LINK_TARGET_STATIC = lib\$(TARGET).a
SYSCONF_LINK_LIB_STATIC = rm -f \$(DESTDIR)\$(SYSCONF_LINK_TARGET_STATIC) ; \\
				 \$(SYSCONF_AR) \$(DESTDIR)\$(SYSCONF_LINK_TARGET_STATIC) \$(OBJECTS) \$(OBJMOC)
SYSCONF_CXXFLAGS = -pipe -DQWS ${COMMON_CXXFLAGS} -Wall -W -DNO_DEBUG
SYSCONF_CFLAGS = -pipe ${COMMON_CFLAGS} -Wall -W
SYSCONF_LINK_LIB = \$(SYSCONF_LINK_LIB_SHARED)
SYSCONF_LINK_TARGET = \$(SYSCONF_LINK_TARGET_SHARED)
SYSCONF_CXXFLAGS_LIB = -fPIC
SYSCONF_CFLAGS_LIB = -fPIC
SYSCONF_CXXFLAGS_SHOBJ = -fPIC
SYSCONF_CFLAGS_SHOBJ = -fPIC
SYSCONF_LIBS_QTLIB = ${COMMON_LIBS}
SYSCONF_LIBS_QTAPP = ${COMMON_LIBS}
EOF
}

patch_qt_source() {
	make_generated_tree_writable "$QT_SRC"
	if [ ! -f "$QT_SRC/.be300-opie-patched-v2" ]; then
		echo "=== Applying OPIE Qt/Embedded patches ==="
		rm -rf "$QT_SRC"
		tar xzf "$QT_ARCHIVE" -C /work
		mv "/work/qt-${QT_VERSION}" "$QT_SRC"
		make_generated_tree_writable "$QT_SRC"
		(
			cd "$QT_SRC"
			if ! patch -p1 <"$OPIE_SRC/qt/qt-${QT_VERSION}.patch/qte-${QT_VERSION}-all.patch"; then
				# The OPIE patch includes hunks for include/*.h symlinks
				# that point at the real src/* headers.  GNU patch refuses
				# the symlink paths, then applies the real files.  Treat
				# those include-only rejects as expected.
				bad_rejects=$(find . -name '*.rej' ! -path './include/*' -print)
				if [ -n "$bad_rejects" ]; then
					echo "$bad_rejects"
					exit 1
				fi
				rm -f include/*.rej
			fi
			cp "$OPIE_SRC/qt/qconfig-qpe.h" src/tools/qconfig-qpe.h
		)
		touch "$QT_SRC/.be300-opie-patched-v2"
	fi
	write_qt_config
	QT_SRC="$QT_SRC" python3 - <<'PY'
import os
import re
from pathlib import Path

qt_root = Path(os.environ["QT_SRC"])

path = qt_root / "src/kernel/qwindowsystem_qws.h"
text = path.read_text()
needle = "class QWSMouseHandler;\nstruct QWSCommandStruct;\n"
replacement = (
    "class QWSMouseHandler;\n"
    "class QWSInputMethod;\n"
    "class QWSGestureMethod;\n"
    "struct QWSCommandStruct;\n"
)
if needle in text and replacement not in text:
    text = text.replace(needle, replacement, 1)
path.write_text(text)

path = qt_root / "src/kernel/qpixmapcache.cpp"
text = path.read_text()
old = "# include <asm/page.h> // PAGE_SIZE,PAGE_MASK,PAGE_ALIGN\n"
new = (
    "# ifndef PAGE_SIZE\n"
    "# define PAGE_SIZE 4096\n"
    "# endif\n"
    "# ifndef PAGE_MASK\n"
    "# define PAGE_MASK (~(PAGE_SIZE-1))\n"
    "# endif\n"
)
if old in text:
    text = text.replace(old, new, 1)
path.write_text(text)

path = qt_root / "src/kernel/qimage.cpp"
text = path.read_text()
old = "    dst.create(d->newcols, d->newrows, 32);\n    dst.setAlphaBuffer(d->hasAlpha);\n"
new = (
    "    int dstcols = d->newcols > 0 ? d->newcols + 1 : d->newcols;\n"
    "    dst.create(dstcols, d->newrows, 32);\n"
    "    dst.setAlphaBuffer(d->hasAlpha);\n"
)
if old in text and new not in text:
    text = text.replace(old, new, 1)
old = "	    nxP = (QRgb*)dst.scanLine(rowswritten++);\n	    fraccoltofill = SCALE;\n"
new = (
    "	    nxP = (QRgb*)dst.scanLine(rowswritten++);\n"
    "	    QRgb *dstend = nxP + d->newcols;\n"
    "	    fraccoltofill = SCALE;\n"
)
if old in text and new not in text:
    text = text.replace(old, new, 1)
old = (
    "		    if (as) {\n"
    "\t\t\ta /= SCALE;\n"
    "\t\t\tif ( a > maxval ) a = maxval;\n"
    "\t\t\t*nxP = qRgba( (int)r, (int)g, (int)b, (int)a );\n"
    "\t\t    } else {\n"
    "\t\t\t*nxP = qRgb( (int)r, (int)g, (int)b );\n"
    "\t\t    }\n"
    "\t\t    fraccolleft -= fraccoltofill;\n"
)
new = (
    "		    if ( nxP < dstend ) {\n"
    "\t\t\tif (as) {\n"
    "\t\t\t    a /= SCALE;\n"
    "\t\t\t    if ( a > maxval ) a = maxval;\n"
    "\t\t\t    *nxP = qRgba( (int)r, (int)g, (int)b, (int)a );\n"
    "\t\t\t} else {\n"
    "\t\t\t    *nxP = qRgb( (int)r, (int)g, (int)b );\n"
    "\t\t\t}\n"
    "\t\t    }\n"
    "\t\t    fraccolleft -= fraccoltofill;\n"
)
if old in text and new not in text:
    text = text.replace(old, new, 1)
old = (
    "\t\tif (as) {\n"
    "\t\t    a /= SCALE;\n"
    "\t\t    if ( a > maxval ) a = maxval;\n"
    "\t\t    *nxP = qRgba( (int)r, (int)g, (int)b, (int)a );\n"
    "\t\t} else {\n"
    "\t\t    *nxP = qRgb( (int)r, (int)g, (int)b );\n"
    "\t\t}\n"
    "\t    }\n"
)
new = (
    "\t\tif ( nxP < dstend ) {\n"
    "\t\t    if (as) {\n"
    "\t\t\ta /= SCALE;\n"
    "\t\t\tif ( a > maxval ) a = maxval;\n"
    "\t\t\t*nxP = qRgba( (int)r, (int)g, (int)b, (int)a );\n"
    "\t\t    } else {\n"
    "\t\t\t*nxP = qRgb( (int)r, (int)g, (int)b );\n"
    "\t\t    }\n"
    "\t\t}\n"
    "\t    }\n"
)
if old in text and new not in text:
    text = text.replace(old, new, 1)
old = "    return dst;\n}\n#endif // QT_NO_IMAGE_SMOOTHSCALE\n"
new = (
    "    if (dstcols != d->newcols)\n"
    "\treturn dst.copy(0, 0, d->newcols, d->newrows);\n"
    "    return dst;\n"
    "}\n"
    "#endif // QT_NO_IMAGE_SMOOTHSCALE\n"
)
if old in text and new not in text:
    text = text.replace(old, new, 1)
path.write_text(text)

path = qt_root / "src/kernel/qapplication_qws.cpp"
text = path.read_text()
if "[be300-qt]" not in text:
    text = text.replace(
        "    // Connect to FB server\n\n    qt_fbdpy = new QWSDisplay();\n",
        "    // Connect to FB server\n\n"
        "    fprintf(stderr, \"[be300-qt] init_display: new QWSDisplay\\n\");\n"
        "    qt_fbdpy = new QWSDisplay();\n"
        "    fprintf(stderr, \"[be300-qt] init_display: QWSDisplay ready\\n\");\n",
        1,
    )
    text = text.replace(
        "void qt_init_display()\n{\n    qt_is_gui_used = TRUE;\n",
        "void qt_init_display()\n{\n    fprintf(stderr, \"[be300-qt] qt_init_display\\n\");\n    qt_is_gui_used = TRUE;\n",
        1,
    )
    text = text.replace(
        "void qt_init( int *argcptr, char **argv, QApplication::Type type )\n{\n",
        "void qt_init( int *argcptr, char **argv, QApplication::Type type )\n{\n"
        "    fprintf(stderr, \"[be300-qt] qt_init enter type=%d display=%s\\n\", (int)type, getenv(\"QWS_DISPLAY\") ? getenv(\"QWS_DISPLAY\") : \"\");\n",
        1,
    )
    text = text.replace(
        "    if ( type == QApplication::GuiServer ) {\n\tqt_appType = type;\n\tqws_single_process = TRUE;\n\tQWSServer::startup(flags);\n\tsetenv(\"QWS_DISPLAY\", qws_display_spec, 0);\n    }\n\n    if( qt_is_gui_used )\n\tinit_display();\n",
        "    if ( type == QApplication::GuiServer ) {\n\tqt_appType = type;\n\tqws_single_process = TRUE;\n\tfprintf(stderr, \"[be300-qt] qt_init: QWSServer::startup flags=%d spec=%s\\n\", flags, qws_display_spec ? qws_display_spec : \"\");\n\tQWSServer::startup(flags);\n\tfprintf(stderr, \"[be300-qt] qt_init: QWSServer::startup returned\\n\");\n\tsetenv(\"QWS_DISPLAY\", qws_display_spec, 0);\n    }\n\n    if( qt_is_gui_used ) {\n\tfprintf(stderr, \"[be300-qt] qt_init: init_display client path\\n\");\n\tinit_display();\n\tfprintf(stderr, \"[be300-qt] qt_init: init_display returned\\n\");\n    }\n",
        1,
    )
    path.write_text(text)

path = qt_root / "src/kernel/qwscursor_qws.cpp"
text = path.read_text()
old = "    setMouse(QPoint(swidth/2, sheight/2), 0);\n"
new = "    mousePosition = QPoint(swidth/2, sheight/2);\n"
if old in text and new not in text:
    text = text.replace(old, new, 1)
old = (
    "    qt_screencursor->hide();\n"
    "    qt_screencursor->set(curs->image(),\n"
)
new = (
    "    if ( !qt_screencursor )\n"
    "\treturn;\n"
    "\n"
    "    qt_screencursor->hide();\n"
    "    qt_screencursor->set(curs->image(),\n"
)
if old in text and "if ( !qt_screencursor )" not in text:
    text = text.replace(old, new, 1)
path.write_text(text)

path = qt_root / "src/kernel/qwindowsystem_qws.cpp"
text = path.read_text()
old = "    qt_screencursor->move(pos.x(),pos.y());\n"
new = "    if ( qt_screencursor )\n\tqt_screencursor->move(pos.x(),pos.y());\n"
if old in text and new not in text:
    text = text.replace(old, new, 1)
if "[be300-qws]" not in text:
    text = text.replace(
        "    d = new QWSServerData;\n    ASSERT( !qwsServer );\n",
        "    fprintf(stderr, \"[be300-qws] QWSServer ctor body flags=%d\\n\", flags);\n"
        "    d = new QWSServerData;\n    ASSERT( !qwsServer );\n",
        1,
    )
    text = text.replace(
        "    openDisplay();\n\n    d->screensavertimer = new QTimer(this);\n",
        "    fprintf(stderr, \"[be300-qws] openDisplay\\n\");\n"
        "    openDisplay();\n"
        "    fprintf(stderr, \"[be300-qws] openDisplay done\\n\");\n\n"
        "    d->screensavertimer = new QTimer(this);\n",
        1,
    )
    text = text.replace(
        "    if ( !(flags&DisableMouse) ) {\n\topenMouse();\n    }\n    initializeCursor();\n",
        "    if ( !(flags&DisableMouse) ) {\n\tfprintf(stderr, \"[be300-qws] openMouse\\n\");\n\topenMouse();\n\tfprintf(stderr, \"[be300-qws] openMouse done\\n\");\n    }\n    fprintf(stderr, \"[be300-qws] initializeCursor\\n\");\n    initializeCursor();\n    fprintf(stderr, \"[be300-qws] initializeCursor done\\n\");\n",
        1,
    )
    text = text.replace(
        "    if ( !(flags&DisableKeyboard) ) {\n\topenKeyboard();\n    }\n#endif\n",
        "    if ( !(flags&DisableKeyboard) ) {\n\tfprintf(stderr, \"[be300-qws] openKeyboard\\n\");\n\topenKeyboard();\n\tfprintf(stderr, \"[be300-qws] openKeyboard done\\n\");\n    }\n#endif\n",
        1,
    )
    text = text.replace(
        "void QWSServer::openMouse()\n{\n    QString mice = getenv(\"QWS_MOUSE_PROTO\");\n",
        "void QWSServer::openMouse()\n{\n    QString mice = getenv(\"QWS_MOUSE_PROTO\");\n    fprintf(stderr, \"[be300-qws] openMouse proto=%s\\n\", getenv(\"QWS_MOUSE_PROTO\") ? getenv(\"QWS_MOUSE_PROTO\") : \"\");\n",
        1,
    )
    text = text.replace(
        "\t    QWSMouseHandler* h = newMouseHandler(ms);\n",
        "\t    fprintf(stderr, \"[be300-qws] newMouseHandler %s\\n\", ms.latin1());\n\t    QWSMouseHandler* h = newMouseHandler(ms);\n\t    fprintf(stderr, \"[be300-qws] newMouseHandler done %p\\n\", h);\n",
        1,
    )
    text = text.replace(
        "void QWSServer::openKeyboard()\n{\n    QString keyboards = getenv(\"QWS_KEYBOARD\");\n",
        "void QWSServer::openKeyboard()\n{\n    QString keyboards = getenv(\"QWS_KEYBOARD\");\n    fprintf(stderr, \"[be300-qws] openKeyboard proto=%s\\n\", getenv(\"QWS_KEYBOARD\") ? getenv(\"QWS_KEYBOARD\") : \"\");\n",
        1,
    )
    text = text.replace(
        "\tQWSKeyboardHandler* kh = newKeyboardHandler(*k);\n\tkeyboardhandlers.append(kh);\n",
        "\tfprintf(stderr, \"[be300-qws] newKeyboardHandler %s\\n\", (*k).latin1());\n\tQWSKeyboardHandler* kh = newKeyboardHandler(*k);\n\tfprintf(stderr, \"[be300-qws] newKeyboardHandler done %p\\n\", kh);\n\tkeyboardhandlers.append(kh);\n",
        1,
    )
    text = text.replace(
        "void QWSServer::startup(int flags)\n{\n    if ( qwsServer )\n\treturn;\n    unlink( qws_qtePipeFilename().latin1() );\n    (void)new QWSServer(flags);\n}\n",
        "void QWSServer::startup(int flags)\n{\n    fprintf(stderr, \"[be300-qws] startup flags=%d\\n\", flags);\n    if ( qwsServer )\n\treturn;\n    unlink( qws_qtePipeFilename().latin1() );\n    (void)new QWSServer(flags);\n    fprintf(stderr, \"[be300-qws] startup done\\n\");\n}\n",
        1,
    )
    path.write_text(text)
else:
    path.write_text(text)

for rel in ("include/qvaluestack.h", "src/tools/qvaluestack.h"):
    path = qt_root / rel
    text = path.read_text()
    text = text.replace("this->this->append", "this->append")
    text = text.replace("this->this->remove", "this->remove")
    text = text.replace("void  push( const T& d ) { append(d); }",
                        "void  push( const T& d ) { this->append(d); }")
    text = text.replace("remove( this->fromLast() );",
                        "this->remove( this->fromLast() );")
    text = text.replace("this->this->append", "this->append")
    text = text.replace("this->this->remove", "this->remove")
    path.write_text(text)

path = qt_root / "src/kernel/qkeyboard_qws.cpp"
text = path.read_text()
old = (
    "    Myinputevent event;\n"
    "    int n = ::read(fd, &event, sizeof(Myinputevent) );\n"
    "    if ( n != 16 )\n"
    "\treturn;\n"
)
new = (
    "    Myinputevent event;\n"
    "    int n = ::read(fd, &event, sizeof(Myinputevent) );\n"
    "    if ( n != 16 )\n"
    "\treturn;\n"
    "    if ( event.type != 1 )\n"
    "\treturn;\n"
)
if old in text and new not in text:
    text = text.replace(old, new, 1)
path.write_text(text)

path = qt_root / "src/kernel/qwsmouse_qws.cpp"
text = path.read_text()
old = (
    "#ifdef QT_QWS_CASSIOPEIA\n"
    "#include <linux/tpanel.h>\n"
    "#endif\n"
)
new = (
    "#ifdef QT_QWS_CASSIOPEIA\n"
    "struct scanparam {\n"
    "    int interval;\n"
    "    int settletime;\n"
    "};\n"
    "#ifndef TPSETSCANPARM\n"
    "#define TPSETSCANPARM 0\n"
    "#endif\n"
    "#endif\n"
)
if old in text:
    text = text.replace(old, new, 1)
old = "    int mouseFD;\n    MouseProtocol mouseProtocol;\nprivate slots:\n"
new = (
    "    int mouseFD;\n"
    "    MouseProtocol mouseProtocol;\n"
    "    bool useEvdev;\n"
    "    int evX;\n"
    "    int evY;\n"
    "    bool evPressed;\n"
    "    bool evDirty;\n"
    "    bool evHaveX;\n"
    "    bool evHaveY;\n"
    "private slots:\n"
)
if old in text and new not in text:
    text = text.replace(old, new, 1)
old = (
    "#ifndef QT_QWS_CASSIOPEIA\n"
    "QVrTPanelHandlerPrivate::QVrTPanelHandlerPrivate( MouseProtocol, QString ) :\n"
)
new = (
    "struct Be300InputEvent {\n"
    "    unsigned int sec;\n"
    "    unsigned int usec;\n"
    "    unsigned short type;\n"
    "    unsigned short code;\n"
    "    int value;\n"
    "};\n"
    "\n"
    "#define BE300_EV_SYN 0\n"
    "#define BE300_EV_KEY 1\n"
    "#define BE300_EV_ABS 3\n"
    "#define BE300_SYN_REPORT 0\n"
    "#define BE300_ABS_X 0\n"
    "#define BE300_ABS_Y 1\n"
    "#define BE300_BTN_TOUCH 0x14a\n"
    "\n"
    "#ifndef QT_QWS_CASSIOPEIA\n"
    "QVrTPanelHandlerPrivate::QVrTPanelHandlerPrivate( MouseProtocol, QString ) :\n"
)
if old in text and "struct Be300InputEvent" not in text:
    text = text.replace(old, new, 1)
old = (
    "QVrTPanelHandlerPrivate::QVrTPanelHandlerPrivate( MouseProtocol, QString dev ) :\n"
    "    QCalibratedMouseHandler()\n"
    "{\n"
    "    if ( dev.isEmpty() )\n"
    "\tdev = \"/dev/tpanel\";\n"
    "\n"
    "    if ((mouseFD = open( dev, O_RDONLY)) < 0) {\n"
)
new = (
    "QVrTPanelHandlerPrivate::QVrTPanelHandlerPrivate( MouseProtocol, QString dev ) :\n"
    "    QCalibratedMouseHandler(), useEvdev(FALSE), evX(0), evY(0),\n"
    "    evPressed(FALSE), evDirty(FALSE), evHaveX(FALSE), evHaveY(FALSE)\n"
    "{\n"
    "    if ( dev.isEmpty() )\n"
    "\tdev = \"/dev/tpanel\";\n"
    "\n"
    "    if ( dev.left(11) == \"/dev/input/\" ) {\n"
    "\tif ((mouseFD = open( dev, O_RDONLY | O_NDELAY)) < 0) {\n"
    "\t    qFatal( \"Cannot open %s (%s)\", dev.latin1(), strerror(errno));\n"
    "\t}\n"
    "\tuseEvdev = TRUE;\n"
    "\tfcntl(mouseFD, F_SETFL, O_NONBLOCK);\n"
    "\tQSocketNotifier *mouseNotifier;\n"
    "\tmouseNotifier = new QSocketNotifier( mouseFD, QSocketNotifier::Read,\n"
    "\t\t\t\t\t this );\n"
    "\tconnect(mouseNotifier, SIGNAL(activated(int)),this, SLOT(readMouseData()));\n"
    "\tprintf(\"\\033[?25l\"); fflush(stdout);\n"
    "\treturn;\n"
    "    }\n"
    "\n"
    "    if ((mouseFD = open( dev, O_RDONLY)) < 0) {\n"
)
if old in text and "useEvdev = TRUE" not in text:
    text = text.replace(old, new, 1)
old = (
    "    if(!qt_screen)\n"
    "\treturn;\n"
    "    static bool pressed = FALSE;\n"
    "\n"
    "    int n;\n"
)
new = (
    "    if(!qt_screen)\n"
    "\treturn;\n"
    "\n"
    "    if ( useEvdev ) {\n"
    "\tBe300InputEvent event;\n"
    "\tint n;\n"
    "\twhile ( (n = read(mouseFD, &event, sizeof(event))) == (int)sizeof(event) ) {\n"
    "\t    if ( event.type == BE300_EV_ABS ) {\n"
    "\t\tif ( event.code == BE300_ABS_X ) {\n"
    "\t\t    evX = event.value;\n"
    "\t\t    evHaveX = TRUE;\n"
    "\t\t    evDirty = TRUE;\n"
    "\t\t} else if ( event.code == BE300_ABS_Y ) {\n"
    "\t\t    evY = event.value;\n"
    "\t\t    evHaveY = TRUE;\n"
    "\t\t    evDirty = TRUE;\n"
    "\t\t}\n"
    "\t    } else if ( event.type == BE300_EV_KEY && event.code == BE300_BTN_TOUCH ) {\n"
    "\t\tevPressed = event.value != 0;\n"
    "\t\tevDirty = TRUE;\n"
    "\t    } else if ( event.type == BE300_EV_SYN && event.code == BE300_SYN_REPORT ) {\n"
    "\t\tif ( evDirty ) {\n"
    "\t\t    if ( !evPressed || ( evHaveX && evHaveY ) ) {\n"
    "\t\t\tmousePos = QPoint(evX, evY);\n"
    "\t\t\temit mouseChanged(mousePos, evPressed ? Qt::LeftButton : 0);\n"
    "\t\t    }\n"
    "\t\t    evDirty = FALSE;\n"
    "\t\t}\n"
    "\t    }\n"
    "\t}\n"
    "\tif ( n < 0 && errno != EAGAIN )\n"
    "\t    qWarning(\"touch read error %s\", strerror(errno));\n"
    "\treturn;\n"
    "    }\n"
    "\n"
    "    static bool pressed = FALSE;\n"
    "\n"
    "    int n;\n"
)
if old in text and "touch read error" not in text:
    text = text.replace(old, new, 1)
if "bool evDirty;\nprivate slots:" in text:
    text = text.replace(
        "    bool evDirty;\n"
        "private slots:\n",
        "    bool evDirty;\n"
        "    bool evHaveX;\n"
        "    bool evHaveY;\n"
        "private slots:\n",
        1,
    )
if "evPressed(FALSE), evDirty(FALSE)\n" in text:
    text = text.replace(
        "    evPressed(FALSE), evDirty(FALSE)\n",
        "    evPressed(FALSE), evDirty(FALSE), evHaveX(FALSE), evHaveY(FALSE)\n",
        1,
    )
if "evX = event.value;\n\t\t    evDirty = TRUE;" in text:
    text = text.replace(
        "evX = event.value;\n\t\t    evDirty = TRUE;",
        "evX = event.value;\n\t\t    evHaveX = TRUE;\n\t\t    evDirty = TRUE;",
        1,
    )
if "evY = event.value;\n\t\t    evDirty = TRUE;" in text:
    text = text.replace(
        "evY = event.value;\n\t\t    evDirty = TRUE;",
        "evY = event.value;\n\t\t    evHaveY = TRUE;\n\t\t    evDirty = TRUE;",
        1,
    )
old = (
    "\t\tif ( evDirty ) {\n"
    "\t\t    mousePos = QPoint(evX, evY);\n"
    "\t\t    emit mouseChanged(mousePos, evPressed ? Qt::LeftButton : 0);\n"
    "\t\t    evDirty = FALSE;\n"
    "\t\t}\n"
)
new = (
    "\t\tif ( evDirty ) {\n"
    "\t\t    if ( !evPressed || ( evHaveX && evHaveY ) ) {\n"
    "\t\t\tmousePos = QPoint(evX, evY);\n"
    "\t\t\temit mouseChanged(mousePos, evPressed ? Qt::LeftButton : 0);\n"
    "\t\t    }\n"
    "\t\t    evDirty = FALSE;\n"
    "\t\t}\n"
)
if old in text:
    text = text.replace(old, new, 1)
path.write_text(text)
PY
	python3 /work/board/opie/patch_qt_sources.py "$QT_SRC"
}

build_qt() {
	if [ ! -f "$QT_SRC/.be300-qt-built-v30" ] || [ ! -f "$QT_SRC/lib/libqte.so.${QT_VERSION}" ]; then
		echo "=== Building Qt/Embedded ${QT_VERSION} for BE-300 ==="
		(
			cd "$QT_SRC"
			export QTDIR="$QT_SRC"
			export PATH="$QTDIR/bin:$PATH"
			echo yes | ./configure \
				-platform linux-generic-g++ \
				-xplatform linux-be300-g++ \
				-shared -release -qconfig qpe \
				-depths 16 -no-g++-exceptions -no-thread \
				-gif -qt-zlib -qt-libpng -no-jpeg \
				-no-xkb -no-sm -no-xft -no-qvfb \
				>"$QT_BUILD_LOG" 2>&1 || exit 1
			make -j"$(nproc)" >>"$QT_BUILD_LOG" 2>&1 || exit 1
			touch "$QT_SRC/.be300-qt-built-v30"
		) || {
			tail -80 "$QT_BUILD_LOG"
			exit 1
		}
		if [ ! -f "$QT_SRC/lib/libqte.so.${QT_VERSION}" ]; then
			tail -80 "$QT_BUILD_LOG"
			echo "ERROR: Qt/Embedded target library was not created" >&2
			exit 1
		fi
	fi
}

patch_qt_host_source() {
	cp "$OPIE_SRC/qt/qconfig-qpe.h" "$QT_HOST_SRC/src/tools/qconfig-qpe.h"
	QT_HOST_SRC="$QT_HOST_SRC" python3 - <<'PY'
import os
from pathlib import Path

root = Path(os.environ["QT_HOST_SRC"])

path = root / "configs/linux-generic-g++-shared"
text = path.read_text()
text = text.replace("-pipe -DQWS -fno-exceptions",
                    "-pipe -DQWS -std=gnu++98 -fpermissive -fno-exceptions")
path.write_text(text)

path = root / "src/kernel/qwindowsystem_qws.h"
text = path.read_text()
needle = "class QWSMouseHandler;\nstruct QWSCommandStruct;\n"
replacement = (
    "class QWSMouseHandler;\n"
    "class QWSInputMethod;\n"
    "class QWSGestureMethod;\n"
    "struct QWSCommandStruct;\n"
)
if needle in text and replacement not in text:
    text = text.replace(needle, replacement, 1)
path.write_text(text)

path = root / "src/kernel/qpixmapcache.cpp"
text = path.read_text()
old = "# include <asm/page.h> // PAGE_SIZE,PAGE_MASK,PAGE_ALIGN\n"
new = (
    "# ifndef PAGE_SIZE\n"
    "# define PAGE_SIZE 4096\n"
    "# endif\n"
    "# ifndef PAGE_MASK\n"
    "# define PAGE_MASK (~(PAGE_SIZE-1))\n"
    "# endif\n"
)
if old in text:
    text = text.replace(old, new, 1)
path.write_text(text)

for rel in ("include/qvaluestack.h", "src/tools/qvaluestack.h"):
    path = root / rel
    if not path.exists():
        continue
    text = path.read_text()
    text = text.replace("this->this->append", "this->append")
    text = text.replace("this->this->remove", "this->remove")
    text = text.replace("void  push( const T& d ) { append(d); }",
                        "void  push( const T& d ) { this->append(d); }")
    text = text.replace("remove( this->fromLast() );",
                        "this->remove( this->fromLast() );")
    text = text.replace("this->this->append", "this->append")
    text = text.replace("this->this->remove", "this->remove")
    path.write_text(text)

for rel in ("include/qgfxraster_qws.h", "src/kernel/qgfxraster_qws.h"):
    path = root / rel
    if not path.exists():
        continue
    text = path.read_text()
    old = "#include <unistd.h>\n#include <stdio.h>\n#include <stdlib.h>\n#include <math.h>\n"
    new = (
        "#ifndef QT_MOC_CPP\n"
        "#include <unistd.h>\n"
        "#include <stdio.h>\n"
        "#include <stdlib.h>\n"
        "#include <math.h>\n"
        "#endif\n"
    )
    if old in text:
        text = text.replace(old, new, 1)
    path.write_text(text)
PY
}

build_qt_host_tools() {
	if [ -x "$QT_SRC/bin/uic" ]; then
		return
	fi

	echo "=== Building host Qt/Embedded uic for OPIE ==="
	if [ -d "$QT_HOST_SRC" ] && [ ! -f "$QT_HOST_SRC/.be300-host-configured-v6" ]; then
		rm -rf "$QT_HOST_SRC"
	fi
	if [ ! -d "$QT_HOST_SRC" ]; then
		rm -rf "$QT_HOST_SRC"
		tar xzf "$QT_ARCHIVE" -C /work
		mv "/work/qt-${QT_VERSION}" "$QT_HOST_SRC"
	fi
	make_generated_tree_writable "$QT_HOST_SRC"
	patch_qt_host_source
	(
		cd "$QT_HOST_SRC"
		export QTDIR="$QT_HOST_SRC"
		export PATH="$QTDIR/bin:$PATH"
		if [ ! -f .be300-host-configured-v6 ]; then
			echo yes | ./configure \
				-platform linux-generic-g++ \
				-shared -release \
				-depths 16 -no-g++-exceptions -no-thread \
				-gif -qt-zlib -qt-libpng -no-jpeg \
				-no-xkb -no-sm -no-xft -no-qvfb \
				>"$QT_HOST_BUILD_LOG" 2>&1 || exit 1
			touch .be300-host-configured-v6
		fi
		make src-moc >>"$QT_HOST_BUILD_LOG" 2>&1 || exit 1
		make -C src -j"$(nproc)" >>"$QT_HOST_BUILD_LOG" 2>&1 || exit 1
		make -C tools/designer/uic >>"$QT_HOST_BUILD_LOG" 2>&1 || exit 1
	) || {
		tail -120 "$QT_HOST_BUILD_LOG"
		exit 1
	}
	cp "$QT_HOST_SRC/bin/uic" "$QT_SRC/bin/uic"
	chmod +x "$QT_SRC/bin/uic"
}

patch_opie_source() {
	make_generated_tree_writable "$OPIE_SRC"
	OPIE_SRC="$OPIE_SRC" python3 - <<'PY'
import os
import re
from pathlib import Path

root = Path(os.environ["OPIE_SRC"])

path = root / "Makefile"
if path.exists():
    text = path.read_text()
    text = text.replace("./scripts/kconfig/conf -s ./config.in",
                        "./scripts/kconfig/conf -o ./config.in")
    path.write_text(text)

for rel in ("qmake/include/qvaluestack.h",):
    path = root / rel
    if not path.exists():
        continue
    text = path.read_text()
    text = text.replace("this->this->append", "this->append")
    text = text.replace("this->this->remove", "this->remove")
    text = text.replace("void  push( const T& d ) { append(d); }",
                        "void  push( const T& d ) { this->append(d); }")
    text = text.replace("remove( this->fromLast() );",
                        "this->remove( this->fromLast() );")
    text = text.replace("this->this->append", "this->append")
    text = text.replace("this->this->remove", "this->remove")
    path.write_text(text)

path = root / "library/qpeapplication.cpp"
if path.exists():
    text = path.read_text()
    if "#include <fcntl.h>" not in text:
        text = text.replace("#include <unistd.h>\n", "#include <unistd.h>\n#include <fcntl.h>\n", 1)
    if "#include <stdio.h>" not in text:
        text = text.replace("#include <unistd.h>\n", "#include <unistd.h>\n#include <stdio.h>\n", 1)
    if "[be300-qpeapp]" not in text:
        text = text.replace(
            "    {\n        Config cfg( \"qpe\" );\n",
            "    {\n        fprintf(stderr, \"[be300-qpeapp] data ctor start\\n\");\n"
            "        Config cfg( \"qpe\" );\n",
            1,
        )
        text = text.replace(
            "        saveWindowsPos = cfg.readBoolEntry( \"AllowWindowed\", false );\n",
            "        saveWindowsPos = cfg.readBoolEntry( \"AllowWindowed\", false );\n"
            "        fprintf(stderr, \"[be300-qpeapp] data ctor done\\n\");\n",
            1,
        )
        text = text.replace(
            "    QPixmapCache::setCacheLimit(256); // sensible default for smaller devices.\n",
            "    fprintf(stderr, \"[be300-qpeapp] ctor body start\\n\");\n"
            "    QPixmapCache::setCacheLimit(256); // sensible default for smaller devices.\n"
            "    fprintf(stderr, \"[be300-qpeapp] cache limit set\\n\");\n",
            1,
        )
        text = text.replace(
            "    qInstallMsgHandler(qtopiaMsgHandler);\n\n    d = new QPEApplicationData;\n",
            "    qInstallMsgHandler(qtopiaMsgHandler);\n"
            "    fprintf(stderr, \"[be300-qpeapp] msg handler set\\n\");\n\n"
            "    d = new QPEApplicationData;\n"
            "    fprintf(stderr, \"[be300-qpeapp] data allocated\\n\");\n",
            1,
        )
        text = text.replace(
            "    d->loadTextCodecs();\n    d->loadImageCodecs();\n\n    setFont( QFont( d->fontFamily, d->fontSize ) );\n",
            "    fprintf(stderr, \"[be300-qpeapp] load text codecs\\n\");\n"
            "    d->loadTextCodecs();\n"
            "    fprintf(stderr, \"[be300-qpeapp] load image codecs\\n\");\n"
            "    d->loadImageCodecs();\n\n"
            "    fprintf(stderr, \"[be300-qpeapp] set font size=%d\\n\", d->fontSize);\n"
            "    setFont( QFont( d->fontFamily, d->fontSize ) );\n"
            "    fprintf(stderr, \"[be300-qpeapp] font set\\n\");\n",
            1,
        )
        text = text.replace(
            "    AppLnk::setSmallIconSize( d->smallIconSize );\n    AppLnk::setBigIconSize( d->bigIconSize );\n\n    QMimeSourceFactory::setDefaultFactory( new ResourceMimeFactory );\n",
            "    AppLnk::setSmallIconSize( d->smallIconSize );\n"
            "    AppLnk::setBigIconSize( d->bigIconSize );\n"
            "    fprintf(stderr, \"[be300-qpeapp] icon sizes set\\n\");\n\n"
            "    QMimeSourceFactory::setDefaultFactory( new ResourceMimeFactory );\n"
            "    fprintf(stderr, \"[be300-qpeapp] mime factory set\\n\");\n",
            1,
        )
        text = text.replace(
            "    sysChannel = new QCopChannel( \"QPE/System\", this );\n",
            "    fprintf(stderr, \"[be300-qpeapp] create sys channel\\n\");\n"
            "    sysChannel = new QCopChannel( \"QPE/System\", this );\n"
            "    fprintf(stderr, \"[be300-qpeapp] sys channel created\\n\");\n",
            1,
        )
        text = text.replace(
            "#else\n    initApp( argc, argv );\n#endif\n#ifdef Q_WS_QWS\n",
            "#else\n"
            "    fprintf(stderr, \"[be300-qpeapp] initApp\\n\");\n"
            "    initApp( argc, argv );\n"
            "    fprintf(stderr, \"[be300-qpeapp] initApp done\\n\");\n"
            "#endif\n#ifdef Q_WS_QWS\n",
            1,
        )
        text = text.replace(
            "    FontDatabase::loadRenderers();\n#endif\n#ifndef QT_NO_TRANSLATION\n",
            "    fprintf(stderr, \"[be300-qpeapp] load font renderers\\n\");\n"
            "    FontDatabase::loadRenderers();\n"
            "    fprintf(stderr, \"[be300-qpeapp] load font renderers done\\n\");\n"
            "#endif\n#ifndef QT_NO_TRANSLATION\n",
            1,
        )
        text = text.replace(
            "    qtopia_loadTranslations(qms);\n#endif\n\n    applyStyle();\n\n    if ( type() == GuiServer ) {\n        setVolume();\n    }\n\n    installEventFilter( this );\n\n    QPEMenuToolFocusManager::initialize();\n",
            "    fprintf(stderr, \"[be300-qpeapp] load translations\\n\");\n"
            "    qtopia_loadTranslations(qms);\n"
            "    fprintf(stderr, \"[be300-qpeapp] load translations done\\n\");\n"
            "#endif\n\n"
            "    fprintf(stderr, \"[be300-qpeapp] apply style\\n\");\n"
            "    applyStyle();\n"
            "    fprintf(stderr, \"[be300-qpeapp] apply style done\\n\");\n\n"
            "    if ( type() == GuiServer ) {\n"
            "        fprintf(stderr, \"[be300-qpeapp] set volume\\n\");\n"
            "        setVolume();\n"
            "        fprintf(stderr, \"[be300-qpeapp] set volume done\\n\");\n"
            "    }\n\n"
            "    installEventFilter( this );\n"
            "    fprintf(stderr, \"[be300-qpeapp] event filter installed\\n\");\n\n"
            "    QPEMenuToolFocusManager::initialize();\n"
            "    fprintf(stderr, \"[be300-qpeapp] ctor done\\n\");\n",
            1,
        )
    path.write_text(text)

path = root / "library/alarmserver.cpp"
if path.exists():
    text = path.read_text()
    text = text.replace(
        "ds << it.current()->UTCtime;",
        "Q_INT64 utc = (Q_INT64)it.current()->UTCtime;\n\t\t\tds << utc;",
    )
    text = text.replace(
        "ds >> newTimerEventItem->UTCtime;",
        "Q_INT64 utc;\n\t\t\tds >> utc;\n\t\t\tnewTimerEventItem->UTCtime = (time_t)utc;",
    )
    path.write_text(text)

path = root / "library/qmath.c"
if path.exists():
    text = path.read_text()
    if "#define MAXDOUBLE DBL_MAX" not in text:
        text = text.replace(
            "#include <float.h>\n",
            "#include <float.h>\n#ifndef MAXDOUBLE\n#define MAXDOUBLE DBL_MAX\n#endif\n",
            1,
        )
    path.write_text(text)

path = root / "library/power.cpp"
if path.exists():
    text = path.read_text().replace("#include <cmath>", "#include <math.h>")
    path.write_text(text)

path = root / "core/pim/todo/tableview.cpp"
if path.exists():
    text = path.read_text()
    text = text.replace("#include <cmath>", "#include <math.h>")
    text = text.replace("#include <cctype>", "#include <ctype.h>")
    path.write_text(text)

for rel, replacements in {
    "library/backend/event.cpp": (
        ("QString::number( r.endDateUTC ? r.endDateUTC : time( 0 ) )",
         "QString::number( (long)( r.endDateUTC ? r.endDateUTC : time( 0 ) ) )"),
        ("QString::number( r.createTime )",
         "QString::number( (long)r.createTime )"),
        ("QString::number( TimeConversion::toUTC( start() ) )",
         "QString::number( (long)TimeConversion::toUTC( start() ) )"),
        ("QString::number( TimeConversion::toUTC( end() ) )",
         "QString::number( (long)TimeConversion::toUTC( end() ) )"),
        ("QString::number( repeatPattern().endDateUTC )",
         "QString::number( (long)repeatPattern().endDateUTC )"),
        ("QString::number( startUTC )",
         "QString::number( (long)startUTC )"),
        ("QString::number( endUTC )",
         "QString::number( (long)endUTC )"),
    ),
    "noncore/unsupported/libopie/pim/orecur.cpp": (
        ("QString::number( OTimeZone::utc().fromUTCDateTime( QDateTime( data->end, QTime(12,0,0) ) ) )",
         "QString::number( (long)OTimeZone::utc().fromUTCDateTime( QDateTime( data->end, QTime(12,0,0) ) ) )"),
        ("QString::number( OTimeZone::utc().fromUTCDateTime( data->create ) )",
         "QString::number( (long)OTimeZone::utc().fromUTCDateTime( data->create ) )"),
    ),
    "noncore/unsupported/libopie/pim/odatebookaccessbackend_xml.cpp": (
        ("QString::number( zone.fromUTCDateTime( zone.toDateTime( ev.startDateTime(), OTimeZone::utc() ) ) )",
         "QString::number( (long)zone.fromUTCDateTime( zone.toDateTime( ev.startDateTime(), OTimeZone::utc() ) ) )"),
        ("QString::number( zone.fromUTCDateTime( zone.toDateTime( ev.endDateTime()  , OTimeZone::utc() ) ) )",
         "QString::number( (long)zone.fromUTCDateTime( zone.toDateTime( ev.endDateTime()  , OTimeZone::utc() ) ) )"),
    ),
    "noncore/unsupported/libopie/pim/oevent.cpp": (
        ("QString::number( zone.fromUTCDateTime( zone.toDateTime(  startDateTime(), OTimeZone::utc() ) ) )",
         "QString::number( (long)zone.fromUTCDateTime( zone.toDateTime(  startDateTime(), OTimeZone::utc() ) ) )"),
        ("QString::number( zone.fromUTCDateTime( zone.toDateTime(  endDateTime(), OTimeZone::utc() ) ) )",
         "QString::number( (long)zone.fromUTCDateTime( zone.toDateTime(  endDateTime(), OTimeZone::utc() ) ) )"),
    ),
    "libopie2/opiepim/core/opimevent.cpp": (
        ("QString::number( zone.fromDateTime( startDateTime()))",
         "QString::number( (long)zone.fromDateTime( startDateTime()))"),
        ("QString::number( zone.fromDateTime(   endDateTime() ))",
         "QString::number( (long)zone.fromDateTime(   endDateTime() ))"),
    ),
    "libopie2/opiepim/core/opimrecurrence.cpp": (
        ("QString::number( OPimTimeZone::current().fromDateTime( QDateTime( data->end, QTime(12,0,0) ) ) )",
         "QString::number( (long)OPimTimeZone::current().fromDateTime( QDateTime( data->end, QTime(12,0,0) ) ) )"),
        ("QString::number( OPimTimeZone::current().fromDateTime( data->create ) )",
         "QString::number( (long)OPimTimeZone::current().fromDateTime( data->create ) )"),
    ),
    "libopie2/opiepim/backend/opimchangelog_sql.cpp": (
        ("QString::number(t)",
         "QString::number((long)t)"),
    ),
}.items():
    path = root / rel
    if not path.exists():
        continue
    text = path.read_text()
    for old, new in replacements:
        text = text.replace(old, new)
    path.write_text(text)

path = root / "core/launcher/main.cpp"
if path.exists():
    text = path.read_text()
    if "be300_qpe_stage" not in text:
        text = text.replace(
            "void create_pidfile();\nvoid remove_pidfile();\n",
            "void create_pidfile();\nvoid remove_pidfile();\n\n"
            "static const char *be300_qpe_stage = \"startup\";\n"
            "#define BE300_QPE_STAGE(s) do { be300_qpe_stage = (s); fprintf(stderr, \"[be300-qpe] %s\\n\", be300_qpe_stage); fflush(stderr); } while (0)\n",
            1,
        )
        text = text.replace(
            "qDebug( \"D'oh! QPE Server process got SIGNAL %d. Trying to exit gracefully...\", sig );",
            "fprintf(stderr, \"D'oh! QPE Server process got SIGNAL %d at stage %s. Trying to exit gracefully...\\n\", sig, be300_qpe_stage );",
            1,
        )
        text = text.replace("    cleanup();\n    initEnvironment();\n",
                            "    BE300_QPE_STAGE(\"cleanup\");\n    cleanup();\n    BE300_QPE_STAGE(\"initEnvironment\");\n    initEnvironment();\n",
                            1)
        text = text.replace("#ifdef QWS\n    QWSServer::setDesktopBackground( QImage() );\n#endif\n    ServerApplication a",
                            "#ifdef QWS\n    BE300_QPE_STAGE(\"setDesktopBackground\");\n    QWSServer::setDesktopBackground( QImage() );\n#endif\n    BE300_QPE_STAGE(\"ServerApplication\");\n    ServerApplication a",
                            1)
        text = text.replace("    initKeyboard();\n\n    bool firstUseShown = firstUse();",
                            "    BE300_QPE_STAGE(\"initKeyboard\");\n    initKeyboard();\n\n    BE300_QPE_STAGE(\"firstUse\");\n    bool firstUseShown = firstUse();",
                            1)
        text = text.replace("        QCopEnvelope e(\"QPE/System\", \"setBacklight(int)\" );",
                            "        BE300_QPE_STAGE(\"setBacklight\");\n        QCopEnvelope e(\"QPE/System\", \"setBacklight(int)\" );",
                            1)
        text = text.replace("    AlarmServer::initialize();\n    Server *s = new Server();\n    new SysFileMonitor(s);\n#ifdef QWS\n    Network::createServer(s);\n#endif\n    s->show();",
                            "    BE300_QPE_STAGE(\"AlarmServer::initialize\");\n    AlarmServer::initialize();\n    BE300_QPE_STAGE(\"new Server\");\n    Server *s = new Server();\n#ifndef QT_QWS_CASSIOPEIA\n    BE300_QPE_STAGE(\"new SysFileMonitor\");\n    new SysFileMonitor(s);\n#else\n    BE300_QPE_STAGE(\"skip SysFileMonitor\");\n#endif\n#ifdef QWS\n    BE300_QPE_STAGE(\"Network::createServer\");\n    Network::createServer(s);\n#endif\n    BE300_QPE_STAGE(\"server show\");\n    s->show();",
                            1)
        text = text.replace("    create_pidfile();\n    odebug << \"--> mainloop in\" << oendl;\n    int rv = a.exec();",
                            "    BE300_QPE_STAGE(\"create_pidfile\");\n    create_pidfile();\n    BE300_QPE_STAGE(\"mainloop\");\n    odebug << \"--> mainloop in\" << oendl;\n    int rv = a.exec();",
                            1)
    text = text.replace(
        "#define BE300_QPE_STAGE(s) do { be300_qpe_stage = (s); qDebug(\"[be300-qpe] %s\", be300_qpe_stage); } while (0)\n",
        "#define BE300_QPE_STAGE(s) do { be300_qpe_stage = (s); fprintf(stderr, \"[be300-qpe] %s\\n\", be300_qpe_stage); fflush(stderr); } while (0)\n",
    )
    text = text.replace(
        "qDebug( \"D'oh! QPE Server process got SIGNAL %d at stage %s. Trying to exit gracefully...\", sig, be300_qpe_stage );",
        "fprintf(stderr, \"D'oh! QPE Server process got SIGNAL %d at stage %s. Trying to exit gracefully...\\n\", sig, be300_qpe_stage );",
    )
    text = text.replace(
        "    BE300_QPE_STAGE(\"new Server\");\n"
        "    Server *s = new Server();\n"
        "    BE300_QPE_STAGE(\"new SysFileMonitor\");\n"
        "    new SysFileMonitor(s);\n"
        "#ifdef QWS\n"
        "    BE300_QPE_STAGE(\"Network::createServer\");\n"
        "    Network::createServer(s);\n"
        "#endif\n"
        "    BE300_QPE_STAGE(\"server show\");\n"
        "    s->show();",
        "    BE300_QPE_STAGE(\"new Server\");\n"
        "    Server *s = new Server();\n"
        "#ifndef QT_QWS_CASSIOPEIA\n"
        "    BE300_QPE_STAGE(\"new SysFileMonitor\");\n"
        "    new SysFileMonitor(s);\n"
        "#else\n"
        "    BE300_QPE_STAGE(\"skip SysFileMonitor\");\n"
        "#endif\n"
        "#ifdef QWS\n"
        "    BE300_QPE_STAGE(\"Network::createServer\");\n"
        "    Network::createServer(s);\n"
        "#endif\n"
        "    BE300_QPE_STAGE(\"server show\");\n"
        "    s->show();",
    )
    if "BE300 skips OPIE first-use wizard" not in text:
        text = text.replace(
            "static bool firstUse()\n{\n",
            "static bool firstUse()\n"
            "{\n"
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "    /* BE300 skips OPIE first-use wizard; the image ships\n"
            "       calibrated input defaults and should land directly on\n"
            "       the launcher. */\n"
            "    return FALSE;\n"
            "#endif\n",
            1,
        )
    if "BE300 skips invalid-date prompt" not in text:
        text = text.replace(
            "    if ( !firstUseShown ) {\n        Config config( \"qpe\" );\n",
            "#ifndef QT_QWS_CASSIOPEIA\n"
            "    if ( !firstUseShown ) {\n        Config config( \"qpe\" );\n",
            1,
        )
        text = text.replace(
            "    }\n\n    BE300_QPE_STAGE(\"create_pidfile\");\n",
            "    }\n"
            "#else\n"
            "    /* BE300 skips invalid-date prompt; RTC handoff is emulator\n"
            "       dependent and should not block the desktop at boot. */\n"
            "#endif\n\n"
            "    BE300_QPE_STAGE(\"create_pidfile\");\n",
            1,
        )
    text = text.replace(
        "    char buf[128];\n"
        "    int n = snprintf(buf, sizeof(buf),\n"
        "        \"D'oh! qpe got SIG %d code=%d si_addr=%p stage=%s\\n\",\n"
        "        sig, info ? info->si_code : -1,\n"
        "        info ? info->si_addr : (void*)0, be300_qpe_stage);\n"
        "    write(2, buf, n);\n",
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    const char msg[] = \"D'oh! qpe got signal\\n\";\n"
        "    write(2, msg, sizeof(msg) - 1);\n"
        "#else\n"
        "    char buf[128];\n"
        "    int n = snprintf(buf, sizeof(buf),\n"
        "        \"D'oh! qpe got SIG %d code=%d si_addr=%p stage=%s\\n\",\n"
        "        sig, info ? info->si_code : -1,\n"
        "        info ? info->si_addr : (void*)0, be300_qpe_stage);\n"
        "    write(2, buf, n);\n"
        "#endif\n",
    )
    text = text.replace(
        "        sigaction(SIGSEGV, &sa, 0);\n"
        "        sigaction(SIGBUS, &sa, 0);\n"
        "        sigaction(SIGILL, &sa, 0);\n"
        "        sigaction(SIGTERM, &sa, 0);\n"
        "        sigaction(SIGINT, &sa, 0);\n",
        "#ifndef QT_QWS_CASSIOPEIA\n"
        "        sigaction(SIGSEGV, &sa, 0);\n"
        "        sigaction(SIGBUS, &sa, 0);\n"
        "        sigaction(SIGILL, &sa, 0);\n"
        "#endif\n"
        "        sigaction(SIGTERM, &sa, 0);\n"
        "        sigaction(SIGINT, &sa, 0);\n",
    )
    path.write_text(text)

path = root / "core/launcher/serverapp.cpp"
if path.exists():
    text = path.read_text()
    if "#include <stdio.h>" not in text:
        text = text.replace("#include <stdlib.h>\n", "#include <stdlib.h>\n#include <stdio.h>\n", 1)
    if "[be300-serverapp]" not in text:
        text = text.replace(
            "{\n    ms_is_starting = true;\n",
            "{\n    fprintf(stderr, \"[be300-serverapp] ctor body start\\n\");\n"
            "    ms_is_starting = true;\n"
            "    fprintf(stderr, \"[be300-serverapp] state init\\n\");\n",
            1,
        )
        text = text.replace(
            "    QPixmapCache::setCacheLimit(512);\n\n    m_ps = new PowerStatus;\n    m_ps_last = new PowerStatus;\n    pa = new DesktopPowerAlerter( 0 );\n",
            "    QPixmapCache::setCacheLimit(512);\n"
            "    fprintf(stderr, \"[be300-serverapp] pixmap cache set\\n\");\n\n"
            "    fprintf(stderr, \"[be300-serverapp] new PowerStatus\\n\");\n"
            "    m_ps = new PowerStatus;\n"
            "    fprintf(stderr, \"[be300-serverapp] new PowerStatus last\\n\");\n"
            "    m_ps_last = new PowerStatus;\n"
            "    fprintf(stderr, \"[be300-serverapp] new DesktopPowerAlerter\\n\");\n"
            "    pa = new DesktopPowerAlerter( 0 );\n"
            "    fprintf(stderr, \"[be300-serverapp] power widgets ready\\n\");\n",
            1,
        )
        text = text.replace(
            "    m_apm_timer = new QTimer( this );\n    connect(m_apm_timer, SIGNAL( timeout() ),\n            this, SLOT( apmTimeout() ) );\n\n    reloadPowerWarnSettings();\n\n    QCopChannel *channel = new QCopChannel( \"QPE/System\", this );\n",
            "    fprintf(stderr, \"[be300-serverapp] new apm timer\\n\");\n"
            "    m_apm_timer = new QTimer( this );\n"
            "    connect(m_apm_timer, SIGNAL( timeout() ),\n"
            "            this, SLOT( apmTimeout() ) );\n"
            "    fprintf(stderr, \"[be300-serverapp] apm timer connected\\n\");\n\n"
            "    fprintf(stderr, \"[be300-serverapp] reload power warn settings\\n\");\n"
            "    reloadPowerWarnSettings();\n"
            "    fprintf(stderr, \"[be300-serverapp] power warn settings done\\n\");\n\n"
            "    fprintf(stderr, \"[be300-serverapp] create system channel\\n\");\n"
            "    QCopChannel *channel = new QCopChannel( \"QPE/System\", this );\n",
            1,
        )
        text = text.replace(
            "    connect(channel, SIGNAL(received(const QCString&,const QByteArray&) ),\n            this, SLOT(systemMessage(const QCString&,const QByteArray&) ) );\n\n    channel = new QCopChannel(\"QPE/Launcher\", this );\n",
            "    connect(channel, SIGNAL(received(const QCString&,const QByteArray&) ),\n"
            "            this, SLOT(systemMessage(const QCString&,const QByteArray&) ) );\n"
            "    fprintf(stderr, \"[be300-serverapp] system channel ready\\n\");\n\n"
            "    fprintf(stderr, \"[be300-serverapp] create launcher channel\\n\");\n"
            "    channel = new QCopChannel(\"QPE/Launcher\", this );\n",
            1,
        )
        text = text.replace(
            "    connect(channel, SIGNAL(received(const QCString&,const QByteArray&) ),\n            this, SLOT(launcherMessage(const QCString&,const QByteArray&) ) );\n\n    channel = new QCopChannel(\"QPE/Desktop\", this );\n",
            "    connect(channel, SIGNAL(received(const QCString&,const QByteArray&) ),\n"
            "            this, SLOT(launcherMessage(const QCString&,const QByteArray&) ) );\n"
            "    fprintf(stderr, \"[be300-serverapp] launcher channel ready\\n\");\n\n"
            "    fprintf(stderr, \"[be300-serverapp] create desktop channel\\n\");\n"
            "    channel = new QCopChannel(\"QPE/Desktop\", this );\n",
            1,
        )
        text = text.replace(
            "    connect(channel, SIGNAL(received(const QCString&,const QByteArray&) ),\n            this, SLOT(desktopMessage(const QCString&,const QByteArray&) ) );\n\n    m_screensaver = new OpieScreenSaver();\n    m_screensaver->setInterval( -1 );\n    QWSServer::setScreenSaver( m_screensaver );\n\n    connect( qApp, SIGNAL( volumeChanged(bool) ),\n             this, SLOT( rereadVolumes() ) );\n",
            "    connect(channel, SIGNAL(received(const QCString&,const QByteArray&) ),\n"
            "            this, SLOT(desktopMessage(const QCString&,const QByteArray&) ) );\n"
            "    fprintf(stderr, \"[be300-serverapp] desktop channel ready\\n\");\n\n"
            "    fprintf(stderr, \"[be300-serverapp] new screensaver\\n\");\n"
            "    m_screensaver = new OpieScreenSaver();\n"
            "    fprintf(stderr, \"[be300-serverapp] set screensaver interval\\n\");\n"
            "    m_screensaver->setInterval( -1 );\n"
            "    fprintf(stderr, \"[be300-serverapp] install screensaver\\n\");\n"
            "    QWSServer::setScreenSaver( m_screensaver );\n"
            "    fprintf(stderr, \"[be300-serverapp] screensaver installed\\n\");\n\n"
            "    connect( qApp, SIGNAL( volumeChanged(bool) ),\n"
            "             this, SLOT( rereadVolumes() ) );\n"
            "    fprintf(stderr, \"[be300-serverapp] ctor done\\n\");\n",
            1,
        )
    if "BE300 skips the APM warning timer" not in text:
        text = text.replace(
            "void ServerApplication::reloadPowerWarnSettings ( )\n{\n",
            "void ServerApplication::reloadPowerWarnSettings ( )\n"
            "{\n"
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "    /* BE300 skips the APM warning timer; there is no useful APM\n"
            "       source in this image, and the legacy probe path can block\n"
            "       before the launcher paints. */\n"
            "    if ( m_apm_timer )\n"
            "        m_apm_timer->stop();\n"
            "    m_powerVeryLow = 10;\n"
            "    m_powerCritical = 5;\n"
            "    return;\n"
            "#endif\n",
            1,
        )
    if "BE300 skips APM polling" not in text:
        text = text.replace(
            "void ServerApplication::apmTimeout()\n{\n",
            "void ServerApplication::apmTimeout()\n"
            "{\n"
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "    /* BE300 skips APM polling; the image has no useful APM\n"
            "       source, and the launcher should not block on power state\n"
            "       before the desktop is visible. */\n"
            "    return;\n"
            "#endif\n",
            1,
        )
    if "[be300-serverapp] key filter new" not in text:
        text = text.replace(
            "    kf = new KeyFilter(this);\n\n"
            "    connect( kf, SIGNAL(launch()), this, SIGNAL(launch()) );\n",
            "    fprintf(stderr, \"[be300-serverapp] key filter new\\n\");\n"
            "    kf = new KeyFilter(this);\n"
            "    fprintf(stderr, \"[be300-serverapp] key filter ready\\n\");\n\n"
            "    fprintf(stderr, \"[be300-serverapp] connect key filter\\n\");\n"
            "    connect( kf, SIGNAL(launch()), this, SIGNAL(launch()) );\n",
            1,
        )
        text = text.replace(
            "    connect( this, SIGNAL(power() ),\n"
            "             SLOT(togglePower() ) );\n\n"
            "    rereadVolumes();\n\n"
            "    serverApp = this;\n\n"
            "    apmTimeout();\n"
            "    grabKeyboard();\n\n"
            "    /* make sure the event filter is installed */  /* std::limits<short>::max() when you've stdc++ */\n"
            "    const ODeviceButton* but = ODevice::inst()->buttonForKeycode( SHRT_MAX );\n"
            "    Q_CONST_UNUSED( but )\n",
            "    connect( this, SIGNAL(power() ),\n"
            "             SLOT(togglePower() ) );\n"
            "    fprintf(stderr, \"[be300-serverapp] key filter connected\\n\");\n\n"
            "    fprintf(stderr, \"[be300-serverapp] rereadVolumes\\n\");\n"
            "    rereadVolumes();\n"
            "    fprintf(stderr, \"[be300-serverapp] rereadVolumes done\\n\");\n\n"
            "    serverApp = this;\n"
            "    fprintf(stderr, \"[be300-serverapp] serverApp set\\n\");\n\n"
            "    apmTimeout();\n"
            "    fprintf(stderr, \"[be300-serverapp] apmTimeout done\\n\");\n"
            "#ifndef QT_QWS_CASSIOPEIA\n"
            "    grabKeyboard();\n"
            "#else\n"
            "    fprintf(stderr, \"[be300-serverapp] skip keyboard grab\\n\");\n"
            "#endif\n"
            "    fprintf(stderr, \"[be300-serverapp] keyboard grab done\\n\");\n\n"
            "#ifndef QT_QWS_CASSIOPEIA\n"
            "    /* make sure the event filter is installed */  /* std::limits<short>::max() when you've stdc++ */\n"
            "    const ODeviceButton* but = ODevice::inst()->buttonForKeycode( SHRT_MAX );\n"
            "    Q_CONST_UNUSED( but )\n"
            "#else\n"
            "    fprintf(stderr, \"[be300-serverapp] skip device button probe\\n\");\n"
            "#endif\n"
            "    fprintf(stderr, \"[be300-serverapp] ctor tail done\\n\");\n",
            1,
        )
    path.write_text(text)

path = root / "core/launcher/server.cpp"
if path.exists():
    text = path.read_text()
    be300_date_block = (
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    last_today_show = QDate( 2000, 1, 1 );\n"
        "#else\n"
        "    last_today_show = QDate::currentDate();\n"
        "#endif\n"
        "    fprintf(stderr, \"[be300-server] date initialized\\n\");\n"
    )
    text = re.sub(
        r"(?:#ifdef QT_QWS_CASSIOPEIA\n"
        r"    last_today_show = QDate\( 2000, 1, 1 \);\n"
        r"#else\n)+"
        r"    last_today_show = QDate::currentDate\(\);\n"
        r"(?:#endif\n)+"
        r"    fprintf\(stderr, \"\[be300-server\] date initialized\\n\"\);\n",
        lambda _match: be300_date_block,
        text,
        count=1,
    )
    if "#include <stdio.h>" not in text:
        text = text.replace("#include <stdlib.h>\n", "#include <stdlib.h>\n#include <stdio.h>\n", 1)
    if "[be300-server]" not in text:
        text = text.replace(
            "{\n    Global::setBuiltinCommands(builtins);\n\n"
            "    tid_xfer = 0;\n",
            "{\n"
            "    fprintf(stderr, \"[be300-server] ctor body start\\n\");\n"
            "    Global::setBuiltinCommands(builtins);\n"
            "    fprintf(stderr, \"[be300-server] builtins set\\n\");\n\n"
            "    tid_xfer = 0;\n",
            1,
        )
        text = text.replace(
            "    last_today_show = QDate::currentDate();\n",
            "    last_today_show = QDate::currentDate();\n"
            "    fprintf(stderr, \"[be300-server] date initialized\\n\");\n",
            1,
        )
        text = text.replace(
            "    serverGui = new Launcher;\n    serverGui->createGUI();\n\n"
            "    docList = new DocumentList( serverGui );\n    appLauncher = new AppLauncher(this);\n",
            "    fprintf(stderr, \"[be300-server] new Launcher\\n\");\n"
            "    serverGui = new Launcher;\n"
            "    fprintf(stderr, \"[be300-server] Launcher allocated\\n\");\n"
            "    fprintf(stderr, \"[be300-server] createGUI\\n\");\n"
            "    serverGui->createGUI();\n"
            "    fprintf(stderr, \"[be300-server] createGUI done\\n\");\n\n"
            "    fprintf(stderr, \"[be300-server] new DocumentList\\n\");\n"
            "    docList = new DocumentList( serverGui );\n"
            "    fprintf(stderr, \"[be300-server] DocumentList allocated\\n\");\n"
            "    fprintf(stderr, \"[be300-server] new AppLauncher\\n\");\n"
            "    appLauncher = new AppLauncher(this);\n"
            "    fprintf(stderr, \"[be300-server] AppLauncher allocated\\n\");\n",
            1,
        )
        text = text.replace(
            "    storage = new StorageInfo( this );\n    connect( storage, SIGNAL(disksChanged()), this, SLOT(storageChanged()) );\n",
            "    fprintf(stderr, \"[be300-server] new StorageInfo\\n\");\n"
            "    storage = new StorageInfo( this );\n"
            "    fprintf(stderr, \"[be300-server] StorageInfo allocated\\n\");\n"
            "    connect( storage, SIGNAL(disksChanged()), this, SLOT(storageChanged()) );\n"
            "    fprintf(stderr, \"[be300-server] StorageInfo connected\\n\");\n",
            1,
        )
        text = text.replace(
            "    soundServerExited();\n\n"
            "    // start services\n"
            "    startTransferServer();\n"
            "    (void) new IrServer( this );\n\n"
            "    packageHandler = new PackageHandler( this );\n",
            "    fprintf(stderr, \"[be300-server] soundServerExited\\n\");\n"
            "    soundServerExited();\n"
            "    fprintf(stderr, \"[be300-server] soundServerExited done\\n\");\n\n"
            "    // start services\n"
            "    fprintf(stderr, \"[be300-server] startTransferServer\\n\");\n"
            "    startTransferServer();\n"
            "    fprintf(stderr, \"[be300-server] startTransferServer done\\n\");\n"
            "    fprintf(stderr, \"[be300-server] new IrServer\\n\");\n"
            "    (void) new IrServer( this );\n"
            "    fprintf(stderr, \"[be300-server] IrServer allocated\\n\");\n\n"
            "    fprintf(stderr, \"[be300-server] new PackageHandler\\n\");\n"
            "    packageHandler = new PackageHandler( this );\n"
            "    fprintf(stderr, \"[be300-server] PackageHandler allocated\\n\");\n",
            1,
        )
        text = text.replace(
            "    setGeometry( -10, -10, 9, 9 );\n\n"
            "    QCopChannel *channel = new QCopChannel(\"QPE/System\", this);\n",
            "    fprintf(stderr, \"[be300-server] setGeometry\\n\");\n"
            "    setGeometry( -10, -10, 9, 9 );\n"
            "    fprintf(stderr, \"[be300-server] setGeometry done\\n\");\n\n"
            "    fprintf(stderr, \"[be300-server] create system channel\\n\");\n"
            "    QCopChannel *channel = new QCopChannel(\"QPE/System\", this);\n",
            1,
        )
        text = text.replace(
            "    connect(channel, SIGNAL(received(const QCString&,const QByteArray&)),\n"
            "        this, SLOT(systemMsg(const QCString&,const QByteArray&)) );\n\n"
            "    QCopChannel *tbChannel = new QCopChannel( \"QPE/TaskBar\", this );\n",
            "    connect(channel, SIGNAL(received(const QCString&,const QByteArray&)),\n"
            "        this, SLOT(systemMsg(const QCString&,const QByteArray&)) );\n"
            "    fprintf(stderr, \"[be300-server] system channel ready\\n\");\n\n"
            "    fprintf(stderr, \"[be300-server] create taskbar channel\\n\");\n"
            "    QCopChannel *tbChannel = new QCopChannel( \"QPE/TaskBar\", this );\n",
            1,
        )
        text = text.replace(
            "    connect( qApp, SIGNAL(prepareForRestart()), this, SLOT(terminateServers()) );\n"
            "    connect( qApp, SIGNAL(timeChanged()), this, SLOT(pokeTimeMonitors()) );\n\n"
            "    preloadApps();\n",
            "    fprintf(stderr, \"[be300-server] taskbar channel ready\\n\");\n\n"
            "    connect( qApp, SIGNAL(prepareForRestart()), this, SLOT(terminateServers()) );\n"
            "    connect( qApp, SIGNAL(timeChanged()), this, SLOT(pokeTimeMonitors()) );\n"
            "    fprintf(stderr, \"[be300-server] qapp signals connected\\n\");\n\n"
            "    fprintf(stderr, \"[be300-server] preloadApps\\n\");\n"
            "    preloadApps();\n"
            "    fprintf(stderr, \"[be300-server] ctor done\\n\");\n",
            1,
        )
    if "#ifdef QT_QWS_CASSIOPEIA\n    last_today_show = QDate( 2000, 1, 1 );\n#else\n    last_today_show = QDate::currentDate();\n#endif" not in text:
        text = text.replace(
            "    last_today_show = QDate::currentDate();\n"
            "    fprintf(stderr, \"[be300-server] date initialized\\n\");\n",
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "    last_today_show = QDate( 2000, 1, 1 );\n"
            "#else\n"
            "    last_today_show = QDate::currentDate();\n"
            "#endif\n"
            "    fprintf(stderr, \"[be300-server] date initialized\\n\");\n",
            1,
        )
        text = text.replace(
            "    last_today_show = QDate::currentDate();\n",
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "    last_today_show = QDate( 2000, 1, 1 );\n"
            "#else\n"
            "    last_today_show = QDate::currentDate();\n"
            "#endif\n",
            1,
        )
    text = re.sub(
        r"(/\*    tid_today = startTimer\(3600\*2\*1000\);\*/\n)(.*?)(?=\n#warning FIXME support TempScreenSaverMode)",
        lambda match: match.group(1) + be300_date_block,
        text,
        count=1,
        flags=re.S,
    )
    if "[be300-server] skip AppLauncher" not in text:
        text = text.replace(
            "    fprintf(stderr, \"[be300-server] new AppLauncher\\n\");\n"
            "    appLauncher = new AppLauncher(this);\n"
            "    fprintf(stderr, \"[be300-server] AppLauncher allocated\\n\");\n"
            "    connect(appLauncher, SIGNAL(launched(int,const QString&)), this, SLOT(applicationLaunched(int,const QString&)) );\n"
            "    connect(appLauncher, SIGNAL(terminated(int,const QString&)), this, SLOT(applicationTerminated(int,const QString&)) );\n"
            "    connect(appLauncher, SIGNAL(connected(const QString&)), this, SLOT(applicationConnected(const QString&)) );\n",
            "#ifndef QT_QWS_CASSIOPEIA\n"
            "    fprintf(stderr, \"[be300-server] new AppLauncher\\n\");\n"
            "    appLauncher = new AppLauncher(this);\n"
            "    fprintf(stderr, \"[be300-server] AppLauncher allocated\\n\");\n"
            "    connect(appLauncher, SIGNAL(launched(int,const QString&)), this, SLOT(applicationLaunched(int,const QString&)) );\n"
            "    connect(appLauncher, SIGNAL(terminated(int,const QString&)), this, SLOT(applicationTerminated(int,const QString&)) );\n"
            "    connect(appLauncher, SIGNAL(connected(const QString&)), this, SLOT(applicationConnected(const QString&)) );\n"
            "#else\n"
            "    fprintf(stderr, \"[be300-server] skip AppLauncher\\n\");\n"
            "    appLauncher = 0;\n"
            "#endif\n",
            1,
        )
    if "[be300-server] skip AppLauncher" not in text:
        text = text.replace(
            "    docList = new DocumentList( serverGui );\n"
            "    appLauncher = new AppLauncher(this);\n"
            "    connect(appLauncher, SIGNAL(launched(int,const QString&)), this, SLOT(applicationLaunched(int,const QString&)) );\n"
            "    connect(appLauncher, SIGNAL(terminated(int,const QString&)), this, SLOT(applicationTerminated(int,const QString&)) );\n"
            "    connect(appLauncher, SIGNAL(connected(const QString&)), this, SLOT(applicationConnected(const QString&)) );\n",
            "    docList = new DocumentList( serverGui );\n"
            "#ifndef QT_QWS_CASSIOPEIA\n"
            "    appLauncher = new AppLauncher(this);\n"
            "    connect(appLauncher, SIGNAL(launched(int,const QString&)), this, SLOT(applicationLaunched(int,const QString&)) );\n"
            "    connect(appLauncher, SIGNAL(terminated(int,const QString&)), this, SLOT(applicationTerminated(int,const QString&)) );\n"
            "    connect(appLauncher, SIGNAL(connected(const QString&)), this, SLOT(applicationConnected(const QString&)) );\n"
            "#else\n"
            "    fprintf(stderr, \"[be300-server] skip AppLauncher\\n\");\n"
            "    appLauncher = 0;\n"
            "#endif\n",
            1,
        )
    if "[be300-server] skip optional services" not in text:
        text = text.replace(
            "    fprintf(stderr, \"[be300-server] soundServerExited\\n\");\n"
            "    soundServerExited();\n"
            "    fprintf(stderr, \"[be300-server] soundServerExited done\\n\");\n"
            "\n"
            "    // start services\n"
            "    fprintf(stderr, \"[be300-server] startTransferServer\\n\");\n"
            "    startTransferServer();\n"
            "    fprintf(stderr, \"[be300-server] startTransferServer done\\n\");\n"
            "    fprintf(stderr, \"[be300-server] new IrServer\\n\");\n"
            "    (void) new IrServer( this );\n"
            "    fprintf(stderr, \"[be300-server] IrServer allocated\\n\");\n"
            "\n"
            "    fprintf(stderr, \"[be300-server] new PackageHandler\\n\");\n"
            "    packageHandler = new PackageHandler( this );\n"
            "    fprintf(stderr, \"[be300-server] PackageHandler allocated\\n\");\n"
            "    connect(qApp, SIGNAL(activate(const Opie::Core::ODeviceButton*,bool)),\n"
            "            this,SLOT(activate(const Opie::Core::ODeviceButton*,bool)));\n",
            "#ifndef QT_QWS_CASSIOPEIA\n"
            "    fprintf(stderr, \"[be300-server] soundServerExited\\n\");\n"
            "    soundServerExited();\n"
            "    fprintf(stderr, \"[be300-server] soundServerExited done\\n\");\n"
            "\n"
            "    // start services\n"
            "    fprintf(stderr, \"[be300-server] startTransferServer\\n\");\n"
            "    startTransferServer();\n"
            "    fprintf(stderr, \"[be300-server] startTransferServer done\\n\");\n"
            "    fprintf(stderr, \"[be300-server] new IrServer\\n\");\n"
            "    (void) new IrServer( this );\n"
            "    fprintf(stderr, \"[be300-server] IrServer allocated\\n\");\n"
            "\n"
            "    fprintf(stderr, \"[be300-server] new PackageHandler\\n\");\n"
            "    packageHandler = new PackageHandler( this );\n"
            "    fprintf(stderr, \"[be300-server] PackageHandler allocated\\n\");\n"
            "    connect(qApp, SIGNAL(activate(const Opie::Core::ODeviceButton*,bool)),\n"
            "            this,SLOT(activate(const Opie::Core::ODeviceButton*,bool)));\n"
            "#else\n"
            "    fprintf(stderr, \"[be300-server] skip optional services\\n\");\n"
            "#endif\n",
            1,
        )
    if "[be300-server] skip preloadApps" not in text:
        text = text.replace(
            "    fprintf(stderr, \"[be300-server] preloadApps\\n\");\n"
            "    preloadApps();\n"
            "    fprintf(stderr, \"[be300-server] ctor done\\n\");\n",
            "#ifndef QT_QWS_CASSIOPEIA\n"
            "    fprintf(stderr, \"[be300-server] preloadApps\\n\");\n"
            "    preloadApps();\n"
            "#else\n"
            "    fprintf(stderr, \"[be300-server] skip preloadApps\\n\");\n"
            "#endif\n"
            "    fprintf(stderr, \"[be300-server] ctor done\\n\");\n",
            1,
        )
    text = text.replace(
        "void Server::show()\n"
        "{\n"
        "    ServerApplication::login(TRUE);\n"
        "    QWidget::show();\n"
        "}\n",
        "void Server::show()\n"
        "{\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    fprintf(stderr, \"[be300-server] skip Server::show widget\\n\");\n"
        "#else\n"
        "    ServerApplication::login(TRUE);\n"
        "    QWidget::show();\n"
        "#endif\n"
        "}\n",
        1,
    )
    path.write_text(text)

path = root / "library/backend/palmtopuidgen.h"
if path.exists():
    text = path.read_text(encoding="latin-1")
    if "BE300 lightweight UidGen" not in text:
        text = text.replace(
            "    int generate() const\n"
            "\t{\n"
            "\t    int id = sign * (int) ::time(NULL);\n"
            "\t    while ( ids.contains( id ) ) {\n"
            "\t\tid += sign;\n"
            "\n"
            "\t\t// check for overflow cases; if so, wrap back to beginning of\n"
            "\t\t// set ( -1 or 1 )\n"
            "\t\tif ( ( sign == -1 && id > 0 ) || ( sign == 1 && id < 0 ) )\n"
            "\t\t    id = sign;\n"
            "\t    }\n"
            "\t    return id;\n"
            "\t}\n"
            "\n"
            "    void store(int id) { ids.insert(id, TRUE); }\n"
            "    bool isUnique(int id) const { return (!ids.contains(id)); }\n",
            "    int generate() const\n"
            "\t{\n"
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "\t    /* BE300 lightweight UidGen: avoid the global QMap<int,bool>\n"
            "\t       during early qpe startup on the 16 MiB Linux 2.4 image. */\n"
            "\t    int id = sign * (int) ::time(NULL);\n"
            "\t    return id ? id : sign;\n"
            "#else\n"
            "\t    int id = sign * (int) ::time(NULL);\n"
            "\t    while ( ids.contains( id ) ) {\n"
            "\t\tid += sign;\n"
            "\n"
            "\t\t// check for overflow cases; if so, wrap back to beginning of\n"
            "\t\t// set ( -1 or 1 )\n"
            "\t\tif ( ( sign == -1 && id > 0 ) || ( sign == 1 && id < 0 ) )\n"
            "\t\t    id = sign;\n"
            "\t    }\n"
            "\t    return id;\n"
            "#endif\n"
            "\t}\n"
            "\n"
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "    void store(int) { }\n"
            "    bool isUnique(int) const { return true; }\n"
            "#else\n"
            "    void store(int id) { ids.insert(id, TRUE); }\n"
            "    bool isUnique(int id) const { return (!ids.contains(id)); }\n"
            "#endif\n",
            1,
        )
        if "BE300 lightweight UidGen" not in text:
            pattern = (
                r"    int generate\(\) const\s*\{\n"
                r".*?"
                r"    void store\(int id\) \{ ids\.insert\(id, TRUE\); \}\n"
                r"    bool isUnique\(int id\) const \{ return \(!ids\.contains\(id\)\); \}\n"
            )
            replacement = """    int generate() const
{
#ifdef QT_QWS_CASSIOPEIA
    /* BE300 lightweight UidGen: avoid the global QMap<int,bool>
       during early qpe startup on the 16 MiB Linux 2.4 image. */
    int id = sign * (int) ::time(NULL);
    return id ? id : sign;
#else
    int id = sign * (int) ::time(NULL);
    while ( ids.contains( id ) ) {
	id += sign;

	// check for overflow cases; if so, wrap back to beginning of
	// set ( -1 or 1 )
	if ( ( sign == -1 && id > 0 ) || ( sign == 1 && id < 0 ) )
	    id = sign;
    }
    return id;
#endif
}

#ifdef QT_QWS_CASSIOPEIA
    void store(int) { }
    bool isUnique(int) const { return true; }
#else
    void store(int id) { ids.insert(id, TRUE); }
    bool isUnique(int id) const { return (!ids.contains(id)); }
#endif
"""
            text, count = re.subn(pattern, replacement, text, count=1, flags=re.S)
            if count != 1:
                raise RuntimeError("failed to patch BE-300 UidGen")
    path.write_text(text, encoding="latin-1")

path = root / "library/timestring.cpp"
if path.exists():
    text = path.read_text(encoding="latin-1")
    if "BE300 simple DateFormat::wordDate" not in text:
        text = text.replace(
            "QString DateFormat::wordDate(const QDate &d, int v) const\n"
            "{\n",
            "QString DateFormat::wordDate(const QDate &d, int v) const\n"
            "{\n"
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "    /* BE300 simple DateFormat::wordDate: avoid the translated\n"
            "       QString-heavy path during 16 MiB qpe startup. */\n"
            "    (void)v;\n"
            "    QString date;\n"
            "    date.sprintf(\"%04d-%02d-%02d\", d.year(), d.month(), d.day());\n"
            "    return date;\n"
            "#else\n",
            1,
        )
        if "BE300 simple DateFormat::wordDate" not in text:
            raise RuntimeError("failed to patch BE-300 DateFormat::wordDate")
    if "BE300 simple DateFormat::wordDate" in text and "#endif\n}\n\n#ifndef QT_NO_DATASTREAM" not in text:
        text = text.replace(
            "\n}\n\n#ifndef QT_NO_DATASTREAM\nvoid DateFormat::save(QDataStream &d) const\n",
            "\n#endif\n}\n\n#ifndef QT_NO_DATASTREAM\nvoid DateFormat::save(QDataStream &d) const\n",
            1,
        )
        if "#endif\n}\n\n#ifndef QT_NO_DATASTREAM" not in text:
            raise RuntimeError("failed to close BE-300 DateFormat::wordDate")
    if "BE300 simple DateFormat::wordDate" in text and "#else\n    // for each part of the order" in text.split("void DateFormat::save", 1)[0] and "#endif\n}\n\n#ifndef QT_NO_DATASTREAM" not in text:
        raise RuntimeError("failed to close BE-300 DateFormat::wordDate")
    path.write_text(text, encoding="latin-1")

path = root / "library/global.cpp"
if path.exists():
    text = path.read_text(encoding="latin-1")
    if "BE300 no-op Global::invoke" not in text:
        text = text.replace(
            "void Global::invoke(const QString &c)\n"
            "{\n",
            "void Global::invoke(const QString &c)\n"
            "{\n"
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "    /* BE300 no-op Global::invoke: the 16 MiB Linux 2.4 profile\n"
            "       boots the desktop first and avoids fork/vfork child launch\n"
            "       from qpe, which corrupts the parent stack on this target. */\n"
            "    (void)c;\n"
            "    return;\n"
            "#endif\n",
            1,
        )
    if "BE300 no-op Global::execute" not in text:
        text = text.replace(
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "    /* BE300 direct Global::execute: the lightweight launcher\n"
            "       skips AppLauncher during startup. */\n"
            "    if ( document.isNull() || document.isEmpty() )\n"
            "        invoke( c );\n"
            "    else\n"
            "        invoke( c + \" \" + document );\n"
            "    return;\n"
            "#endif\n"
            "    // ask the server to do the work\n",
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "    /* BE300 no-op Global::execute: application launching is\n"
            "       disabled while bringing up the 16 MiB OPIE desktop. */\n"
            "    (void)c;\n"
            "    (void)document;\n"
            "    return;\n"
            "#endif\n"
            "    // ask the server to do the work\n",
            1,
        )
    if "BE300 no-op Global::execute" not in text and "BE300 direct Global::execute" not in text:
        text = text.replace(
            "void Global::execute( const QString &c, const QString& document )\n"
            "{\n"
            "    // ask the server to do the work\n",
            "void Global::execute( const QString &c, const QString& document )\n"
            "{\n"
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "    /* BE300 no-op Global::execute: application launching is\n"
            "       disabled while bringing up the 16 MiB OPIE desktop. */\n"
            "    (void)c;\n"
            "    (void)document;\n"
            "    return;\n"
            "#endif\n"
            "    // ask the server to do the work\n",
            1,
        )
    if "BE300 no-op Global::invoke" not in text:
        raise RuntimeError("failed to patch BE-300 Global::invoke")
    if "BE300 no-op Global::execute" not in text:
        raise RuntimeError("failed to patch BE-300 Global::execute")
    if "BE300 simple Global::helpPath" not in text:
        text = text.replace(
            "QStringList Global::helpPath()\n"
            "{\n",
            "QStringList Global::helpPath()\n"
            "{\n"
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "    /* BE300 simple Global::helpPath: avoid QString path\n"
            "       concatenation during 16 MiB qpe startup. */\n"
            "    return QStringList();\n"
            "#endif\n",
            1,
        )
    else:
        text = text.replace(
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "    /* BE300 simple Global::helpPath: avoid QString path\n"
            "       concatenation during 16 MiB qpe startup. */\n"
            "    QStringList path;\n"
            "    return path;\n"
            "#endif\n",
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "    /* BE300 simple Global::helpPath: avoid QString path\n"
            "       concatenation during 16 MiB qpe startup. */\n"
            "    return QStringList();\n"
            "#endif\n",
            1,
        )
    if "BE300 simple Global::helpPath" not in text:
        raise RuntimeError("failed to patch BE-300 Global::helpPath")
    if "BE300 vfork Global::invoke" not in text:
        text = text.replace(
            "        pid_t pid = ::fork ( );\n",
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "        /* BE300 vfork Global::invoke: 16 MiB Linux 2.4 has\n"
            "           shown unstable full-fork returns from qpe.  Build\n"
            "           child data before vfork and only make syscalls in\n"
            "           the child before exec/_exit. */\n"
            "        QString be300ExecPath = qpeDir() + \"/bin/\" + args[0];\n"
            "        QCString be300ExecPath8 = be300ExecPath.utf8();\n"
            "        pid_t pid = ::vfork();\n"
            "#else\n"
            "        pid_t pid = ::fork ( );\n"
            "#endif\n",
            1,
        )
        text = text.replace(
            "            ::execv ( qpeDir ( ) + \"/bin/\" + args [0], (char * const *) args );\n"
            "            ::execvp ( args [0], (char * const *) args );\n",
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "            ::execv ( be300ExecPath8.data(), (char * const *) args );\n"
            "#else\n"
            "            ::execv ( qpeDir ( ) + \"/bin/\" + args [0], (char * const *) args );\n"
            "#endif\n"
            "            ::execvp ( args [0], (char * const *) args );\n",
            1,
        )
    path.write_text(text, encoding="latin-1")

path = root / "core/launcher/documentlist.cpp"
if path.exists():
    text = path.read_text(encoding="latin-1")
    if "#include <stdio.h>" not in text:
        text = text.replace("#include <qpixmap.h>\n", "#include <qpixmap.h>\n#include <stdio.h>\n", 1)
    if "be300BuildAppLnkSet" not in text:
        helper = (
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "class Be300AppLnkSet : public AppLnkSet {\n"
            "public:\n"
            "    Be300AppLnkSet() : AppLnkSet()\n"
            "    {\n"
            "        typs.append( \"Application\" );\n"
            "    }\n"
            "\n"
            "    void addBe300App( const char *name, const char *exec )\n"
            "    {\n"
            "        AppLnk *app = new AppLnk;\n"
            "        app->setName( QString( name ) );\n"
            "        app->setExec( QString( exec ) );\n"
            "        app->setType( QString( \"Application\" ) );\n"
            "        app->setLinkFile( QString( \"/opt/QtPalmtop/apps/BE300/\" ) + QString( exec ) + QString( \".desktop\" ) );\n"
            "        add( app );\n"
            "    }\n"
            "};\n"
            "\n"
            "static AppLnkSet *be300BuildAppLnkSet()\n"
            "{\n"
            "    fprintf(stderr, \"[be300-doclist] build fixed app set\\n\");\n"
            "    Be300AppLnkSet *set = new Be300AppLnkSet;\n"
            "    set->addBe300App( \"Terminal\", \"embeddedkonsole\" );\n"
            "    set->addBe300App( \"Web\", \"ubrowser\" );\n"
            "    set->addBe300App( \"Text\", \"textedit\" );\n"
            "    set->addBe300App( \"Files\", \"advancedfm\" );\n"
            "    set->addBe300App( \"Calculator\", \"calculator\" );\n"
            "    set->addBe300App( \"Clock\", \"clock\" );\n"
            "    set->addBe300App( \"System\", \"sysinfo\" );\n"
            "    set->addBe300App( \"Help\", \"helpbrowser\" );\n"
            "    set->addBe300App( \"Contacts\", \"addressbook\" );\n"
            "    set->addBe300App( \"Calendar\", \"datebook\" );\n"
            "    set->addBe300App( \"Todo\", \"todolist\" );\n"
            "    set->addBe300App( \"Notes\", \"opie-notes\" );\n"
            "    fprintf(stderr, \"[be300-doclist] fixed app set ready\\n\");\n"
            "    return set;\n"
            "}\n"
            "#endif\n"
            "\n"
        )
        text = text.replace(
            "\n\nAppLnkSet *DocumentList::appLnkSet = 0;\n",
            "\n\n" + helper + "AppLnkSet *DocumentList::appLnkSet = 0;\n",
            1,
        )
    if "[be300-doclist]" not in text:
        text = text.replace(
            " : QObject( parent, name )\n"
            "{\n"
            "    appLnkSet = new AppLnkSet( MimeType::appsFolderName() );\n"
            "    d = new DocumentListPrivate( serverGui );\n"
            "    d->needToSendAllDocLinks = false;\n\n"
            "    Config cfg( \"Launcher\" );\n"
            "    cfg.setGroup( \"DocTab\" );\n"
            "    d->scanDocs = cfg.readBoolEntry( \"Enable\", true );\n"
            "    odebug << \"DocumentList::DocumentList() : scanDocs = \" << d->scanDocs << \"\" << oendl;\n\n"
            "    QTimer::singleShot( 0, this, SLOT( startInitialScan() ) );\n"
            "}\n",
            " : QObject( parent, name )\n"
            "{\n"
            "    fprintf(stderr, \"[be300-doclist] ctor start\\n\");\n"
            "    fprintf(stderr, \"[be300-doclist] new AppLnkSet\\n\");\n"
            "    appLnkSet = new AppLnkSet( MimeType::appsFolderName() );\n"
            "    fprintf(stderr, \"[be300-doclist] AppLnkSet ready\\n\");\n"
            "    fprintf(stderr, \"[be300-doclist] new private\\n\");\n"
            "    d = new DocumentListPrivate( serverGui );\n"
            "    fprintf(stderr, \"[be300-doclist] private ready\\n\");\n"
            "    d->needToSendAllDocLinks = false;\n\n"
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "    d->scanDocs = false;\n"
            "    fprintf(stderr, \"[be300-doclist] document scan disabled\\n\");\n"
            "#else\n"
            "    Config cfg( \"Launcher\" );\n"
            "    cfg.setGroup( \"DocTab\" );\n"
            "    d->scanDocs = cfg.readBoolEntry( \"Enable\", true );\n"
            "    odebug << \"DocumentList::DocumentList() : scanDocs = \" << d->scanDocs << \"\" << oendl;\n"
            "#endif\n\n"
            "    fprintf(stderr, \"[be300-doclist] schedule initial scan\\n\");\n"
            "    QTimer::singleShot( 0, this, SLOT( startInitialScan() ) );\n"
            "    fprintf(stderr, \"[be300-doclist] ctor done\\n\");\n"
            "}\n",
            1,
        )
        text = text.replace(
            "void DocumentList::startInitialScan()\n"
            "{\n"
            "    reloadAppLnks();\n"
            "    reloadDocLnks();\n"
            "}\n",
            "void DocumentList::startInitialScan()\n"
            "{\n"
            "    fprintf(stderr, \"[be300-doclist] startInitialScan\\n\");\n"
            "    reloadAppLnks();\n"
            "#ifndef QT_QWS_CASSIOPEIA\n"
            "    reloadDocLnks();\n"
            "#else\n"
            "    fprintf(stderr, \"[be300-doclist] skip reloadDocLnks\\n\");\n"
            "#endif\n"
            "    fprintf(stderr, \"[be300-doclist] startInitialScan done\\n\");\n"
            "}\n",
            1,
        )
        text = text.replace(
            "void DocumentList::reloadAppLnks()\n"
            "{\n"
            "    if ( d->sendAppLnks && d->serverGui ) {\n",
            "void DocumentList::reloadAppLnks()\n"
            "{\n"
            "    fprintf(stderr, \"[be300-doclist] reloadAppLnks start\\n\");\n"
            "    if ( d->sendAppLnks && d->serverGui ) {\n",
            1,
        )
        text = text.replace(
            "    delete appLnkSet;\n"
            "    appLnkSet = new AppLnkSet( MimeType::appsFolderName() );\n",
            "    fprintf(stderr, \"[be300-doclist] reloadAppLnks rebuild AppLnkSet\\n\");\n"
            "    delete appLnkSet;\n"
            "    appLnkSet = new AppLnkSet( MimeType::appsFolderName() );\n"
            "    fprintf(stderr, \"[be300-doclist] reloadAppLnks AppLnkSet ready\\n\");\n",
            1,
        )
        text = text.replace(
            "    if ( d->sendAppLnks && d->serverGui )\n"
            "    d->serverGui->applicationScanningProgress( 100 );\n"
            "}\n",
            "    if ( d->sendAppLnks && d->serverGui )\n"
            "    d->serverGui->applicationScanningProgress( 100 );\n"
            "    fprintf(stderr, \"[be300-doclist] reloadAppLnks done\\n\");\n"
            "}\n",
            1,
        )
        text = text.replace(
            "DocumentListPrivate::DocumentListPrivate( ServerInterface *gui )\n"
            "{\n"
            "    storage = new StorageInfo( this );\n",
            "DocumentListPrivate::DocumentListPrivate( ServerInterface *gui )\n"
            "{\n"
            "    fprintf(stderr, \"[be300-doclist] private ctor start\\n\");\n"
            "    fprintf(stderr, \"[be300-doclist] private new StorageInfo\\n\");\n"
            "    storage = new StorageInfo( this );\n"
            "    fprintf(stderr, \"[be300-doclist] private StorageInfo ready\\n\");\n",
            1,
        )
        text = text.replace(
            "    initialize();\n"
            "    tid = 0;\n"
            "}\n",
            "#ifndef QT_QWS_CASSIOPEIA\n"
            "    fprintf(stderr, \"[be300-doclist] private initialize\\n\");\n"
            "    initialize();\n"
            "    fprintf(stderr, \"[be300-doclist] private initialize done\\n\");\n"
            "#else\n"
            "    docPathsSearched = 0;\n"
            "    searchDepth = -1;\n"
            "    state = Done;\n"
            "    dit = 0;\n"
            "    fprintf(stderr, \"[be300-doclist] private skip document initialize\\n\");\n"
            "#endif\n"
            "    tid = 0;\n"
            "    fprintf(stderr, \"[be300-doclist] private ctor done\\n\");\n"
            "}\n",
            1,
        )
    text = re.sub(
        r"(?<!#else\n)    appLnkSet = new AppLnkSet\( MimeType::appsFolderName\(\) \);\n",
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    appLnkSet = be300BuildAppLnkSet();\n"
        "#else\n"
        "    appLnkSet = new AppLnkSet( MimeType::appsFolderName() );\n"
        "#endif\n",
        text,
    )
    text = text.replace(
        "    fprintf(stderr, \"[be300-doclist] schedule initial scan\\n\");\n"
        "    QTimer::singleShot( 0, this, SLOT( startInitialScan() ) );\n"
        "    fprintf(stderr, \"[be300-doclist] ctor done\\n\");\n",
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    fprintf(stderr, \"[be300-doclist] run initial scan\\n\");\n"
        "    startInitialScan();\n"
        "#else\n"
        "    fprintf(stderr, \"[be300-doclist] schedule initial scan\\n\");\n"
        "    QTimer::singleShot( 0, this, SLOT( startInitialScan() ) );\n"
        "#endif\n"
        "    fprintf(stderr, \"[be300-doclist] ctor done\\n\");\n",
        1,
    )
    text = text.replace(
        "    appLnkSet2 = new AppLnkSet( MimeType::appsFolderName() );\n",
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    appLnkSet2 = be300BuildAppLnkSet();\n"
        "#else\n"
        "    appLnkSet2 = new AppLnkSet( MimeType::appsFolderName() );\n"
        "#endif\n",
        1,
    )
    if "[be300-doclist] add BE300 application type" not in text:
        text = re.sub(
            r"    if \( d->sendAppLnks && d->serverGui \) \{\n"
            r"    static QStringList prevTypeList;\n"
            r".*?"
            r"    \}\n\n"
            r"    QListIterator<AppLnk> itapp",
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "    if ( d->sendAppLnks && d->serverGui ) {\n"
            "        fprintf(stderr, \"[be300-doclist] add BE300 application type\\n\");\n"
            "        QPixmap pm;\n"
            "        d->serverGui->typeAdded( QString( \"Application\" ), QString( \"Applications\" ), pm, pm );\n"
            "    }\n"
            "#else\n"
            "    if ( d->sendAppLnks && d->serverGui ) {\n"
            "    static QStringList prevTypeList;\n"
            "    QStringList types = appLnkSet->types();\n"
            "    for ( QStringList::Iterator ittypes=types.begin(); ittypes!=types.end(); ++ittypes) {\n"
            "        if ( !(*ittypes).isEmpty() ) {\n"
            "        if ( !prevTypeList.contains(*ittypes) ) {\n"
            "            QString name = appLnkSet->typeName(*ittypes);\n"
            "            QPixmap pm = appLnkSet->typePixmap(*ittypes);\n"
            "            QPixmap bgPm = appLnkSet->typeBigPixmap(*ittypes);\n"
            "\n"
            "            if (pm.isNull())\n"
            "            {\n"
            "                pm = OResource::loadImage( \"UnknownDocument\", OResource::SmallIcon );\n"
            "                bgPm = OResource::loadImage( \"UnknownDocument\", OResource::BigIcon );\n"
            "            }\n"
            "\n"
            "            //FIXME our current launcher expects docs tab to be last\n"
            "            d->serverGui->typeAdded( *ittypes, name.isNull() ? (*ittypes) : name, pm, bgPm );\n"
            "        }\n"
            "        prevTypeList.remove(*ittypes);\n"
            "        }\n"
            "    }\n"
            "    for ( QStringList::Iterator ittypes=prevTypeList.begin(); ittypes!=prevTypeList.end(); ++ittypes) {\n"
            "        d->serverGui->typeRemoved(*ittypes);\n"
            "    }\n"
            "    prevTypeList = types;\n"
            "    }\n"
            "#endif\n\n"
            "    QListIterator<AppLnk> itapp",
            text,
            count=1,
            flags=re.S,
        )
    if "[be300-doclist] add app" not in text:
        text = text.replace(
            "    if ( d->sendAppLnks && d->serverGui )\n"
            "        d->serverGui->applicationAdded( l->type(), *l );\n",
            "    if ( d->sendAppLnks && d->serverGui ) {\n"
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "        fprintf(stderr, \"[be300-doclist] add app %s\\n\", l->name().latin1() );\n"
            "#endif\n"
            "        d->serverGui->applicationAdded( l->type(), *l );\n"
            "    }\n",
            1,
        )
    path.write_text(text, encoding="latin-1")

path = root / "core/launcher/launcherview.cpp"
# Final launcher-view fixes live in patch_opie_sources.py.  Keep this
# debug-era placeholder-icon patch disabled so stock Opie icons can paint.
if False and path.exists():
    text = path.read_text(encoding="latin-1")
    if "#include <stdio.h>" not in text:
        text = text.replace(
            "#include <qobjectlist.h>\n",
            "#include <qobjectlist.h>\n"
            "#include <stdio.h>\n",
            1,
        )
    if "be300LauncherPixmap" not in text:
        text = text.replace(
            "static bool s_IgnoreNextPix = false;\n",
            "static bool s_IgnoreNextPix = false;\n"
            "\n"
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "static const QPixmap &be300LauncherPixmap()\n"
            "{\n"
            "    static QPixmap *pm = 0;\n"
            "    if ( !pm ) {\n"
            "        pm = new QPixmap( 24, 24 );\n"
            "        pm->fill( QColor( 32, 128, 224 ) );\n"
            "    }\n"
            "    return *pm;\n"
            "}\n"
            "#endif\n",
            1,
        )
        text = text.replace(
            "LauncherItem::LauncherItem( QIconView *parent, AppLnk *applnk, bool bigIcon )\n"
            "    : QIconViewItem( parent, applnk->name(),\n"
            "           bigIcon ? applnk->bigPixmap() :applnk->pixmap() ),\n"
            "LauncherItem::LauncherItem( QIconView *parent, AppLnk *applnk, bool bigIcon )\n"
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "    : QIconViewItem( parent, applnk->name(), be300LauncherPixmap() ),\n"
            "#else\n"
            "    : QIconViewItem( parent, applnk->name(),\n"
            "           bigIcon ? applnk->bigPixmap() :applnk->pixmap() ),\n"
            "#endif\n",
            1,
        )
        text = text.replace(
            "    psize( (bigIcon ? applnk->bigPixmap().width() :applnk->pixmap().width() ) ),\n",
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "    psize( be300LauncherPixmap().width() ),\n"
            "#else\n"
            "    psize( (bigIcon ? applnk->bigPixmap().width() :applnk->pixmap().width() ) ),\n"
            "#endif\n",
            1,
        )
    if "BE300 launcher solid background" not in text:
        text = text.replace(
            "    tools = 0;\n"
            "    setBackgroundType( Ruled, QString::null );\n",
            "    tools = 0;\n"
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "    /* BE300 launcher solid background: avoid ruled pixmap\n"
            "       generation and widget-tree walks before first paint. */\n"
            "    bgType = SolidColor;\n"
            "    bgName = \"\";\n"
            "    icons->setBackgroundColor( QColor( 224, 224, 224 ) );\n"
            "    icons->viewport()->setBackgroundColor( QColor( 224, 224, 224 ) );\n"
            "    setTextColor( QColor( 0, 0, 0 ) );\n"
            "#else\n"
            "    setBackgroundType( Ruled, QString::null );\n"
            "#endif\n",
            1,
        )
    text = text.replace(
        "        pm->fill( QColor( 255, 255, 255 ) );\n",
        "        pm->fill( QColor( 32, 128, 224 ) );\n",
    )
    text = text.replace(
        "    icons->setBackgroundColor( colorGroup().base() );\n"
        "    icons->viewport()->setBackgroundColor( colorGroup().base() );\n",
        "    icons->setBackgroundColor( QColor( 224, 224, 224 ) );\n"
        "    icons->viewport()->setBackgroundColor( QColor( 224, 224, 224 ) );\n"
        "    setTextColor( QColor( 0, 0, 0 ) );\n",
    )
    path.write_text(text, encoding="latin-1")

path = root / "core/launcher/launcher.h"
if path.exists():
    text = path.read_text(encoding="latin-1")
    if "public slots:\n    void raiseTabWidget();" not in text:
        text = text.replace(
            "protected slots:\n    void raiseTabWidget();\n",
            "public slots:\n    void raiseTabWidget();\n\nprotected slots:\n",
            1,
        )
    if "class Be300HomeWidget;" not in text:
        text = text.replace(
            "class QWidgetStack;\nclass TaskBar;\nclass Launcher;\n",
            "class QWidgetStack;\nclass TaskBar;\nclass Launcher;\n"
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "class Be300HomeWidget;\n"
            "#endif\n",
            1,
        )
    if "Be300HomeWidget *be300Home;" not in text:
        text = text.replace(
            "    LauncherTabWidget *tabs;\n"
            "    QStringList ids;\n"
            "    TaskBar *tb;\n\n"
            "    bool docTabEnabled;\n",
            "    LauncherTabWidget *tabs;\n"
            "    QStringList ids;\n"
            "    TaskBar *tb;\n"
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "    Be300HomeWidget *be300Home;\n"
            "#endif\n\n"
            "    bool docTabEnabled;\n",
            1,
        )
    path.write_text(text, encoding="latin-1")

path = root / "core/launcher/launcher.cpp"
if path.exists():
    text = path.read_text(encoding="latin-1")
    if "#include <qevent.h>" not in text:
        text = text.replace("#include <qdir.h>\n", "#include <qdir.h>\n#include <qevent.h>\n", 1)
    text = text.replace("#include <qptrlist.h>\n", "")
    if "class Be300HomeButton" not in text:
        text = text.replace(
            "static bool isVisibleWindow( int );\n"
            "//===========================================================================\n\n",
            "static bool isVisibleWindow( int );\n"
            "\n"
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "class Be300HomeButton : public QPushButton\n"
            "{\n"
            "public:\n"
            "    Be300HomeButton( const AppLnk &app, QWidget *parent )\n"
            "        : QPushButton( app.name(), parent ), appLnk( new AppLnk( app ) )\n"
            "    {\n"
            "        setMinimumHeight( 22 );\n"
            "        setFocusPolicy( QWidget::StrongFocus );\n"
            "    }\n"
            "\n"
            "    ~Be300HomeButton()\n"
            "    {\n"
            "        delete appLnk;\n"
            "    }\n"
            "\n"
            "    void executeApp()\n"
            "    {\n"
            "        if ( appLnk )\n"
            "            appLnk->execute();\n"
            "    }\n"
            "\n"
            "protected:\n"
            "    void mouseReleaseEvent( QMouseEvent *e )\n"
            "    {\n"
            "        bool inside = rect().contains( e->pos() );\n"
            "        QPushButton::mouseReleaseEvent( e );\n"
            "        if ( inside )\n"
            "            executeApp();\n"
            "    }\n"
            "\n"
            "    void keyReleaseEvent( QKeyEvent *e )\n"
            "    {\n"
            "        if ( e->key() == Qt::Key_Return || e->key() == Qt::Key_Enter ||\n"
            "             e->key() == Qt::Key_Space ) {\n"
            "            executeApp();\n"
            "            e->accept();\n"
            "            return;\n"
            "        }\n"
            "        QPushButton::keyReleaseEvent( e );\n"
            "    }\n"
            "\n"
            "private:\n"
            "    AppLnk *appLnk;\n"
            "};\n"
            "\n"
            "class Be300HomeWidget : public QWidget\n"
            "{\n"
            "public:\n"
            "    Be300HomeWidget( QWidget *parent = 0 )\n"
            "        : QWidget( parent, \"be300Home\", parent ? 0 : (WStyle_Customize | WStyle_Tool | WStyle_StaysOnTop | WGroupLeader) )\n"
            "    {\n"
            "        buttons.setAutoDelete( FALSE );\n"
            "        setBackgroundColor( QColor( 224, 224, 224 ) );\n"
            "    }\n"
            "\n"
            "    void addApp( const AppLnk &app )\n"
            "    {\n"
            "        Be300HomeButton *button = new Be300HomeButton( app, this );\n"
            "        buttons.append( button );\n"
            "        layoutButtons();\n"
            "        button->show();\n"
            "        if ( buttons.count() == 1 )\n"
            "            button->setFocus();\n"
            "        update();\n"
            "    }\n"
            "\n"
            "protected:\n"
            "    void resizeEvent( QResizeEvent * )\n"
            "    {\n"
            "        layoutButtons();\n"
            "    }\n"
            "\n"
            "    void paintEvent( QPaintEvent * )\n"
            "    {\n"
            "        QPainter p( this );\n"
            "        p.fillRect( rect(), QColor( 224, 224, 224 ) );\n"
            "        p.setPen( QColor( 0, 0, 0 ) );\n"
            "        p.drawText( 6, 16, \"OPIE\" );\n"
            "    }\n"
            "\n"
            "private:\n"
            "    void layoutButtons()\n"
            "    {\n"
            "        int n = (int)buttons.count();\n"
            "        if ( n <= 0 )\n"
            "            return;\n"
            "\n"
            "        int cols = 2;\n"
            "        int margin = 6;\n"
            "        int gap = 4;\n"
            "        int title = 22;\n"
            "        int rows = ( n + cols - 1 ) / cols;\n"
            "        int availW = width() - margin * 2 - gap;\n"
            "        int availH = height() - title - margin * 2 - gap * ( rows - 1 );\n"
            "        int buttonW = availW / cols;\n"
            "        int buttonH = rows > 0 ? availH / rows : 22;\n"
            "\n"
            "        if ( buttonW < 40 )\n"
            "            buttonW = 40;\n"
            "        if ( buttonH > 34 )\n"
            "            buttonH = 34;\n"
            "        if ( buttonH < 18 )\n"
            "            buttonH = 18;\n"
            "\n"
            "        int i = 0;\n"
            "        for ( Be300HomeButton *b = buttons.first(); b; b = buttons.next(), ++i ) {\n"
            "            int row = i / cols;\n"
            "            int col = i % cols;\n"
            "            int x = margin + col * ( buttonW + gap );\n"
            "            int y = title + margin + row * ( buttonH + gap );\n"
            "            b->setGeometry( x, y, buttonW, buttonH );\n"
            "            b->show();\n"
            "        }\n"
            "    }\n"
            "\n"
            "    QList<Be300HomeButton> buttons;\n"
            "};\n"
            "#endif\n"
            "\n"
            "//===========================================================================\n\n",
            1,
        )
    text = text.replace("QPtrList<Be300HomeButton>", "QList<Be300HomeButton>")
    if "void executeApp()" not in text:
        text = text.replace(
            "    ~Be300HomeButton()\n"
            "    {\n"
            "        delete appLnk;\n"
            "    }\n"
            "\n"
            "protected:\n",
            "    ~Be300HomeButton()\n"
            "    {\n"
            "        delete appLnk;\n"
            "    }\n"
            "\n"
            "    void executeApp()\n"
            "    {\n"
            "        if ( appLnk )\n"
            "            appLnk->execute();\n"
            "    }\n"
            "\n"
            "protected:\n",
            1,
        )
        text = text.replace(
            "        if ( inside && appLnk )\n"
            "            appLnk->execute();\n",
            "        if ( inside )\n"
            "            executeApp();\n",
            1,
        )
        text = text.replace(
            "            if ( appLnk )\n"
            "                appLnk->execute();\n",
            "            executeApp();\n",
            1,
        )
    if "BE300 home fallback release launcher" not in text:
        text = text.replace(
            "    void paintEvent( QPaintEvent * )\n"
            "    {\n",
            "    void mouseReleaseEvent( QMouseEvent *e )\n"
            "    {\n"
            "        /* BE300 home fallback release launcher: if an early\n"
            "           pen-down lands on the background, Qt keeps the mouse\n"
            "           grab here.  Launch the button under the final release. */\n"
            "        for ( Be300HomeButton *b = buttons.first(); b; b = buttons.next() ) {\n"
            "            if ( b->geometry().contains( e->pos() ) ) {\n"
            "                b->executeApp();\n"
            "                return;\n"
            "            }\n"
            "        }\n"
            "        QWidget::mouseReleaseEvent( e );\n"
            "    }\n"
            "\n"
            "    void paintEvent( QPaintEvent * )\n"
            "    {\n",
            1,
        )
    text = text.replace(
        "                b->executeApp();\n"
        "                e->accept();\n"
        "                return;\n",
        "                b->executeApp();\n"
        "                return;\n",
    )
    text = text.replace(
        "    Be300HomeWidget( QWidget *parent = 0 )\n"
        "        : QWidget( parent )\n",
        "    Be300HomeWidget( QWidget *parent = 0 )\n"
        "        : QWidget( parent, \"be300Home\" )\n",
        1,
    )
    text = text.replace(
        "        : QWidget( parent, \"be300Home\", parent ? 0 : (WStyle_Customize | WStyle_Tool | WStyle_StaysOnTop | WGroupLeader) )\n",
        "        : QWidget( parent, \"be300Home\" )\n",
    )
    if "[be300-home]" not in text:
        text = text.replace(
            "        buttons.setAutoDelete( FALSE );\n"
            "        setBackgroundColor( QColor( 224, 224, 224 ) );\n"
            "    }\n",
            "        buttons.setAutoDelete( FALSE );\n"
            "        setBackgroundColor( QColor( 224, 224, 224 ) );\n"
            "        setGeometry( 0, 0, 240, 296 );\n"
            "        fprintf(stderr, \"[be300-home] ctor geom=%dx%d+%d+%d visible=%d\\n\",\n"
            "                width(), height(), x(), y(), isVisible() ? 1 : 0 );\n"
            "    }\n",
            1,
        )
        text = text.replace(
            "        buttons.append( button );\n"
            "        layoutButtons();\n"
            "        button->show();\n",
            "        buttons.append( button );\n"
            "        if ( width() <= 1 || height() <= 1 )\n"
            "            setGeometry( 0, 0, 240, 296 );\n"
            "        layoutButtons();\n"
            "        button->show();\n",
            1,
        )
        text = text.replace(
            "        update();\n"
            "    }\n"
            "\n"
            "protected:\n"
            "    void resizeEvent( QResizeEvent * )\n"
            "    {\n"
            "        layoutButtons();\n"
            "    }\n"
            "\n"
            "    void paintEvent( QPaintEvent * )\n"
            "    {\n",
            "        repaint( FALSE );\n"
            "        fprintf(stderr, \"[be300-home] addApp %s count=%u geom=%dx%d+%d+%d visible=%d\\n\",\n"
            "                app.name().latin1(), (unsigned)buttons.count(), width(), height(), x(), y(), isVisible() ? 1 : 0 );\n"
            "    }\n"
            "\n"
            "protected:\n"
            "    void resizeEvent( QResizeEvent * )\n"
            "    {\n"
            "        layoutButtons();\n"
            "        fprintf(stderr, \"[be300-home] resize geom=%dx%d+%d+%d visible=%d\\n\",\n"
            "                width(), height(), x(), y(), isVisible() ? 1 : 0 );\n"
            "    }\n"
            "\n"
            "    void paintEvent( QPaintEvent * )\n"
            "    {\n"
            "        fprintf(stderr, \"[be300-home] paint geom=%dx%d+%d+%d visible=%d count=%u\\n\",\n"
            "                width(), height(), x(), y(), isVisible() ? 1 : 0, (unsigned)buttons.count() );\n",
            1,
        )
    text = text.replace(
        "    be300Home = new Be300HomeWidget( this );\n"
        "    setCentralWidget( be300Home );\n",
        "    be300Home = new Be300HomeWidget( this );\n"
        "    be300Home->setGeometry( 0, 0, qApp->desktop()->width(), qApp->desktop()->height() - 24 );\n"
        "    be300Home->show();\n"
        "    be300Home->raise();\n"
        "    setCentralWidget( be300Home );\n",
        1,
    )
    text = text.replace(
        "    be300Home->setGeometry( 0, 0, qApp->desktop()->width(), qApp->desktop()->height() );\n",
        "    be300Home->setGeometry( 0, 0, qApp->desktop()->width(), qApp->desktop()->height() - 24 );\n",
    )
    text = text.replace(
        "        be300Home->setGeometry( 0, 0, qApp->desktop()->width(), qApp->desktop()->height() );\n",
        "        be300Home->setGeometry( 0, 0, qApp->desktop()->width(), qApp->desktop()->height() - 24 );\n",
    )
    text = text.replace(
        "                be300Home->setGeometry( 0, 0, qApp->desktop()->width(), qApp->desktop()->height() );\n",
        "                be300Home->setGeometry( 0, 0, qApp->desktop()->width(), qApp->desktop()->height() - 24 );\n",
    )
    text = text.replace(
        "    if ( be300Home )\n"
        "        be300Home->addApp( app );\n",
        "    if ( be300Home ) {\n"
        "        be300Home->setGeometry( 0, 0, qApp->desktop()->width(), qApp->desktop()->height() - 24 );\n"
        "        be300Home->addApp( app );\n"
        "        be300Home->show();\n"
        "        be300Home->raise();\n"
        "        be300Home->repaint( FALSE );\n"
        "    }\n",
        1,
    )
    text = text.replace(
        "            if ( be300Home ) {\n"
        "                be300Home->show();\n"
        "                be300Home->raise();\n"
        "                be300Home->update();\n"
        "            }\n"
        "            showMaximized();\n"
        "            raise();\n"
        "            update();\n",
        "            if ( be300Home ) {\n"
        "                be300Home->setGeometry( 0, 0, qApp->desktop()->width(), qApp->desktop()->height() - 24 );\n"
        "                be300Home->show();\n"
        "                be300Home->raise();\n"
        "                be300Home->repaint( FALSE );\n"
        "            }\n"
        "            showMaximized();\n"
        "            raise();\n"
        "            repaint( FALSE );\n",
        1,
    )
    if "[be300-launcher]" not in text:
        text = text.replace(
            "{\n    tabs = 0;\n",
            "{\n"
            "    fprintf(stderr, \"[be300-launcher] ctor body start\\n\");\n"
            "    tabs = 0;\n",
            1,
        )
        text = text.replace(
            "    docTabEnabled = cfg.readBoolEntry( \"Enable\", true );\n}\n\nvoid Launcher::createGUI()\n{\n    setCaption( tr(\"Launcher\") );\n",
            "    docTabEnabled = cfg.readBoolEntry( \"Enable\", true );\n"
            "    fprintf(stderr, \"[be300-launcher] ctor done\\n\");\n"
            "}\n\n"
            "void Launcher::createGUI()\n"
            "{\n"
            "    fprintf(stderr, \"[be300-launcher] createGUI start\\n\");\n"
            "    setCaption( tr(\"Launcher\") );\n",
            1,
        )
        text = text.replace(
            "    setGeometry( 0, 0, qApp->desktop()->width(), qApp->desktop()->height() );\n\n"
            "    tb = new TaskBar;\n    tabs = new LauncherTabWidget( this );\n",
            "    setGeometry( 0, 0, qApp->desktop()->width(), qApp->desktop()->height() );\n"
            "    fprintf(stderr, \"[be300-launcher] geometry set\\n\");\n\n"
            "    fprintf(stderr, \"[be300-launcher] new TaskBar\\n\");\n"
            "    tb = new TaskBar;\n"
            "    fprintf(stderr, \"[be300-launcher] TaskBar allocated\\n\");\n"
            "    fprintf(stderr, \"[be300-launcher] new LauncherTabWidget\\n\");\n"
            "    tabs = new LauncherTabWidget( this );\n"
            "    fprintf(stderr, \"[be300-launcher] LauncherTabWidget allocated\\n\");\n",
            1,
        )
        text = text.replace(
            "    setCentralWidget( tabs );\n\n"
            "    ServerInterface::dockWidget( tb, ServerInterface::Bottom );\n    tb->show();\n",
            "    setCentralWidget( tabs );\n"
            "    fprintf(stderr, \"[be300-launcher] central widget set\\n\");\n\n"
            "    fprintf(stderr, \"[be300-launcher] dock taskbar\\n\");\n"
            "    ServerInterface::dockWidget( tb, ServerInterface::Bottom );\n"
            "    fprintf(stderr, \"[be300-launcher] taskbar docked\\n\");\n"
            "    tb->show();\n"
            "    fprintf(stderr, \"[be300-launcher] taskbar shown\\n\");\n",
            1,
        )
        text = text.replace(
            "    QCopChannel* sysChannel = new QCopChannel( \"QPE/System\", this );\n",
            "    fprintf(stderr, \"[be300-launcher] create system channel\\n\");\n"
            "    QCopChannel* sysChannel = new QCopChannel( \"QPE/System\", this );\n"
            "    fprintf(stderr, \"[be300-launcher] system channel created\\n\");\n",
            1,
        )
        text = text.replace(
            "    QPixmap pm = OResource::loadPixmap( \"DocsIcon\", OResource::SmallIcon );\n",
            "#ifndef QT_QWS_CASSIOPEIA\n"
            "    fprintf(stderr, \"[be300-launcher] load DocsIcon\\n\");\n"
            "    QPixmap pm = OResource::loadPixmap( \"DocsIcon\", OResource::SmallIcon );\n"
            "    fprintf(stderr, \"[be300-launcher] DocsIcon loaded\\n\");\n"
            "#else\n"
            "    fprintf(stderr, \"[be300-launcher] skip DocsIcon load\\n\");\n"
            "    QPixmap pm;\n"
            "#endif\n",
            1,
        )
        text = text.replace(
            "    tabs->newView(\"Documents\", pm, tr(\"Documents\") )->setToolsEnabled( TRUE );\n\n"
            "    QTimer::singleShot( 0, tabs, SLOT( initLayout() ) );\n",
            "    fprintf(stderr, \"[be300-launcher] new Documents view\\n\");\n"
            "    tabs->newView(\"Documents\", pm, tr(\"Documents\") )->setToolsEnabled( TRUE );\n"
            "    fprintf(stderr, \"[be300-launcher] Documents view ready\\n\");\n\n"
            "    QTimer::singleShot( 0, tabs, SLOT( initLayout() ) );\n",
            1,
        )
        text = text.replace(
            "    QTimer::singleShot( 500, this, SLOT( makeVisible() ) );\n}\n",
            "    QTimer::singleShot( 500, this, SLOT( makeVisible() ) );\n"
            "    fprintf(stderr, \"[be300-launcher] createGUI done\\n\");\n"
            "}\n",
            1,
        )
    if "be300Home = 0;" not in text:
        text = text.replace(
            "    tabs = 0;\n"
            "    tb = 0;\n",
            "    tabs = 0;\n"
            "    tb = 0;\n"
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "    be300Home = 0;\n"
            "#endif\n",
            1,
        )
    if "setCentralWidget( be300Home );" not in text:
        text = text.replace(
            "    fprintf(stderr, \"[be300-launcher] new LauncherTabWidget\\n\");\n"
            "    tabs = new LauncherTabWidget( this );\n"
            "    fprintf(stderr, \"[be300-launcher] LauncherTabWidget allocated\\n\");\n"
            "    setCentralWidget( tabs );\n"
            "    fprintf(stderr, \"[be300-launcher] central widget set\\n\");\n",
            "    fprintf(stderr, \"[be300-launcher] new LauncherTabWidget\\n\");\n"
            "    tabs = new LauncherTabWidget( this );\n"
            "    fprintf(stderr, \"[be300-launcher] LauncherTabWidget allocated\\n\");\n"
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "    tabs->hide();\n"
            "    be300Home = new Be300HomeWidget( this );\n"
            "    setCentralWidget( be300Home );\n"
            "    be300Home->setGeometry( 0, 0, qApp->desktop()->width(), qApp->desktop()->height() - 24 );\n"
            "    be300Home->show();\n"
            "    be300Home->raise();\n"
            "#else\n"
            "    setCentralWidget( tabs );\n"
            "#endif\n"
            "    fprintf(stderr, \"[be300-launcher] central widget set\\n\");\n",
            1,
        )
    text = text.replace(
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    tabs->hide();\n"
        "    be300Home = new Be300HomeWidget( 0 );\n"
        "    be300Home->setGeometry( 0, 0, qApp->desktop()->width(), qApp->desktop()->height() );\n"
        "    be300Home->show();\n"
        "    be300Home->raise();\n"
        "#else\n"
        "    setCentralWidget( tabs );\n"
        "#endif\n",
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    tabs->hide();\n"
        "    be300Home = new Be300HomeWidget( this );\n"
        "    setCentralWidget( be300Home );\n"
        "    be300Home->setGeometry( 0, 0, qApp->desktop()->width(), qApp->desktop()->height() - 24 );\n"
        "    be300Home->show();\n"
        "    be300Home->raise();\n"
        "#else\n"
        "    setCentralWidget( tabs );\n"
        "#endif\n",
    )
    text = text.replace(
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    tabs->hide();\n"
        "    be300Home = new Be300HomeWidget( 0 );\n"
        "    be300Home->setGeometry( 0, 0, qApp->desktop()->width(), qApp->desktop()->height() - 24 );\n"
        "    be300Home->show();\n"
        "    be300Home->raise();\n"
        "#else\n"
        "    setCentralWidget( tabs );\n"
        "#endif\n",
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    tabs->hide();\n"
        "    be300Home = new Be300HomeWidget( this );\n"
        "    setCentralWidget( be300Home );\n"
        "    be300Home->setGeometry( 0, 0, qApp->desktop()->width(), qApp->desktop()->height() - 24 );\n"
        "    be300Home->show();\n"
        "    be300Home->raise();\n"
        "#else\n"
        "    setCentralWidget( tabs );\n"
        "#endif\n",
    )
    if "delete be300Home;" not in text:
        text = text.replace(
            "void Launcher::destroyGUI()\n"
            "{\n"
            "    delete tb;\n"
            "    tb = 0;\n"
            "    delete tabs;\n"
            "    tabs =0;\n"
            "}\n",
            "void Launcher::destroyGUI()\n"
            "{\n"
            "    delete tb;\n"
            "    tb = 0;\n"
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "    delete be300Home;\n"
            "    be300Home = 0;\n"
            "#endif\n"
            "    delete tabs;\n"
            "    tabs =0;\n"
            "}\n",
            1,
        )
    if "be300Home->addApp( app );" not in text:
        text = text.replace(
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "    fprintf(stderr, \"[be300-launcher] applicationAdded enter %s\\n\", app.name().latin1() );\n"
            "#endif\n"
            "    LauncherView *view = tabs->view( type );\n",
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "    fprintf(stderr, \"[be300-launcher] applicationAdded enter %s\\n\", app.name().latin1() );\n"
            "    if ( be300Home )\n"
            "        be300Home->addApp( app );\n"
            "    fprintf(stderr, \"[be300-launcher] applicationAdded done %s\\n\", app.name().latin1() );\n"
            "    return;\n"
            "#endif\n"
            "    LauncherView *view = tabs->view( type );\n",
            1,
        )
    if "be300Home->raise();" not in text:
        text = text.replace(
            "            tabs->show();\n"
            "            if ( tabs->layout() )\n"
            "                tabs->layout()->activate();\n"
            "            showMaximized();\n"
            "            raise();\n"
            "            update();\n",
            "            if ( be300Home ) {\n"
            "                be300Home->show();\n"
            "                be300Home->raise();\n"
            "                be300Home->update();\n"
            "            }\n"
            "            showMaximized();\n"
            "            raise();\n"
            "            update();\n",
            1,
        )
    if "[be300-launcher] skip DocsIcon load" not in text:
        text = text.replace(
            "    fprintf(stderr, \"[be300-launcher] load DocsIcon\\n\");\n"
            "    QPixmap pm = OResource::loadPixmap( \"DocsIcon\", OResource::SmallIcon );\n"
            "    fprintf(stderr, \"[be300-launcher] DocsIcon loaded\\n\");\n",
            "#ifndef QT_QWS_CASSIOPEIA\n"
            "    fprintf(stderr, \"[be300-launcher] load DocsIcon\\n\");\n"
            "    QPixmap pm = OResource::loadPixmap( \"DocsIcon\", OResource::SmallIcon );\n"
            "    fprintf(stderr, \"[be300-launcher] DocsIcon loaded\\n\");\n"
            "#else\n"
            "    fprintf(stderr, \"[be300-launcher] skip DocsIcon load\\n\");\n"
            "    QPixmap pm;\n"
            "#endif\n",
            1,
        )
    if "[be300-launcher] skip Documents view" not in text:
        text = text.replace(
            "    fprintf(stderr, \"[be300-launcher] new Documents view\\n\");\n"
            "    tabs->newView(\"Documents\", pm, tr(\"Documents\") )->setToolsEnabled( TRUE );\n"
            "    fprintf(stderr, \"[be300-launcher] Documents view ready\\n\");\n",
            "#ifndef QT_QWS_CASSIOPEIA\n"
            "    fprintf(stderr, \"[be300-launcher] new Documents view\\n\");\n"
            "    tabs->newView(\"Documents\", pm, tr(\"Documents\") )->setToolsEnabled( TRUE );\n"
            "    fprintf(stderr, \"[be300-launcher] Documents view ready\\n\");\n"
            "#else\n"
            "    fprintf(stderr, \"[be300-launcher] skip Documents view\\n\");\n"
            "#endif\n",
            1,
        )
    if "[be300-tabs]" not in text:
        text = text.replace(
            "LauncherTabWidget::LauncherTabWidget( Launcher* parent ) :\n"
            "    QVBox( parent ), docview( 0 ),docTabEnabled(true),m_DocumentTabId(0)\n"
            "{\n"
            "    docLoadingWidgetEnabled = false;\n",
            "LauncherTabWidget::LauncherTabWidget( Launcher* parent ) :\n"
            "    QVBox( parent ), docview( 0 ),docTabEnabled(true),m_DocumentTabId(0)\n"
            "{\n"
            "    fprintf(stderr, \"[be300-tabs] ctor start\\n\");\n"
            "    docLoadingWidgetEnabled = false;\n",
            1,
        )
        text = text.replace(
            "    launcher = parent;\n"
            "    categoryBar = new LauncherTabBar( this );\n",
            "    launcher = parent;\n"
            "    fprintf(stderr, \"[be300-tabs] new category bar\\n\");\n"
            "    categoryBar = new LauncherTabBar( this );\n"
            "    fprintf(stderr, \"[be300-tabs] category bar ready\\n\");\n",
            1,
        )
        text = text.replace(
            "    stack = new QWidgetStack(this);\n",
            "    fprintf(stderr, \"[be300-tabs] new stack\\n\");\n"
            "    stack = new QWidgetStack(this);\n"
            "    fprintf(stderr, \"[be300-tabs] stack ready\\n\");\n",
            1,
        )
        text = text.replace(
            "    categoryBar->show();\n"
            "    stack->show();\n",
            "    categoryBar->show();\n"
            "    stack->show();\n"
            "    fprintf(stderr, \"[be300-tabs] widgets shown\\n\");\n",
            1,
        )
        text = text.replace(
            "    createDocLoadingWidget();\n"
            "}\n",
            "#ifndef QT_QWS_CASSIOPEIA\n"
            "    createDocLoadingWidget();\n"
            "#else\n"
            "    fprintf(stderr, \"[be300-tabs] skip doc loading widget\\n\");\n"
            "#endif\n"
            "    fprintf(stderr, \"[be300-tabs] ctor done\\n\");\n"
            "}\n",
            1,
        )
    text = text.replace(
        "void LauncherTabWidget::initLayout()\n"
        "{\n"
        "    layout()->activate();\n"
        "    docView()->setFocus();\n"
        "    categoryBar->showTab(\"Documents\");\n"
        "}\n",
        "void LauncherTabWidget::initLayout()\n"
        "{\n"
        "    layout()->activate();\n"
        "    if ( docView() ) {\n"
        "        docView()->setFocus();\n"
        "        categoryBar->showTab(\"Documents\");\n"
        "    } else if ( categoryBar->currentView() ) {\n"
        "        categoryBar->currentView()->setFocus();\n"
        "    }\n"
        "}\n",
        1,
    )
    text = text.replace(
        "void LauncherTabWidget::raiseTabWidget()\n"
        "{\n"
        "    if ( categoryBar->currentView() == docView()\n"
        "         && docLoadingWidgetEnabled ) {\n"
        "        stack->raiseWidget( docLoadingWidget );\n"
        "        docLoadingWidget->updateGeometry();\n"
        "    } else {\n"
        "        stack->raiseWidget( categoryBar->currentView() );\n"
        "    }\n"
        "}\n",
        "void LauncherTabWidget::raiseTabWidget()\n"
        "{\n"
        "    LauncherView *view = categoryBar->currentView();\n"
        "    if ( !view )\n"
        "        return;\n"
        "    if ( view == docView()\n"
        "         && docLoadingWidgetEnabled && docLoadingWidget ) {\n"
        "        stack->raiseWidget( docLoadingWidget );\n"
        "        docLoadingWidget->updateGeometry();\n"
        "    } else {\n"
        "        stack->raiseWidget( view );\n"
        "    }\n"
        "}\n",
        1,
    )
    text = text.replace(
        "        if ( id == \"Documents\" )\n"
        "            docLoadingWidget->setBackgroundType( (LauncherView::BackgroundType)mode, pixmapOrColor );\n",
        "        if ( id == \"Documents\" && docLoadingWidget )\n"
        "            docLoadingWidget->setBackgroundType( (LauncherView::BackgroundType)mode, pixmapOrColor );\n",
        1,
    )
    text = text.replace(
        "        if ( id == \"Documents\" )\n"
        "            docLoadingWidget->setTextColor( QColor(color) );\n",
        "        if ( id == \"Documents\" && docLoadingWidget )\n"
        "            docLoadingWidget->setTextColor( QColor(color) );\n",
        1,
    )
    if "void LauncherTabWidget::reCheckDoctab(int how)\n{\n#ifdef QT_QWS_CASSIOPEIA" not in text:
        text = text.replace(
            "void LauncherTabWidget::reCheckDoctab(int how)\n"
            "{\n",
            "void LauncherTabWidget::reCheckDoctab(int how)\n"
            "{\n"
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "    (void)how;\n"
            "    return;\n"
            "#endif\n",
            1,
        )
    if "[be300-tabs] newView start" not in text:
        text = text.replace(
            "LauncherView* LauncherTabWidget::newView( const QString& id, const QPixmap& pm, const QString& label )\n"
            "{\n"
            "    LauncherView* view = new LauncherView( stack );\n"
            "    connect( view, SIGNAL(clicked(const AppLnk*)),\n"
            "        this, SIGNAL(clicked(const AppLnk*)));\n"
            "    connect( view, SIGNAL(rightPressed(AppLnk*)),\n"
            "        this, SIGNAL(rightPressed(AppLnk*)));\n"
            "\n"
            "\n"
            "    int n = categoryBar->count();\n"
            "\n"
            "    stack->addWidget( view, n );\n"
            "\n"
            "    LauncherTab *tab = new LauncherTab( id, view, pm, label );\n"
            "    categoryBar->insertTab( tab, n-1 );\n"
            "    if ( id == \"Documents\" ) {\n"
            "        docview = view;\n"
            "        m_DocumentTabId = n;\n"
            "    }\n"
            "\n"
            "    odebug << \"inserting \" << id << \" at \" << n-1 << \"\" << oendl;\n"
            "\n"
            "    Config cfg(\"Launcher\");\n"
            "    setTabAppearance( tab, cfg );\n"
            "\n"
            "    cfg.setGroup( \"GUI\" );\n"
            "    view->setBusyIndicatorType( cfg.readEntry( \"BusyType\", QString::null ) );\n"
            "\n"
            "    return view;\n"
            "}\n",
            "LauncherView* LauncherTabWidget::newView( const QString& id, const QPixmap& pm, const QString& label )\n"
            "{\n"
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "    fprintf(stderr, \"[be300-tabs] newView start %s\\n\", id.latin1() );\n"
            "#endif\n"
            "    LauncherView* view = new LauncherView( stack );\n"
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "    fprintf(stderr, \"[be300-tabs] newView LauncherView ready %s\\n\", id.latin1() );\n"
            "#endif\n"
            "    connect( view, SIGNAL(clicked(const AppLnk*)),\n"
            "        this, SIGNAL(clicked(const AppLnk*)));\n"
            "    connect( view, SIGNAL(rightPressed(AppLnk*)),\n"
            "        this, SIGNAL(rightPressed(AppLnk*)));\n"
            "\n"
            "\n"
            "    int n = categoryBar->count();\n"
            "\n"
            "    stack->addWidget( view, n );\n"
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "    fprintf(stderr, \"[be300-tabs] newView stack add done %s\\n\", id.latin1() );\n"
            "#endif\n"
            "\n"
            "    LauncherTab *tab = new LauncherTab( id, view, pm, label );\n"
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "    fprintf(stderr, \"[be300-tabs] newView tab ready %s\\n\", id.latin1() );\n"
            "#endif\n"
            "    categoryBar->insertTab( tab, n-1 );\n"
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "    fprintf(stderr, \"[be300-tabs] newView tab inserted %s\\n\", id.latin1() );\n"
            "#endif\n"
            "    if ( id == \"Documents\" ) {\n"
            "        docview = view;\n"
            "        m_DocumentTabId = n;\n"
            "    }\n"
            "\n"
            "#ifndef QT_QWS_CASSIOPEIA\n"
            "    odebug << \"inserting \" << id << \" at \" << n-1 << \"\" << oendl;\n"
            "\n"
            "    Config cfg(\"Launcher\");\n"
            "    setTabAppearance( tab, cfg );\n"
            "\n"
            "    cfg.setGroup( \"GUI\" );\n"
            "    view->setBusyIndicatorType( cfg.readEntry( \"BusyType\", QString::null ) );\n"
            "#endif\n"
            "\n"
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "    fprintf(stderr, \"[be300-tabs] newView done %s\\n\", id.latin1() );\n"
            "#endif\n"
            "    return view;\n"
            "}\n",
            1,
        )
    text = text.replace(
        "    if ( n == 0 ) {\n"
        "        stack->raiseWidget( view );\n"
        "        view->show();\n"
        "        fprintf(stderr, \"[be300-tabs] newView first view raised %s\\n\", id.latin1() );\n"
        "    }\n",
        "",
    )
    text = text.replace(
        "        tabs->categoryBar->showTab(type);\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "        tabs->raiseTabWidget();\n"
        "#endif\n",
        "        tabs->categoryBar->showTab(type);\n",
    )
    if "[be300-launcher] typeAdded enter" not in text:
        text = text.replace(
            "void Launcher::typeAdded( const QString& type, const QString& name,\n"
            "                    const QPixmap& pixmap, const QPixmap& )\n"
            "{\n"
            "    tabs->newView( type, pixmap, name );\n"
            "    ids.append( type );\n"
            "    /* this will be called in applicationScanningProgress with value 100! */\n"
            "//    tb->refreshStartMenu();\n"
            "\n"
            "    static bool first = TRUE;\n"
            "    if ( first ) {\n"
            "    first = FALSE;\n"
            "        tabs->categoryBar->showTab(type);\n"
            "    }\n"
            "\n"
            "    tabs->view( type )->setUpdatesEnabled( FALSE );\n"
            "    tabs->view( type )->setSortEnabled( FALSE );\n"
            "}\n",
            "void Launcher::typeAdded( const QString& type, const QString& name,\n"
            "                    const QPixmap& pixmap, const QPixmap& )\n"
            "{\n"
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "    fprintf(stderr, \"[be300-launcher] typeAdded enter %s\\n\", type.latin1() );\n"
            "#endif\n"
            "    tabs->newView( type, pixmap, name );\n"
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "    fprintf(stderr, \"[be300-launcher] typeAdded newView done %s\\n\", type.latin1() );\n"
            "#endif\n"
            "    ids.append( type );\n"
            "    /* this will be called in applicationScanningProgress with value 100! */\n"
            "//    tb->refreshStartMenu();\n"
            "\n"
            "    static bool first = TRUE;\n"
            "    if ( first ) {\n"
            "    first = FALSE;\n"
            "        tabs->categoryBar->showTab(type);\n"
            "    }\n"
            "\n"
            "    LauncherView *view = tabs->view( type );\n"
            "    if ( view ) {\n"
            "        view->setUpdatesEnabled( FALSE );\n"
            "        view->setSortEnabled( FALSE );\n"
            "    }\n"
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "    fprintf(stderr, \"[be300-launcher] typeAdded done %s\\n\", type.latin1() );\n"
            "#endif\n"
            "}\n",
            1,
        )
    if "[be300-launcher] applicationAdded enter" not in text:
        text = text.replace(
            "void Launcher::applicationAdded( const QString& type, const AppLnk& app )\n"
            "{\n"
            "    if ( app.type() == \"Separator\" )  // No tr\n"
            "    return;\n"
            "\n"
            "    LauncherView *view = tabs->view( type );\n"
            "    if ( view )\n"
            "    view->addItem( new AppLnk( app ), FALSE );\n"
            "    else\n"
            "    owarn << \"addAppLnk: No view for type \" << type.latin1() << \". Can't add app \"\n"
            "             << app.name().latin1() << \"!\",\n"
            "\n"
            "    MimeType::registerApp( app );\n"
            "}\n",
            "void Launcher::applicationAdded( const QString& type, const AppLnk& app )\n"
            "{\n"
            "    if ( app.type() == \"Separator\" )  // No tr\n"
            "    return;\n"
            "\n"
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "    fprintf(stderr, \"[be300-launcher] applicationAdded enter %s\\n\", app.name().latin1() );\n"
            "#endif\n"
            "    LauncherView *view = tabs->view( type );\n"
            "    if ( view ) {\n"
            "        view->addItem( new AppLnk( app ), FALSE );\n"
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "        fprintf(stderr, \"[be300-launcher] applicationAdded view add done %s\\n\", app.name().latin1() );\n"
            "#endif\n"
            "    } else\n"
            "    owarn << \"addAppLnk: No view for type \" << type.latin1() << \". Can't add app \"\n"
            "             << app.name().latin1() << \"!\",\n"
            "\n"
            "#ifndef QT_QWS_CASSIOPEIA\n"
            "    MimeType::registerApp( app );\n"
            "#else\n"
            "    fprintf(stderr, \"[be300-launcher] applicationAdded done %s\\n\", app.name().latin1() );\n"
            "#endif\n"
            "}\n",
            1,
        )
    text = text.replace(
        "void Launcher::documentAdded( const DocLnk& doc )\n"
        "{\n"
        "    tabs->docView()->addItem( new DocLnk( doc ), FALSE );\n"
        "}\n",
        "void Launcher::documentAdded( const DocLnk& doc )\n"
        "{\n"
        "    if ( !tabs || !tabs->docView() )\n"
        "        return;\n"
        "    tabs->docView()->addItem( new DocLnk( doc ), FALSE );\n"
        "}\n",
        1,
    )
    text = text.replace(
        "void Launcher::aboutToAddBegin()\n"
        "{\n"
        "    tabs->docView()->setUpdatesEnabled( false );\n"
        "}\n",
        "void Launcher::aboutToAddBegin()\n"
        "{\n"
        "    if ( !tabs || !tabs->docView() )\n"
        "        return;\n"
        "    tabs->docView()->setUpdatesEnabled( false );\n"
        "}\n",
        1,
    )
    text = text.replace(
        "void Launcher::aboutToAddEnd()\n"
        "{\n"
        "    tabs->docView()->setUpdatesEnabled( true );\n"
        "}\n",
        "void Launcher::aboutToAddEnd()\n"
        "{\n"
        "    if ( !tabs || !tabs->docView() )\n"
        "        return;\n"
        "    tabs->docView()->setUpdatesEnabled( true );\n"
        "}\n",
        1,
    )
    text = text.replace(
        "void Launcher::showLoadingDocs()\n"
        "{\n"
        "    tabs->docView()->hide();\n"
        "}\n",
        "void Launcher::showLoadingDocs()\n"
        "{\n"
        "    if ( !tabs || !tabs->docView() )\n"
        "        return;\n"
        "    tabs->docView()->hide();\n"
        "}\n",
        1,
    )
    text = text.replace(
        "void Launcher::showDocTab()\n"
        "{\n"
        "    if ( tabs->categoryBar->currentView() == tabs->docView() )\n"
        "    tabs->docView()->show();\n"
        "}\n",
        "void Launcher::showDocTab()\n"
        "{\n"
        "    if ( !tabs || !tabs->docView() )\n"
        "        return;\n"
        "    if ( tabs->categoryBar->currentView() == tabs->docView() )\n"
        "    tabs->docView()->show();\n"
        "}\n",
        1,
    )
    text = text.replace(
        "void Launcher::documentRemoved( const DocLnk& doc )\n"
        "{\n"
        "    tabs->docView()->removeLink( doc.linkFile() );\n"
        "}\n",
        "void Launcher::documentRemoved( const DocLnk& doc )\n"
        "{\n"
        "    if ( !tabs || !tabs->docView() )\n"
        "        return;\n"
        "    tabs->docView()->removeLink( doc.linkFile() );\n"
        "}\n",
        1,
    )
    text = text.replace(
        "void Launcher::documentChanged( const DocLnk& oldDoc, const DocLnk& newDoc )\n"
        "{\n"
        "#if 0\n",
        "void Launcher::documentChanged( const DocLnk& oldDoc, const DocLnk& newDoc )\n"
        "{\n"
        "    if ( !tabs || !tabs->docView() )\n"
        "        return;\n"
        "#if 0\n",
        1,
    )
    text = text.replace(
        "void Launcher::allDocumentsRemoved()\n"
        "{\n"
        "    tabs->docView()->removeAllItems();\n"
        "}\n",
        "void Launcher::allDocumentsRemoved()\n"
        "{\n"
        "    if ( !tabs || !tabs->docView() )\n"
        "        return;\n"
        "    tabs->docView()->removeAllItems();\n"
        "}\n",
        1,
    )
    text = text.replace(
        "void Launcher::documentScanningProgress( int percent )\n"
        "{\n"
        "    switch ( percent ) {\n",
        "void Launcher::documentScanningProgress( int percent )\n"
        "{\n"
        "    if ( !tabs || !tabs->docView() )\n"
        "        return;\n"
        "    switch ( percent ) {\n",
        1,
    )
    if "[be300-launcher] app scan complete" not in text:
        text = text.replace(
            "        case 100: {\n"
            "        for ( QStringList::ConstIterator it=ids.begin(); it!= ids.end(); ++it) {\n"
            "        tabs->view( (*it) )->setUpdatesEnabled( TRUE );\n"
            "        tabs->view( (*it) )->setSortEnabled( TRUE );\n"
            "        }\n"
            "            tb->refreshStartMenu();\n"
            "        break;\n"
            "        }\n",
            "        case 100: {\n"
            "#ifndef QT_QWS_CASSIOPEIA\n"
            "        for ( QStringList::ConstIterator it=ids.begin(); it!= ids.end(); ++it) {\n"
            "        tabs->view( (*it) )->setUpdatesEnabled( TRUE );\n"
            "        tabs->view( (*it) )->setSortEnabled( TRUE );\n"
            "        }\n"
            "#else\n"
            "            fprintf(stderr, \"[be300-launcher] skip enabling launcher views\\n\" );\n"
            "#endif\n"
            "            tb->refreshStartMenu();\n"
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "            fprintf(stderr, \"[be300-launcher] app scan complete ids=%d launcher=%dx%d+%d+%d visible=%d\\n\",\n"
            "                    (int)ids.count(), width(), height(), x(), y(), isVisible() ? 1 : 0 );\n"
            "            if ( !ids.isEmpty() ) {\n"
            "                QString firstType = *ids.begin();\n"
            "                tabs->categoryBar->showTab( firstType );\n"
            "                LauncherView *view = tabs->view( firstType );\n"
            "                if ( view ) {\n"
            "                    fprintf(stderr, \"[be300-launcher] queue first view %s geom=%dx%d+%d+%d visible=%d\\n\",\n"
            "                            firstType.latin1(), view->width(), view->height(), view->x(), view->y(), view->isVisible() ? 1 : 0 );\n"
            "                }\n"
            "            }\n"
            "            tabs->show();\n"
            "            if ( tabs->layout() )\n"
                "                tabs->layout()->activate();\n"
            "            showMaximized();\n"
            "            raise();\n"
            "            update();\n"
            "            fprintf(stderr, \"[be300-launcher] queued repaint done launcher=%dx%d+%d+%d visible=%d\\n\",\n"
            "                    width(), height(), x(), y(), isVisible() ? 1 : 0 );\n"
            "#endif\n"
            "        break;\n"
            "        }\n",
            1,
        )
    text = text.replace(
        "                    fprintf(stderr, \"[be300-launcher] force first view %s geom=%dx%d+%d+%d visible=%d\\n\",\n"
        "                            firstType.latin1(), view->width(), view->height(), view->x(), view->y(), view->isVisible() ? 1 : 0 );\n"
        "                    view->setUpdatesEnabled( TRUE );\n"
        "                    view->show();\n"
        "                    view->setFocus();\n"
        "                    view->relayout();\n"
        "                    view->update();\n"
        "                    view->repaint( TRUE );\n"
        "                }\n"
        "            }\n"
        "            tabs->show();\n"
        "            if ( tabs->layout() )\n"
        "                tabs->layout()->activate();\n"
        "            showMaximized();\n"
        "            raise();\n"
        "            update();\n"
        "            repaint( TRUE );\n"
        "            qApp->processEvents();\n"
        "            fprintf(stderr, \"[be300-launcher] forced repaint done launcher=%dx%d+%d+%d visible=%d\\n\",\n",
        "                    fprintf(stderr, \"[be300-launcher] queue first view %s geom=%dx%d+%d+%d visible=%d\\n\",\n"
        "                            firstType.latin1(), view->width(), view->height(), view->x(), view->y(), view->isVisible() ? 1 : 0 );\n"
        "                }\n"
        "            }\n"
        "            tabs->show();\n"
        "            if ( tabs->layout() )\n"
        "                tabs->layout()->activate();\n"
        "            showMaximized();\n"
        "            raise();\n"
        "            update();\n"
        "            fprintf(stderr, \"[be300-launcher] queued repaint done launcher=%dx%d+%d+%d visible=%d\\n\",\n",
    )
    text = text.replace(
        "        for ( QStringList::ConstIterator it=ids.begin(); it!= ids.end(); ++it) {\n"
        "        tabs->view( (*it) )->setUpdatesEnabled( TRUE );\n"
        "        tabs->view( (*it) )->setSortEnabled( TRUE );\n"
        "        }\n"
        "            tb->refreshStartMenu();\n",
        "#ifndef QT_QWS_CASSIOPEIA\n"
        "        for ( QStringList::ConstIterator it=ids.begin(); it!= ids.end(); ++it) {\n"
        "        tabs->view( (*it) )->setUpdatesEnabled( TRUE );\n"
        "        tabs->view( (*it) )->setSortEnabled( TRUE );\n"
        "        }\n"
        "#else\n"
        "            fprintf(stderr, \"[be300-launcher] skip enabling launcher views\\n\" );\n"
        "#endif\n"
        "            tb->refreshStartMenu();\n",
    )
    text = text.replace(
        "                    view->setUpdatesEnabled( TRUE );\n"
        "                    view->show();\n"
        "                    view->setFocus();\n"
        "                    view->update();\n",
        "",
    )
    text = text.replace(
        "            QTimer::singleShot( 0, tabs, SLOT( raiseTabWidget() ) );\n"
        "            QTimer::singleShot( 100, tabs, SLOT( raiseTabWidget() ) );\n",
        "",
    )
    text = text.replace(
        "                    view->update();\n"
        "                }\n"
        "                tabs->raiseTabWidget();\n"
        "            }\n"
        "            tabs->show();\n",
        "                    view->update();\n"
        "                }\n"
        "            }\n"
        "            tabs->show();\n",
    )
    if "[be300-launcher] skip initLayout timer" not in text:
        text = text.replace(
            "    QTimer::singleShot( 0, tabs, SLOT( initLayout() ) );\n"
            "    qApp->setMainWidget( this );\n"
            "    QTimer::singleShot( 500, this, SLOT( makeVisible() ) );\n"
            "    fprintf(stderr, \"[be300-launcher] createGUI done\\n\");\n",
            "#ifndef QT_QWS_CASSIOPEIA\n"
            "    fprintf(stderr, \"[be300-launcher] initLayout timer\\n\");\n"
            "    QTimer::singleShot( 0, tabs, SLOT( initLayout() ) );\n"
            "#else\n"
            "    fprintf(stderr, \"[be300-launcher] skip initLayout timer\\n\");\n"
            "#endif\n"
            "    fprintf(stderr, \"[be300-launcher] set main widget\\n\");\n"
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "    qApp->setMainWidget( this );\n"
            "#else\n"
            "    qApp->setMainWidget( this );\n"
            "#endif\n"
            "    fprintf(stderr, \"[be300-launcher] main widget set\\n\");\n"
            "#ifndef QT_QWS_CASSIOPEIA\n"
            "    fprintf(stderr, \"[be300-launcher] makeVisible timer\\n\");\n"
            "    QTimer::singleShot( 500, this, SLOT( makeVisible() ) );\n"
            "#else\n"
            "    fprintf(stderr, \"[be300-launcher] show BE300 launcher\\n\");\n"
            "    showMaximized();\n"
            "    raise();\n"
            "    repaint( FALSE );\n"
            "    if ( be300Home ) {\n"
            "        be300Home->setGeometry( 0, 0, qApp->desktop()->width(), qApp->desktop()->height() - 24 );\n"
            "        be300Home->show();\n"
            "        be300Home->raise();\n"
            "        be300Home->repaint( FALSE );\n"
            "    }\n"
            "    fprintf(stderr, \"[be300-launcher] BE300 home shown\\n\");\n"
            "#endif\n"
            "    fprintf(stderr, \"[be300-launcher] createGUI done\\n\");\n",
            1,
        )
    text = text.replace(
        "    fprintf(stderr, \"[be300-launcher] set main widget\\n\");\n"
        "    qApp->setMainWidget( this );\n"
        "    fprintf(stderr, \"[be300-launcher] main widget set\\n\");\n"
        "#ifndef QT_QWS_CASSIOPEIA\n"
        "    fprintf(stderr, \"[be300-launcher] makeVisible timer\\n\");\n"
        "    QTimer::singleShot( 500, this, SLOT( makeVisible() ) );\n"
        "#else\n"
        "    fprintf(stderr, \"[be300-launcher] show maximized\\n\");\n"
        "    showMaximized();\n"
        "    fprintf(stderr, \"[be300-launcher] show maximized done\\n\");\n"
        "#endif\n",
        "    fprintf(stderr, \"[be300-launcher] set main widget\\n\");\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    qApp->setMainWidget( this );\n"
        "#else\n"
        "    qApp->setMainWidget( this );\n"
        "#endif\n"
        "    fprintf(stderr, \"[be300-launcher] main widget set\\n\");\n"
        "#ifndef QT_QWS_CASSIOPEIA\n"
        "    fprintf(stderr, \"[be300-launcher] makeVisible timer\\n\");\n"
        "    QTimer::singleShot( 500, this, SLOT( makeVisible() ) );\n"
        "#else\n"
        "    fprintf(stderr, \"[be300-launcher] show BE300 launcher\\n\");\n"
        "    showMaximized();\n"
        "    raise();\n"
        "    repaint( FALSE );\n"
        "    if ( be300Home ) {\n"
        "        be300Home->setGeometry( 0, 0, qApp->desktop()->width(), qApp->desktop()->height() - 24 );\n"
        "        be300Home->show();\n"
        "        be300Home->raise();\n"
        "        be300Home->repaint( FALSE );\n"
        "    }\n"
        "    fprintf(stderr, \"[be300-launcher] BE300 home shown\\n\");\n"
        "#endif\n",
        1,
    )
    text = text.replace(
        "    qApp->setMainWidget( be300Home ? be300Home : this );\n",
        "    qApp->setMainWidget( this );\n",
    )
    text = text.replace(
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    if ( be300Home )\n"
        "        qApp->setMainWidget( be300Home );\n"
        "    else\n"
        "        qApp->setMainWidget( this );\n"
        "#else\n"
        "    qApp->setMainWidget( this );\n"
        "#endif\n",
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    qApp->setMainWidget( this );\n"
        "#else\n"
        "    qApp->setMainWidget( this );\n"
        "#endif\n",
    )
    text = text.replace(
        "#else\n"
        "    fprintf(stderr, \"[be300-launcher] show BE300 home\\n\");\n"
        "    if ( be300Home ) {\n"
        "        be300Home->setGeometry( 0, 0, qApp->desktop()->width(), qApp->desktop()->height() - 24 );\n"
        "        be300Home->show();\n"
        "        be300Home->raise();\n"
        "        be300Home->repaint( FALSE );\n"
        "    }\n"
        "    fprintf(stderr, \"[be300-launcher] BE300 home shown\\n\");\n"
        "#endif\n",
        "#else\n"
        "    fprintf(stderr, \"[be300-launcher] show BE300 launcher\\n\");\n"
        "    showMaximized();\n"
        "    raise();\n"
        "    repaint( FALSE );\n"
        "    if ( be300Home ) {\n"
        "        be300Home->setGeometry( 0, 0, qApp->desktop()->width(), qApp->desktop()->height() - 24 );\n"
        "        be300Home->show();\n"
        "        be300Home->raise();\n"
        "        be300Home->repaint( FALSE );\n"
        "    }\n"
        "    fprintf(stderr, \"[be300-launcher] BE300 home shown\\n\");\n"
        "#endif\n",
    )
    text = text.replace(
        "            if ( !be300Home ) {\n"
        "                showMaximized();\n"
        "                raise();\n"
        "                repaint( FALSE );\n"
        "            }\n"
        "            fprintf(stderr, \"[be300-launcher] queued repaint done launcher=%dx%d+%d+%d visible=%d\\n\",\n",
        "            showMaximized();\n"
        "            raise();\n"
        "            repaint( FALSE );\n"
        "            fprintf(stderr, \"[be300-launcher] queued repaint done launcher=%dx%d+%d+%d visible=%d\\n\",\n",
        1,
    )
    text = text.replace(
        "            if ( be300Home ) {\n"
        "                be300Home->setGeometry( 0, 0, qApp->desktop()->width(), qApp->desktop()->height() - 24 );\n"
        "                be300Home->show();\n"
        "                be300Home->raise();\n"
        "                be300Home->repaint( FALSE );\n"
        "            }\n"
        "            showMaximized();\n"
        "            raise();\n"
        "            repaint( FALSE );\n",
        "            showMaximized();\n"
        "            raise();\n"
        "            repaint( FALSE );\n"
        "            if ( be300Home ) {\n"
        "                be300Home->setGeometry( 0, 0, qApp->desktop()->width(), qApp->desktop()->height() - 24 );\n"
        "                be300Home->show();\n"
        "                be300Home->raise();\n"
        "                be300Home->repaint( FALSE );\n"
        "            }\n",
    )
    text = text.replace(
        "void LauncherTabWidget::setLoadingProgress( int percent )\n"
        "{\n"
        "    docLoadingWidgetProgress->setProgress( (percent / 4) * 4 );\n"
        "}\n",
        "void LauncherTabWidget::setLoadingProgress( int percent )\n"
        "{\n"
        "    if ( !docLoadingWidgetProgress )\n"
        "        return;\n"
        "    docLoadingWidgetProgress->setProgress( (percent / 4) * 4 );\n"
        "}\n",
        1,
    )
    path.write_text(text, encoding="latin-1")

path = root / "core/launcher/startmenu.cpp"
if path.exists():
    text = path.read_text(encoding="latin-1")
    if "BE300 lightweight Start menu" not in text:
        text = text.replace(
            "    startButtonPixmap = \"go\"; // No tr\n\n"
            "    int sz = AppLnk::smallIconSize()+3;\n",
            "    startButtonPixmap = \"go\"; // No tr\n\n"
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "    /* BE300 lightweight Start menu: avoid synchronous pixmap and\n"
            "       menu construction before the launcher paints. */\n"
            "    setText( \"O\" );\n"
            "    setAlignment( AlignCenter );\n"
            "    setFixedWidth( 18 );\n"
            "#else\n"
            "    int sz = AppLnk::smallIconSize()+3;\n",
            1,
        )
        text = text.replace(
            "    setPixmap(pm);\n"
            "    setFocusPolicy( NoFocus );\n\n"
            "    useWidePopupMenu = true;\n"
            "    launchMenu = 0;\n"
            "    currentItem = 0;\n"
            "    refreshMenu();\n\n"
            "    qApp->installEventFilter( this );\n",
            "    setPixmap(pm);\n"
            "#endif\n"
            "    setFocusPolicy( NoFocus );\n\n"
            "    useWidePopupMenu = true;\n"
            "    launchMenu = 0;\n"
            "    currentItem = 0;\n"
            "#ifndef QT_QWS_CASSIOPEIA\n"
            "    refreshMenu();\n"
            "#else\n"
            "    launchMenu = new StartPopupMenu( this );\n"
            "#endif\n\n"
            "    qApp->installEventFilter( this );\n",
            1,
        )
    text = text.replace(
        "    QPixmap pm;\n"
        "    pm.convertFromImage(OResource::loadImage( startButtonPixmap, OResource::NoScale ).smoothScale( sz,sz) );\n"
        "    setPixmap(pm);\n",
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    QPixmap pm = OResource::loadPixmap( startButtonPixmap, OResource::SmallIcon );\n"
        "    if ( pm.isNull() )\n"
        "        pm = OResource::loadPixmap( \"launcher/opielogo16x16\", OResource::NoScale );\n"
        "#else\n"
        "    QPixmap pm;\n"
        "    pm.convertFromImage(OResource::loadImage( startButtonPixmap, OResource::NoScale ).smoothScale( sz,sz) );\n"
        "#endif\n"
        "    setPixmap(pm);\n",
        1,
    )
    if "BE300 keeps the Start menu applet-free" not in text:
        text = text.replace(
            "void StartMenu::loadApplets()\n{\n",
            "void StartMenu::loadApplets()\n"
            "{\n"
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "    /* BE300 keeps the Start menu applet-free during launcher\n"
            "       startup; the app tabs provide the primary menu. */\n"
            "    return;\n"
            "#endif\n",
            1,
        )
    if "BE300 fixed Start menu" not in text:
        text = text.replace(
            "    QDir dir( MimeType::appsFolderName(), QString::null, QDir::Name );\n"
            "    createMenuEntries( menu, dir, ltabs, lot );\n\n"
            "   \tif ( !menu->count() ) sepfirst = TRUE;\n",
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "    /* BE300 fixed Start menu: avoid recursive app directory scans. */\n"
            "    static const char *be300Apps[][2] = {\n"
            "        { \"Terminal\", \"embeddedkonsole\" },\n"
            "        { \"Web\", \"ubrowser\" },\n"
            "        { \"Text\", \"textedit\" },\n"
            "        { \"Files\", \"advancedfm\" },\n"
            "        { \"Calculator\", \"calculator\" },\n"
            "        { \"Clock\", \"clock\" },\n"
            "        { \"System\", \"sysinfo\" },\n"
            "        { \"Help\", \"helpbrowser\" },\n"
            "        { \"Contacts\", \"addressbook\" },\n"
            "        { \"Calendar\", \"datebook\" },\n"
            "        { \"Todo\", \"todolist\" },\n"
            "        { \"Notes\", \"opie-notes\" }\n"
            "    };\n"
            "    for ( unsigned int i = 0; i < sizeof(be300Apps) / sizeof(be300Apps[0]); ++i ) {\n"
            "        AppLnk *applnk = new AppLnk;\n"
            "        applnk->setName( QString( be300Apps[i][0] ) );\n"
            "        applnk->setExec( QString( be300Apps[i][1] ) );\n"
            "        applnk->setType( QString( \"Application\" ) );\n"
            "        applnk->setLinkFile( QString( \"/opt/QtPalmtop/apps/BE300/\" ) + QString( be300Apps[i][1] ) + QString( \".desktop\" ) );\n"
            "        menu->insertItem( applnk->name(), currentItem + APPLNK_ID_OFFSET );\n"
            "        appLnks.insert( currentItem + APPLNK_ID_OFFSET, applnk );\n"
            "        currentItem++;\n"
            "    }\n"
            "#else\n"
            "    QDir dir( MimeType::appsFolderName(), QString::null, QDir::Name );\n"
            "    createMenuEntries( menu, dir, ltabs, lot );\n"
            "#endif\n\n"
            "   \tif ( !menu->count() ) sepfirst = TRUE;\n",
            1,
        )
    path.write_text(text, encoding="latin-1")

path = root / "core/launcher/taskbar.cpp"
if path.exists():
    text = path.read_text(encoding="latin-1")
    if "#include <stdio.h>" not in text:
        text = text.replace("#include <stdlib.h>\n", "#include <stdlib.h>\n#include <stdio.h>\n", 1)
    if "[be300-taskbar]" not in text:
        text = text.replace(
            "TaskBar::TaskBar() : QHBox(0, 0, WStyle_Customize | WStyle_Tool | WStyle_StaysOnTop | WGroupLeader)\n"
            "{\n"
            "    /* Read InputMethod Config */\n"
            "    readConfig();\n\n"
            "    sm = new StartMenu( this );\n",
            "TaskBar::TaskBar() : QHBox(0, 0, WStyle_Customize | WStyle_Tool | WStyle_StaysOnTop | WGroupLeader)\n"
            "{\n"
            "    fprintf(stderr, \"[be300-taskbar] ctor start\\n\");\n"
            "    waitTimer = 0;\n"
            "    waitIcon = 0;\n"
            "    inputMethods = 0;\n"
            "    sysTray = 0;\n"
            "    runningAppBar = 0;\n"
            "    stack = 0;\n"
            "    clearer = 0;\n"
            "    label = 0;\n"
            "    lockState = 0;\n"
            "    sm = 0;\n\n"
            "    /* Read InputMethod Config */\n"
            "    readConfig();\n"
            "    fprintf(stderr, \"[be300-taskbar] config read\\n\");\n\n"
            "    fprintf(stderr, \"[be300-taskbar] new StartMenu\\n\");\n"
            "    sm = new StartMenu( this );\n"
            "    fprintf(stderr, \"[be300-taskbar] StartMenu ready\\n\");\n",
            1,
        )
        text = text.replace(
            "    inputMethods = new InputMethods( this );\n"
            "    connect( inputMethods, SIGNAL(inputToggled(bool)),\n"
            "\t     this, SLOT(calcMaxWindowRect()) );\n\n"
            "    stack = new QWidgetStack( this );\n",
            "#if !defined(QT_QWS_CASSIOPEIA) || defined(BE300_ENABLE_TASKBAR_PLUGINS)\n"
            "    inputMethods = new InputMethods( this );\n"
            "    connect( inputMethods, SIGNAL(inputToggled(bool)),\n"
            "\t     this, SLOT(calcMaxWindowRect()) );\n"
            "#else\n"
            "    fprintf(stderr, \"[be300-taskbar] skip input method plugins\\n\");\n"
            "#endif\n\n"
            "    fprintf(stderr, \"[be300-taskbar] new widget stack\\n\");\n"
            "    stack = new QWidgetStack( this );\n",
            1,
        )
        text = text.replace(
            "    runningAppBar = new RunningAppBar(stack);\n"
            "    stack->raiseWidget(runningAppBar);\n\n"
            "    waitIcon = new Wait( this );\n"
            "    (void) new AppIcons( this );\n\n"
            "    sysTray = new SysTray( this );\n",
            "    runningAppBar = new RunningAppBar(stack);\n"
            "    stack->raiseWidget(runningAppBar);\n"
            "    fprintf(stderr, \"[be300-taskbar] RunningAppBar ready\\n\");\n\n"
            "#if !defined(QT_QWS_CASSIOPEIA) || defined(BE300_ENABLE_TASKBAR_PLUGINS)\n"
            "    waitIcon = new Wait( this );\n"
            "    fprintf(stderr, \"[be300-taskbar] Wait icon ready\\n\");\n"
            "#else\n"
            "    fprintf(stderr, \"[be300-taskbar] skip wait icon\\n\");\n"
            "#endif\n"
            "#if !defined(QT_QWS_CASSIOPEIA) || defined(BE300_ENABLE_TASKBAR_PLUGINS)\n"
            "    (void) new AppIcons( this );\n\n"
            "    sysTray = new SysTray( this );\n"
            "#else\n"
            "    fprintf(stderr, \"[be300-taskbar] skip tray applets\\n\");\n"
            "#endif\n",
            1,
        )
        text = text.replace(
            "    connect( qApp, SIGNAL(symbol()), this, SLOT(toggleSymbolInput()) );\n"
            "    connect( qApp, SIGNAL(numLockStateToggle()), this, SLOT(toggleNumLockState()) );\n"
            "    connect( qApp, SIGNAL(capsLockStateToggle()), this, SLOT(toggleCapsLockState()) );\n"
            "}\n",
            "    connect( qApp, SIGNAL(symbol()), this, SLOT(toggleSymbolInput()) );\n"
            "    connect( qApp, SIGNAL(numLockStateToggle()), this, SLOT(toggleNumLockState()) );\n"
            "    connect( qApp, SIGNAL(capsLockStateToggle()), this, SLOT(toggleCapsLockState()) );\n"
            "    fprintf(stderr, \"[be300-taskbar] ctor done\\n\");\n"
            "}\n",
            1,
        )
    if "skip wait icon" not in text:
        text = text.replace(
            "    waitIcon = new Wait( this );\n"
            "    fprintf(stderr, \"[be300-taskbar] Wait icon ready\\n\");\n",
            "#if !defined(QT_QWS_CASSIOPEIA) || defined(BE300_ENABLE_TASKBAR_PLUGINS)\n"
            "    waitIcon = new Wait( this );\n"
            "    fprintf(stderr, \"[be300-taskbar] Wait icon ready\\n\");\n"
            "#else\n"
            "    fprintf(stderr, \"[be300-taskbar] skip wait icon\\n\");\n"
            "#endif\n",
            1,
        )
    text = text.replace("    if ( !text.isEmpty() ) {\n\tlabel->setText( text );\n", "    if ( !label || !stack )\n        return;\n    if ( !text.isEmpty() ) {\n\tlabel->setText( text );\n", 1)
    text = text.replace("    label->clear();\n    stack->raiseWidget(runningAppBar);\n", "    if ( !label || !stack || !runningAppBar )\n        return;\n    label->clear();\n    stack->raiseWidget(runningAppBar);\n", 1)
    text = text.replace("    waitIcon->setWaiting( true );\n", "    if ( !waitIcon || !waitTimer )\n        return;\n    waitIcon->setWaiting( true );\n", 1)
    text = text.replace("    waitTimer->stop();\n    waitIcon->setWaiting( false );\n", "    if ( !waitIcon || !waitTimer )\n        return;\n    waitTimer->stop();\n    waitIcon->setWaiting( false );\n", 1)
    text = text.replace("    waitTimer->stop();\n    waitIcon->setWaiting( false );\n", "    if ( !waitIcon || !waitTimer )\n        return;\n    waitTimer->stop();\n    waitIcon->setWaiting( false );\n", 1)
    text = text.replace("void TaskBar::stopWait()\n{\n    waitTimer->stop();\n    waitIcon->setWaiting( false );\n}\n", "void TaskBar::stopWait()\n{\n    if ( !waitIcon || !waitTimer )\n        return;\n    waitTimer->stop();\n    waitIcon->setWaiting( false );\n}\n", 1)
    text = text.replace("        QRect ir = inputMethods->inputRect();\n", "        QRect ir = inputMethods ? inputMethods->inputRect() : QRect();\n", 1)
    text = text.replace("inputMethods->hideInputMethod();", "if ( inputMethods ) inputMethods->hideInputMethod();")
    text = text.replace("inputMethods->showInputMethod();", "if ( inputMethods ) inputMethods->showInputMethod();")
    text = text.replace("inputMethods->showInputMethod(name);", "if ( inputMethods ) inputMethods->showInputMethod(name);")
    text = text.replace("inputMethods->readConfig();\n\tinputMethods->loadInputMethods();", "if ( inputMethods ) {\n\t    inputMethods->readConfig();\n\t    inputMethods->loadInputMethods();\n\t}")
    text = text.replace(
        "    QString unicodeInput = qApp->translate( \"InputMethods\", \"Unicode\" );\n"
        "    if ( inputMethods->currentShown() == unicodeInput ) {\n",
        "    if ( !inputMethods )\n"
        "        return;\n"
        "    QString unicodeInput = qApp->translate( \"InputMethods\", \"Unicode\" );\n"
        "    if ( inputMethods->currentShown() == unicodeInput ) {\n",
        1,
    )
    path.write_text(text, encoding="latin-1")

path = root / "core/launcher/screensaver.cpp"
if path.exists():
    text = path.read_text()
    if "BE300 keeps OPIE screen saver intervals inert" not in text:
        text = text.replace(
            "void OpieScreenSaver::setIntervals ( int dim, int lightoff, int suspend )\n{\n",
            "void OpieScreenSaver::setIntervals ( int dim, int lightoff, int suspend )\n"
            "{\n"
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "    /* BE300 keeps OPIE screen saver intervals inert; the legacy\n"
            "       interval setup can block before the launcher paints. */\n"
            "    (void) dim;\n"
            "    (void) lightoff;\n"
            "    (void) suspend;\n"
            "    m_enable_dim = false;\n"
            "    m_enable_lightoff = false;\n"
            "    m_enable_suspend = false;\n"
            "    m_enable_dim_ac = false;\n"
            "    m_enable_lightoff_ac = false;\n"
            "    m_enable_suspend_ac = false;\n"
            "    return;\n"
            "#endif\n",
            1,
        )
    path.write_text(text)

path = root / "libopie2/opiecore/oapplication.cpp"
if path.exists():
    text = path.read_text(encoding="latin-1")
    if "[be300-oapp]" not in text:
        text = text.replace(
            "{\n    init();\n}\n\nOApplication::OApplication( int& argc, char** argv, const QCString& rAppName )",
            "{\n    fprintf(stderr, \"[be300-oapp] ctor typed body\\n\");\n"
            "    init();\n"
            "    fprintf(stderr, \"[be300-oapp] ctor typed done\\n\");\n"
            "}\n\n"
            "OApplication::OApplication( int& argc, char** argv, const QCString& rAppName )",
            1,
        )
        text = text.replace(
            "{\n    init();\n}\n\n\nOApplication::~OApplication()",
            "{\n    fprintf(stderr, \"[be300-oapp] ctor named body\\n\");\n"
            "    init();\n"
            "    fprintf(stderr, \"[be300-oapp] ctor named done\\n\");\n"
            "}\n\n\n"
            "OApplication::~OApplication()",
            1,
        )
        text = text.replace(
            "{\n    d = new Internal::OApplicationPrivate();\n",
            "{\n    fprintf(stderr, \"[be300-oapp] init start\\n\");\n"
            "    d = new Internal::OApplicationPrivate();\n"
            "    fprintf(stderr, \"[be300-oapp] private allocated\\n\");\n",
            1,
        )
        text = text.replace(
            "        OApplication::_instance = this;\n",
            "        OApplication::_instance = this;\n"
            "        fprintf(stderr, \"[be300-oapp] instance set\\n\");\n",
            1,
        )
        text = text.replace(
            "    }\n    else\n    {\n        ofatal << \"OApplication: Can't create more than one OApplication object. Aborting.\" << oendl;",
            "        fprintf(stderr, \"[be300-oapp] init done\\n\");\n"
            "    }\n"
            "    else\n"
            "    {\n"
            "        fprintf(stderr, \"[be300-oapp] duplicate instance\\n\");\n"
            "        ofatal << \"OApplication: Can't create more than one OApplication object. Aborting.\" << oendl;",
            1,
        )
    path.write_text(text, encoding="latin-1")

path = root / "libopie2/opiepim/backend/backends.pro"
if path.exists():
    text = path.read_text()
    text = text.replace("        backend/opimchangelog_sql.cpp           \\\n", "")
    text = text.replace("        backend/opimio.cpp                      \\\n        backend/opimsql.cpp\n",
                        "        backend/opimio.cpp\n")
    text = text.replace("        backend/opimchangelog_sql.h            \\\n", "")
    text = text.replace("        backend/opimio.h                       \\\n        backend/opimsql.h\n",
                        "        backend/opimio.h\n")
    path.write_text(text)

path = root / "core/launcher/server.pro"
if path.exists():
    text = path.read_text()
    text = text.replace(
        "LIBS        += -lqpe -lopiecore2 -lopieui2 -lopiesecurity2 -lqrsync",
        "LIBS        += -lqpe -lopiecore2 -lopieui2 -lopiesecurity2 -lopiepim2 -lqrsync",
    )
    path.write_text(text)

for rel in ("library/library.pro", "libopie2/opiecore/opiecore.pro"):
    path = root / rel
    if not path.exists():
        continue
    text = path.read_text()
    if "-lsysfs" not in text:
        text += "\nLIBS += -lsysfs\n"
    path.write_text(text)

for rel in ("library/Makefile", "libopie2/opiecore/Makefile"):
    path = root / rel
    if not path.exists():
        continue
    text = path.read_text()
    if "-lsysfs" not in text:
        text = text.replace(" -L$(OPIEDIR)/lib -lqte", " -lsysfs -L$(OPIEDIR)/lib -lqte")
    path.write_text(text)

path = root / "libopie2/opiecore/odebug.cpp"
if path.exists():
    data = path.read_bytes()
    data = data.replace(
        b"#if defined(__UCLIBC__)\n#define OPIE_NO_BACKTRACE\n#endif",
        b"#define OPIE_NO_BACKTRACE",
    )
    path.write_bytes(data)
PY
	python3 /work/board/opie/patch_opie_sources.py "$OPIE_SRC"
	if [ ! -f "$OPIE_SRC/.be300-opie-patched" ]; then
		echo "=== Applying BE-300 OPIE build patches ==="
		OPIE_SRC="$OPIE_SRC" \
		BE300_OPIE_ARCH_CFLAGS="$ARCH_CFLAGS" \
		BE300_OPIE_TARGET_STRIP="$TARGET_STRIP" \
			python3 - <<'PY'
import os
from pathlib import Path

root = Path(os.environ["OPIE_SRC"])
arch_cflags = os.environ.get("BE300_OPIE_ARCH_CFLAGS", "-march=mips2 -mfpxx")

path = root / "config.in"
text = path.read_text()
if "config TARGET_BE300" not in text:
    text = text.replace(
        '  config TARGET_X86\n    boolean "Intel X86"\n',
        '  config TARGET_BE300\n    boolean "Casio BE-300 (mipsel/Qt Embedded)"\n\n'
        '  config TARGET_X86\n    boolean "Intel X86"\n',
        1,
    )
text = text.replace(
    '  default "qws/linux-generic-g++" if TARGET_X86 && (! X11)\n',
    '  default "qws/linux-be300-g++" if TARGET_BE300 && (! X11)\n'
    '  default "qws/linux-generic-g++" if TARGET_X86 && (! X11)\n',
    1,
)
text = text.replace(
    '  default "-march=armv4 -mtune=strongarm1100 -mapcs-32 -fexpensive-optimizations -fomit-frame-pointer -O2" if TARGET_IPAQ\n',
    f'  default "{arch_cflags} -Os -fomit-frame-pointer" if TARGET_BE300\n'
    '  default "-march=armv4 -mtune=strongarm1100 -mapcs-32 -fexpensive-optimizations -fomit-frame-pointer -O2" if TARGET_IPAQ\n',
    1,
)
text = text.replace(
    '  default y if TARGET_RAMSES || TARGET_IPAQ || TARGET_SIMPAD || TARGET_SHARP\n'
    '  default n if ! (TARGET_IPAQ || TARGET_SIMPAD || TARGET_RAMSES || TARGET_SHARP)\n',
    '  default y if TARGET_BE300 || TARGET_RAMSES || TARGET_IPAQ || TARGET_SIMPAD || TARGET_SHARP\n'
    '  default n if ! (TARGET_BE300 || TARGET_IPAQ || TARGET_SIMPAD || TARGET_RAMSES || TARGET_SHARP)\n',
    1,
)
path.write_text(text)

path = root / "Vars.make"
text = path.read_text()
if "CONFIG_TARGET_BE300" not in text:
    text = text.replace(
        "ifdef CONFIG_TARGET_X86\n    PLATFORM=x86-linux\nendif\n",
        "ifdef CONFIG_TARGET_BE300\n    PLATFORM=be300-linux\nendif\n"
        "ifdef CONFIG_TARGET_X86\n    PLATFORM=x86-linux\nendif\n",
        1,
    )
    text = text.replace(
        "ifeq ($(STRIP),)\n",
        "ifeq ($(STRIP),)\n"
        "    ifneq ($(CONFIG_TARGET_BE300),)\n"
        "        STRIP=" + os.environ.get("BE300_OPIE_TARGET_STRIP", "mipsel-linux-gnu-strip") + "\n"
        "    endif\n",
        1,
    )
path.write_text(text)

for rel in ["core/launcher/server.pro"]:
    path = root / rel
    text = path.read_text()
    text = text.replace(" -lsysfs", "")
    text = text.replace("-lsysfs", "")
    path.write_text(text)

for rel in ["library/library.pro", "libopie2/opiecore/opiecore.pro"]:
    path = root / rel
    text = path.read_text()
    if "-lsysfs" not in text:
        text += "\nLIBS += -lsysfs\n"
    path.write_text(text)

for rel in ["library/Makefile", "libopie2/opiecore/Makefile"]:
    path = root / rel
    if not path.exists():
        continue
    text = path.read_text()
    if "-lsysfs" not in text:
        text = text.replace(" -L$(OPIEDIR)/lib -lqte", " -lsysfs -L$(OPIEDIR)/lib -lqte")
    path.write_text(text)

# The BE-300 profile ships a direct launcher instead of OPIE's first-use
# calibration/shutdown flow.
path = root / "core/launcher/server.pro"
text = path.read_text()
text = text.replace("LIBS        += -lqpe -lopiecore2 -lopieui2 -lopiesecurity2 -lqrsync\n",
                    "LIBS        += -lqpe -lopiecore2 -lopieui2 -lopiesecurity2 -lqrsync\n")
path.write_text(text)
PY
	fi
	mkdir -p "$OPIE_SRC/mkspecs/qws/linux-be300-g++"
	cp "$OPIE_SRC/mkspecs/qws/linux-generic-g++/qplatformdefs.h" \
		"$OPIE_SRC/mkspecs/qws/linux-be300-g++/qplatformdefs.h"
	cat >"$OPIE_SRC/mkspecs/qws/linux-be300-g++/qmake.conf" <<EOF
MAKEFILE_GENERATOR = UNIX
TEMPLATE = app
CONFIG += qt link_prl
QMAKE_CC = ${TARGET_CC}
QMAKE_LEX = flex
QMAKE_LEXFLAGS =
QMAKE_YACC = yacc
QMAKE_YACCFLAGS = -d
QMAKE_CFLAGS = -pipe ${COMMON_CFLAGS}
QMAKE_CFLAGS_WARN_ON = -Wall -W
QMAKE_CFLAGS_WARN_OFF =
QMAKE_CFLAGS_RELEASE = \$(if \$(CFLAGS_RELEASE),\$(CFLAGS_RELEASE), -Os)
QMAKE_CFLAGS_DEBUG = -g
QMAKE_CFLAGS_SHLIB = -fPIC
QMAKE_CFLAGS_YACC = -Wno-unused -Wno-parentheses
QMAKE_CFLAGS_THREAD = -D_REENTRANT
QMAKE_CXX = ${TARGET_CXX}
QMAKE_CXXFLAGS = -pipe -DQWS ${COMMON_CXXFLAGS}
QMAKE_CXXFLAGS_WARN_ON = \$\$QMAKE_CFLAGS_WARN_ON
QMAKE_CXXFLAGS_WARN_OFF =
QMAKE_CXXFLAGS_RELEASE = \$\$QMAKE_CFLAGS_RELEASE
QMAKE_CXXFLAGS_DEBUG = \$\$QMAKE_CFLAGS_DEBUG
QMAKE_CXXFLAGS_SHLIB = \$\$QMAKE_CFLAGS_SHLIB
QMAKE_CXXFLAGS_YACC = \$\$QMAKE_CFLAGS_YACC
QMAKE_CXXFLAGS_THREAD = \$\$QMAKE_CFLAGS_THREAD
QMAKE_INCDIR =
QMAKE_LIBDIR = ${BE300_LIBS}/lib /tmp/libgcc_patched
QMAKE_INCDIR_X11 =
QMAKE_LIBDIR_X11 =
QMAKE_INCDIR_QT = \$(QTDIR)/include
QMAKE_LIBDIR_QT = \$(QTDIR)/lib
QMAKE_INCDIR_OPENGL =
QMAKE_LIBDIR_OPENGL =
QMAKE_INCDIR_QTOPIA = \$(QPEDIR)/include
QMAKE_LIBDIR_QTOPIA = \$(QPEDIR)/lib
QMAKE_LINK = ${TARGET_CC}
QMAKE_LINK_SHLIB = ${TARGET_CC}
QMAKE_LFLAGS = ${COMMON_LFLAGS}
QMAKE_LFLAGS_RELEASE =
QMAKE_LFLAGS_DEBUG =
QMAKE_LFLAGS_SHLIB = -shared
QMAKE_LFLAGS_PLUGIN = \$\$QMAKE_LFLAGS_SHLIB
QMAKE_LFLAGS_SONAME = -Wl,-soname,
QMAKE_LFLAGS_THREAD =
QMAKE_RPATH = -Wl,-rpath-link,
QMAKE_LIBS = ${COMMON_LIBS}
QMAKE_LIBS_DYNLOAD = -ldl
QMAKE_LIBS_X11 =
QMAKE_LIBS_X11SM =
QMAKE_LIBS_QT = -lqte
QMAKE_LIBS_QT_THREAD = -lqte-mt
QMAKE_LIBS_QT_OPENGL =
QMAKE_LIBS_QTOPIA = -lqpe -lsysfs
QMAKE_LIBS_THREAD = -lpthread
QMAKE_MOC = \$(QTDIR)/bin/moc
QMAKE_UIC = \$(QTDIR)/bin/uic
QMAKE_AR = ${TARGET_AR} cqs
QMAKE_RANLIB = ${TARGET_RANLIB}
QMAKE_TAR = tar -cf
QMAKE_GZIP = gzip -9f
QMAKE_COPY = cp -f
QMAKE_MOVE = mv -f
QMAKE_DEL_FILE = rm -f
QMAKE_DEL_DIR = rmdir
QMAKE_CHK_DIR_EXISTS = test -d
QMAKE_MKDIR = mkdir -p
EOF
	touch "$OPIE_SRC/.be300-opie-patched"
}

build_opie() {
	if [ -f "$OPIE_SRC/$OPIE_BUILD_STAMP" ]; then
		return
	fi

	echo "=== Building OPIE ${OPIE_VERSION} BE-300 profile: ${OPIE_PROFILE} ==="
	(
		cd "$OPIE_SRC"
		export QTDIR="$QT_SRC"
		export QPEDIR="$OPIE_SRC"
		export OPIEDIR="$OPIE_SRC"
		export QMAKESPEC="$OPIE_SRC/mkspecs/qws/linux-be300-g++"
		export PLATFORM=be300-linux
		export PATH="$OPIEDIR/qmake:$QTDIR/bin:$PATH"
		export CFLAGS_EXTRA=
		export CXXFLAGS_EXTRA=
		export LFLAGS_EXTRA=
		export LIBS_EXTRA=
		export STRIP="$TARGET_STRIP"
		: >"$OPIE_BUILD_LOG"
		cp "$OPIE_CONFIG" .config
		for cfg in \
			CONFIG_TARGET_MACOSX CONFIG_TARGET_C700 CONFIG_TARGET_RAMSES \
			CONFIG_TARGET_SIMPAD CONFIG_TARGET_YOPY CONFIG_TARGET_HTC \
			CONFIG_TARGET_64BIT; do
			if ! grep -q "^${cfg}=\|^# ${cfg} is not set" .config; then
				echo "# ${cfg} is not set" >> .config
			fi
		done
		if [ "$BE300_LIBC" = "uclibc" ]; then
			sed -i \
				"s@^CONFIG_OPTIMIZATIONS=.*@CONFIG_OPTIMIZATIONS=\"${ARCH_CFLAGS} -Os -fomit-frame-pointer\"@" \
				.config
		fi
		rm -f .depends
		rm -f lib/lib*.so*
		find . -name .obj -type d -prune -exec rm -rf {} +
		rm -rf plugins
		find . -name Makefile -type f -print | while read -r mf; do
			case "$mf" in
				./Makefile|./qmake/Makefile|./scripts/kconfig/Makefile)
					continue
					;;
			esac
			if grep -q 'musl-gcc\.specs.*musl-gcc\.specs' "$mf" 2>/dev/null; then
				rm -f "$mf"
			fi
		done
		yes "" | make oldconfig >>"$OPIE_BUILD_LOG" 2>&1 || exit 1
		sed -n 's/^CONFIG_\([^=]*\)=y$/\1/p' "$OPIE_CONFIG" \
			>/tmp/be300-opie-config-allow
		awk '
			BEGIN {
				while ((getline sym < "/tmp/be300-opie-config-allow") > 0)
					allow[sym] = 1
			}
			/^CONFIG_[A-Za-z0-9_-]+=(y|m)$/ {
				sym = $0
				sub(/^CONFIG_/, "", sym)
				sub(/=(y|m)$/, "", sym)
				if (!(sym in allow)) {
					print "# CONFIG_" sym " is not set"
					next
				}
			}
			{ print }
		' .config >/tmp/be300-opie-config-pruned
		mv /tmp/be300-opie-config-pruned .config
		rm -f .depends gen.pro
		make -C qmake >>"$OPIE_BUILD_LOG" 2>&1 || exit 1
		find . -name Makefile -type f -print | while read -r mf; do
			case "$mf" in
				./Makefile|./qmake/Makefile|./scripts/kconfig/Makefile)
					continue
					;;
			esac
			if grep -q '\$(QMAKE).* -o Makefile\|qmake.* -o Makefile' "$mf" 2>/dev/null; then
				rm -f "$mf"
			fi
		done
		make "$OPIE_SRC/gen.pro" >>"$OPIE_BUILD_LOG" 2>&1 || exit 1
		make "$QT_SRC/stamp-headers" "$OPIE_SRC/stamp-headers" \
			>>"$OPIE_BUILD_LOG" 2>&1 || exit 1
		while read -r dir pro; do
			[ -n "$dir" ] || continue
			(
				cd "$dir"
				"$OPIEDIR/qmake/qmake" -o Makefile "$pro"
				make QMAKE="$OPIEDIR/qmake/qmake"
			) >>"$OPIE_BUILD_LOG" 2>&1 || exit 1
		done <<'EOF'
library library.pro
libopie2/opiecore opiecore.pro
libopie2/opieui opieui.pro
libopie2/opiepim opiepim.pro
libopie2/opiesecurity opiesecurity.pro
libqtaux libqtaux.pro
rsync rsync.pro
EOF
		make -j"$(nproc)" >>"$OPIE_BUILD_LOG" 2>&1 || exit 1
				touch "$OPIE_BUILD_STAMP"
	) || {
		tail -120 "$OPIE_BUILD_LOG"
		exit 1
	}
}

copy_if_exists() {
	local src="$1"
	local dst="$2"

	if [ -e "$src" ] || [ -L "$src" ]; then
		mkdir -p "$(dirname "$dst")"
		cp -a "$src" "$dst"
	fi
}

install_selected_desktop_files() {
	local src rel extra_desktops

	extra_desktops=""
	if [ "$OPIE_PROFILE" = "opie64" ]; then
		extra_desktops="\
		Applications/checkbook.desktop \
		Applications/euroconv.desktop \
		Applications/opie-sheet.desktop \
		Applications/opie-write.desktop \
		Applications/tableviewer.desktop \
		1Pim/osearch.desktop \
		1Pim/today.desktop \
		Settings/aqpkg.desktop \
		Settings/appearance.desktop \
		Settings/calibrate.desktop \
		Settings/language.desktop \
		Settings/quit.desktop \
		Settings/systemtime.desktop \
		Settings/confedit.desktop \
		Settings/doctab.desktop"
	fi

	for rel in \
		"Applications/embeddedkonsole.desktop" \
		"Applications/helpbrowser.desktop" \
		"Applications/textedit.desktop" \
		"Applications/advancedfm.desktop" \
		"Applications/calculator.desktop" \
		"Applications/clock.desktop" \
		"Applications/sysinfo.desktop" \
		"Unsupported/ubrowser.desktop" \
		"1Pim/addressbook.desktop" \
		"1Pim/datebook.desktop" \
		"1Pim/todolist.desktop" \
		"1Pim/opie-notes.desktop" \
		"Settings/launchersettings.desktop" \
		"Settings/buttonsettings.desktop" \
		"Settings/light-and-power.desktop" \
		"Settings/citytime.desktop" \
		"Settings/security.desktop" \
		$extra_desktops; do
		src="$OPIE_SRC/apps/$rel"
		copy_if_exists "$src" "$ROOTFS/opt/QtPalmtop/apps/$rel"
	done

	for rel in Applications Unsupported 1Pim Settings; do
		copy_if_exists "$OPIE_SRC/apps/$rel/.directory" \
			"$ROOTFS/opt/QtPalmtop/apps/$rel/.directory"
	done
	if [ "$OPIE_PROFILE" = "opie64" ]; then
		copy_if_exists "$OPIE_SRC/apps/Applications/backup.desktop" \
			"$ROOTFS/opt/QtPalmtop/apps/Settings/backup.desktop"
	fi
	copy_if_exists "$OPIE_SRC/apps/Applications/citytime.desktop" \
		"$ROOTFS/opt/QtPalmtop/apps/Settings/citytime.desktop"
	copy_if_exists "$OPIE_SRC/apps/.directory" "$ROOTFS/opt/QtPalmtop/apps/.directory"
}

install_selected_pics() {
	local rel extra_pics

	extra_pics=""
	if [ "$OPIE_PROFILE" = "opie64" ]; then
		extra_pics="\
		aqpkg appearance backup calibrate checkbook clockapplet confedit \
		doctab euroconv memory netsystemtime opie-sheet opie-write \
		osearch screenshotapplet \
		tableviewer today"
	fi

	mkdir -p "$ROOTFS/opt/QtPalmtop/pics"
	for rel in \
		opie launcher inline taskbar logo background \
		konsole console helpbrowser textedit advancedfm calc clock sysinfo ubrowser \
		addressbook datebook todo opie-notes launchersettings buttonsettings \
		lightandpower citytime security pickboard keyboard flat \
		$extra_pics; do
		if [ -d "$OPIE_SRC/pics/$rel" ]; then
			cp -a "$OPIE_SRC/pics/$rel" "$ROOTFS/opt/QtPalmtop/pics/"
		fi
	done

	find "$ROOTFS/opt/QtPalmtop/apps" -name '*.desktop' -print | while read -r desktop; do
		grep '^Icon[[:space:]]*=' "$desktop" | cut -d= -f2- | while read -r icon; do
			[ -n "$icon" ] || continue
			local_icon="$(printf '%s' "$icon" | tr '[:upper:]' '[:lower:]')"
			for ext in png xpm; do
				copy_if_exists "$OPIE_SRC/pics/${icon}.${ext}" \
					"$ROOTFS/opt/QtPalmtop/pics/${icon}.${ext}"
				copy_if_exists "$OPIE_SRC/pics/inline/${icon}.${ext}" \
					"$ROOTFS/opt/QtPalmtop/pics/${icon}.${ext}"
				copy_if_exists "$OPIE_SRC/pics/inline/${local_icon}.${ext}" \
					"$ROOTFS/opt/QtPalmtop/pics/${icon}.${ext}"
			done
		done
	done
}

install_opie_rootfs() {
	local extra_apps

	echo "=== Installing OPIE runtime into BE-300 rootfs ==="
	mkdir -p "$ROOTFS/lib" "$ROOTFS/etc" "$ROOTFS/opt/QtPalmtop"/{bin,lib,plugins,apps,pics,help,etc,share} \
		"$ROOTFS/opt/QtPalmtop/lib/fonts" "$ROOTFS/root/Settings"

	if [ "$BE300_LIBC" = "musl" ]; then
		if [ ! -e /work/musl-mipsel/lib/ld-musl-mipsel.so.1 ]; then
			echo "ERROR: musl shared loader missing; rebuild musl with shared support" >&2
			exit 1
		fi
		cp -a /work/musl-mipsel/lib/ld-musl-mipsel.so.1 "$ROOTFS/lib/"
		cp -a /work/musl-mipsel/lib/libc.so "$ROOTFS/lib/"
	elif [ ! -e "$ROOTFS/lib/ld-uClibc.so.0" ]; then
		echo "ERROR: uClibc-ng runtime missing from rootfs" >&2
		exit 1
	fi

	cp -a "$QT_SRC/lib"/libqte.so* "$ROOTFS/opt/QtPalmtop/lib/"
	for font in fixed_120_50.qpf fixed_120_50_t5.qpf \
			fixed_70_50.qpf fixed_70_50_t5.qpf \
			helvetica_80_50.qpf helvetica_100_50.qpf \
			helvetica_120_50.qpf micro_40_50.qpf; do
		copy_if_exists "$QT_SRC/lib/fonts/$font" \
			"$ROOTFS/opt/QtPalmtop/lib/fonts/$font"
	done
	cat > "$ROOTFS/opt/QtPalmtop/lib/fonts/fontdir" << 'FONTDIR'
# Qt/Embedded requires this file to exist. QPF fonts in this directory
# are discovered directly, so the OPIE image keeps fontdir intentionally
# minimal to avoid loading BDF/FreeType renderers on the 16 MiB BE-300.
FONTDIR

	printf '1 0 0 0 1 0 1\n' >"$ROOTFS/etc/pointercal"

	find "$OPIE_SRC/lib" -maxdepth 1 -name 'lib*.so*' -print \
		-exec cp -a {} "$ROOTFS/opt/QtPalmtop/lib/" \;
	if [ -d "$OPIE_SRC/plugins" ]; then
		cp -a "$OPIE_SRC/plugins/." "$ROOTFS/opt/QtPalmtop/plugins/"
	fi

	extra_apps=""
	if [ "$OPIE_PROFILE" = "opie64" ]; then
		extra_apps="today osearch opie-write checkbook opie-sheet tableviewer euroconv aqpkg backup language systemtime appearance calibrate doctab confedit"
	fi
	for app in qpe quicklauncher embeddedkonsole helpbrowser textedit addressbook \
			datebook todolist opie-notes advancedfm calculator clock sysinfo \
			ubrowser launchersettings buttonsettings light-and-power citytime \
			security $extra_apps; do
		copy_if_exists "$OPIE_SRC/bin/$app" "$ROOTFS/opt/QtPalmtop/bin/$app"
	done

	install_selected_desktop_files
	install_selected_pics
	if [ "$OPIE_PROFILE" = "opie64" ] && \
			[ -f /work/board/opie/defaults/opie-background.png ]; then
		mkdir -p "$ROOTFS/opt/QtPalmtop/pics/launcher"
		cp /work/board/opie/defaults/opie-background.png \
			"$ROOTFS/opt/QtPalmtop/pics/launcher/opie-background.png"
	fi
	find "$ROOTFS/opt/QtPalmtop/pics" -type f \
		\( -name '*.jpg' -o -name '*.jpeg' -o -name 'firstuse-*' \) -print |
		while read -r pic; do
			rm -f "$pic"
		done
	if [ "$OPIE_PROFILE" = "opie64" ] && \
			[ -d "$ROOTFS/opt/QtPalmtop/pics/sysinfo" ]; then
		find "$ROOTFS/opt/QtPalmtop/pics/sysinfo" -type f -print |
			while read -r pic; do
				case "$(basename "$pic")" in
				SystemInfo.png|mounticon.png|*tabicon.png)
					;;
				*)
					rm -f "$pic"
					;;
				esac
			done
	fi
	if [ "$OPIE_PROFILE" != "opie64" ]; then
		rm -rf "$ROOTFS/opt/QtPalmtop/pics/sysinfo"
		rm -f "$ROOTFS/opt/QtPalmtop/plugins/inputmethods/libqhandwriting.so"* \
			"$ROOTFS/opt/QtPalmtop/plugins/inputmethods/libqpickboard.so"*
	fi
	mkdir -p "$ROOTFS/opt/QtPalmtop/etc/default"
	cp -a /work/board/opie/defaults/. "$ROOTFS/opt/QtPalmtop/etc/default/"
	if [ "$OPIE_PROFILE" = "opie64" ] && \
			[ -f /work/board/opie/defaults/Launcher-opie64.conf ]; then
		cp /work/board/opie/defaults/Launcher-opie64.conf \
			"$ROOTFS/opt/QtPalmtop/etc/default/Launcher.conf"
	fi
	rm -f "$ROOTFS/opt/QtPalmtop/etc/default/Launcher-opie64.conf"
	rm -f "$ROOTFS/opt/QtPalmtop/etc/default/opie-background.png"
	copy_if_exists "$OPIE_SRC/etc/mime.types" "$ROOTFS/opt/QtPalmtop/etc/mime.types"
	copy_if_exists "$OPIE_SRC/etc/mime.conf" "$ROOTFS/opt/QtPalmtop/etc/mime.conf"

	mkdir -p "$ROOTFS/root/Applications" "$ROOTFS/root/Documents" \
		"$ROOTFS/root/Settings"
	${TARGET_CC} $COMMON_CFLAGS $COMMON_LFLAGS /work/board/opie/be300_vtmode.c \
		-o "$ROOTFS/bin/be300-vtmode"
	cp /work/board/opie/start-opie "$ROOTFS/bin/start-opie"
	chmod +x "$ROOTFS/bin/start-opie"

	find "$ROOTFS/opt/QtPalmtop" -type f \( -perm -111 -o -name 'lib*.so*' \) -print |
		while read -r f; do
			${TARGET_STRIP} "$f" >/dev/null 2>&1 || true
		done

	du -sh "$ROOTFS" "$ROOTFS/opt/QtPalmtop"
}

prepare_support_libs
prepare_qt_source
patch_qt_source
build_qt
build_qt_host_tools
patch_opie_source
build_opie
install_opie_rootfs
