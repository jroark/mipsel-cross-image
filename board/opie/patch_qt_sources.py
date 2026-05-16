#!/usr/bin/env python3
"""Final BE-300 Qt/Embedded source fixes applied before building."""

from pathlib import Path
import sys


ROOT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("/work/qt-2.3.10-be300")

BE300_QWS_ACCEL = """#ifdef QT_QWS_CASSIOPEIA
#ifndef BE300_VRC4173_QWS_ACCEL
#define BE300_VRC4173_QWS_ACCEL

#define BE300_FB_WIDTH 240
#define BE300_FB_HEIGHT 320
#define BE300_FB_STRIDE 512
#define BE300_VRC4173_PHYS 0x0a000000UL
#define BE300_VRC4173_MAP_SIZE 0x1000
#define BE300_VRC4173_DISPLAY_OFFSET 0x200

static volatile unsigned int *be300_vrc4173_display = 0;
static int be300_vrc4173_fd = -1;
static bool be300_vrc4173_failed = FALSE;

static bool be300_vrc4173_enabled()
{
    static int checked = 0;
    static bool enabled = FALSE;

    if ( !checked ) {
        const char *want = getenv(\"BE300_QWS_ACCEL\");
        enabled = want && want[0] && want[0] != '0' &&
                  getenv(\"BE300_QWS_NOACCEL\") == 0;
        checked = 1;
    }

    return enabled;
}

static bool be300_vrc4173_map()
{
    if ( be300_vrc4173_display )
        return TRUE;
    if ( be300_vrc4173_failed || !be300_vrc4173_enabled() )
        return FALSE;

    be300_vrc4173_fd = ::open(\"/dev/mem\", O_RDWR | O_SYNC);
    if ( be300_vrc4173_fd < 0 ) {
        be300_vrc4173_failed = TRUE;
        return FALSE;
    }

    void *map = ::mmap( 0, BE300_VRC4173_MAP_SIZE,
                        PROT_READ | PROT_WRITE, MAP_SHARED,
                        be300_vrc4173_fd, BE300_VRC4173_PHYS );
    if ( map == MAP_FAILED ) {
        ::close( be300_vrc4173_fd );
        be300_vrc4173_fd = -1;
        be300_vrc4173_failed = TRUE;
        return FALSE;
    }

    be300_vrc4173_display =
        (volatile unsigned int *)((unsigned char *)map + BE300_VRC4173_DISPLAY_OFFSET);
    return TRUE;
}

static inline void be300_vrc4173_write( unsigned int reg, unsigned int value )
{
    be300_vrc4173_display[reg >> 2] = value;
}

static inline unsigned int be300_vrc4173_read( unsigned int reg )
{
    return be300_vrc4173_display[reg >> 2];
}

static inline void be300_vrc4173_write_offset( unsigned int lo_reg,
                                               unsigned int hi_reg,
                                               unsigned int value )
{
    be300_vrc4173_write( lo_reg, value & 0xffff );
    be300_vrc4173_write( hi_reg, (value >> 16) & 0xffff );
}

static void be300_vrc4173_wait_idle()
{
    int i;

    for ( i = 0; i < 100000; ++i ) {
        if ( !(be300_vrc4173_read( 0x34 ) & 1) )
            break;
    }
}

static bool be300_accel_screen16( unsigned char *base, int lineStep )
{
    ulong offset = 0;

    if ( !qt_screen || qt_screen->width() != BE300_FB_WIDTH ||
         qt_screen->height() != BE300_FB_HEIGHT ||
         qt_screen->depth() != 16 || lineStep != BE300_FB_STRIDE )
        return FALSE;

    if ( !qt_screen->onCard( base, offset ) || offset != 0 )
        return FALSE;

    return be300_vrc4173_map();
}

static bool be300_accel_bounds( int x, int y, int w, int h )
{
    return x >= 0 && y >= 0 && w > 0 && h > 0 &&
           x + w <= BE300_FB_WIDTH && y + h <= BE300_FB_HEIGHT;
}

static void be300_vrc4173_fill16( int lineStep, int x, int y, int w, int h,
                                  unsigned int color )
{
    unsigned int dst = y * lineStep + x * 2;

    be300_vrc4173_wait_idle();
    be300_vrc4173_write( 0x00, 0 );
    be300_vrc4173_write( 0x04, color & 0xffff );
    be300_vrc4173_write( 0x08, w );
    be300_vrc4173_write( 0x0c, h );
    be300_vrc4173_write_offset( 0x10, 0x14, dst );
    be300_vrc4173_write( 0x34, 1 );
    be300_vrc4173_wait_idle();
}

static void be300_vrc4173_copy16( int lineStep, int dx, int dy, int w, int h,
                                  int sx, int sy )
{
    unsigned int mode = 1;
    unsigned int src = sy * lineStep + sx * 2;
    unsigned int dst = dy * lineStep + dx * 2;

    if ( dx > sx ) {
        mode |= 0x400;
        src += (w - 1) * 2;
        dst += (w - 1) * 2;
    }
    if ( dy > sy ) {
        mode |= 0x800;
        src += (h - 1) * lineStep;
        dst += (h - 1) * lineStep;
    }

    be300_vrc4173_wait_idle();
    be300_vrc4173_write( 0x00, mode );
    be300_vrc4173_write( 0x08, w );
    be300_vrc4173_write( 0x0c, h );
    be300_vrc4173_write_offset( 0x10, 0x14, dst );
    be300_vrc4173_write_offset( 0x18, 0x1c, src );
    be300_vrc4173_write( 0x34, 1 );
    be300_vrc4173_wait_idle();
}

static bool be300_accel_fill16( unsigned char *base, int lineStep,
                                int x, int y, int w, int h,
                                unsigned int color,
                                const QRect *clips, int nclips )
{
    int i;

    if ( !be300_accel_screen16( base, lineStep ) )
        return FALSE;

    for ( i = 0; i < nclips; ++i ) {
        int x1 = x > clips[i].left() ? x : clips[i].left();
        int y1 = y > clips[i].top() ? y : clips[i].top();
        int x2 = x + w - 1 < clips[i].right() ? x + w - 1 : clips[i].right();
        int y2 = y + h - 1 < clips[i].bottom() ? y + h - 1 : clips[i].bottom();

        if ( x1 > x2 || y1 > y2 )
            continue;
        if ( !be300_accel_bounds( x1, y1, x2 - x1 + 1, y2 - y1 + 1 ) )
            return FALSE;
        be300_vrc4173_fill16( lineStep, x1, y1, x2 - x1 + 1, y2 - y1 + 1,
                              color );
    }

    return TRUE;
}

static bool be300_accel_copy16( unsigned char *base, int lineStep,
                                int dx, int dy, int w, int h,
                                int sx, int sy, const QRect &clip )
{
    int x1 = dx > clip.left() ? dx : clip.left();
    int y1 = dy > clip.top() ? dy : clip.top();
    int x2 = dx + w - 1 < clip.right() ? dx + w - 1 : clip.right();
    int y2 = dy + h - 1 < clip.bottom() ? dy + h - 1 : clip.bottom();

    if ( !be300_accel_screen16( base, lineStep ) )
        return FALSE;

    if ( x1 > x2 || y1 > y2 )
        return TRUE;

    sx += x1 - dx;
    sy += y1 - dy;
    w = x2 - x1 + 1;
    h = y2 - y1 + 1;

    if ( !be300_accel_bounds( x1, y1, w, h ) ||
         !be300_accel_bounds( sx, sy, w, h ) )
        return FALSE;

    be300_vrc4173_copy16( lineStep, x1, y1, w, h, sx, sy );
    return TRUE;
}

#endif
#endif
"""

BE300_FILL_HOOK = """#ifdef QT_QWS_CASSIOPEIA
    /* BE300_ACCEL_FILL_HOOK */
    if ( this->is_screen_gfx && type == QGfxRaster_Generic &&
         depth == 16 && myrop == CopyROP && cbrush.style() == SolidPattern ) {
        useBrush();
        if ( be300_accel_fill16( buffer, linestep(), rx + xoffs, ry + yoffs,
                                 w, h, pixel, cliprect, ncliprect ) ) {
            GFX_END
            return;
        }
    }
#endif
"""

BE300_SCROLL_HOOK = """#ifdef QT_QWS_CASSIOPEIA
    /* BE300_ACCEL_SCROLL_HOOK */
    if ( this->is_screen_gfx && type == QGfxRaster_Generic &&
         depth == 16 && myrop == CopyROP && ncliprect == 1 &&
         be300_accel_copy16( buffer, linestep(),
                             rx + xoffs, ry + yoffs, w, h,
                             sx + xoffs, sy + yoffs, cliprect[0] ) ) {
        GFX_END
        return;
    }
#endif
"""


def read_text(path):
    return path.read_text(encoding="latin-1")


def write_text(path, text):
    path.write_text(text, encoding="latin-1")


def strip_be300_fprintf(text):
    lines = text.splitlines(True)
    out = []
    i = 0
    while i < len(lines):
        line = lines[i]
        if 'fprintf(stderr, "[be300-' in line or 'qDebug("[be300-' in line:
            while i < len(lines):
                skipped = lines[i]
                i += 1
                if ");" in skipped:
                    break
            continue
        out.append(line)
        i += 1
    return "".join(out)


def patch_file(rel):
    path = ROOT / rel
    if path.exists():
        write_text(path, strip_be300_fprintf(read_text(path)))


def patch_mouse():
    path = ROOT / "src/kernel/qwsmouse_qws.cpp"
    if not path.exists():
        return

    text = strip_be300_fprintf(read_text(path))
    text = text.replace('\tprintf("\\033[?25l"); fflush(stdout);\n', "")
    text = text.replace('    printf("\\033[?25l"); fflush(stdout); // VT100 cursor off\n', "")
    text = text.replace(
        "\tif ( n < 0 && errno != EAGAIN )\n"
        "\t    qWarning(\"touch read error %s\", strerror(errno));\n"
        "\treturn;\n",
        "\treturn;\n",
    )
    if "BE300_TOUCH_MOVE_MIN_MS" not in text:
        text = text.replace(
            "#define BE300_BTN_TOUCH 0x14a\n",
            "#define BE300_BTN_TOUCH 0x14a\n"
            "#define BE300_TOUCH_MOVE_MIN_MS 35u\n"
            "#define BE300_TOUCH_MOVE_MIN_DELTA 3\n",
            1,
        )
    if "evLastSentPressed" not in text:
        text = text.replace(
            "    bool evDirty;\n"
            "    bool evHaveX;\n"
            "    bool evHaveY;\n"
            "private slots:\n",
            "    bool evDirty;\n"
            "    bool evHaveX;\n"
            "    bool evHaveY;\n"
            "    bool evLastSentPressed;\n"
            "    int evLastSentX;\n"
            "    int evLastSentY;\n"
            "    unsigned int evLastMoveMsec;\n"
            "private slots:\n",
            1,
        )
        text = text.replace(
            "    evPressed(FALSE), evDirty(FALSE), evHaveX(FALSE), evHaveY(FALSE)\n",
            "    evPressed(FALSE), evDirty(FALSE), evHaveX(FALSE), evHaveY(FALSE),\n"
            "    evLastSentPressed(FALSE), evLastSentX(0), evLastSentY(0),\n"
            "    evLastMoveMsec(0)\n",
            1,
        )
    old = (
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
        "\treturn;\n"
        "    }\n"
    )
    new = (
        "    if ( useEvdev ) {\n"
        "\tBe300InputEvent event;\n"
        "\tint n;\n"
        "\twhile ( (n = read(mouseFD, &event, sizeof(event))) == (int)sizeof(event) ) {\n"
        "\t    unsigned int eventMsec = event.sec * 1000u + event.usec / 1000u;\n"
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
        "\t\tif ( evDirty && ( !evPressed || ( evHaveX && evHaveY ) ) ) {\n"
        "\t\t    QPoint p = ( evHaveX && evHaveY ) ? QPoint(evX, evY) : mousePos;\n"
        "\t\t    bool send = FALSE;\n"
        "\n"
        "\t\t    if ( evPressed ) {\n"
        "\t\t\tif ( !evLastSentPressed ) {\n"
        "\t\t\t    send = TRUE;\n"
        "\t\t\t} else {\n"
        "\t\t\t    int dx = QABS( p.x() - evLastSentX );\n"
        "\t\t\t    int dy = QABS( p.y() - evLastSentY );\n"
        "\t\t\t    unsigned int elapsed = eventMsec - evLastMoveMsec;\n"
        "\n"
        "\t\t\t    if ( ( dx || dy ) &&\n"
        "\t\t\t\t ( dx + dy >= BE300_TOUCH_MOVE_MIN_DELTA ||\n"
        "\t\t\t\t   elapsed >= BE300_TOUCH_MOVE_MIN_MS ) )\n"
        "\t\t\t\tsend = TRUE;\n"
        "\t\t\t}\n"
        "\t\t    } else {\n"
        "\t\t\tsend = evLastSentPressed;\n"
        "\t\t\tif ( send )\n"
        "\t\t\t    p = QPoint( evLastSentX, evLastSentY );\n"
        "\t\t    }\n"
        "\n"
        "\t\t    if ( send ) {\n"
        "\t\t\tmousePos = p;\n"
        "\t\t\temit mouseChanged(mousePos, evPressed ? Qt::LeftButton : 0);\n"
        "\t\t\tevLastSentPressed = evPressed;\n"
        "\t\t\tevLastSentX = p.x();\n"
        "\t\t\tevLastSentY = p.y();\n"
        "\t\t\tevLastMoveMsec = eventMsec;\n"
        "\t\t    }\n"
        "\t\t    evDirty = FALSE;\n"
        "\t\t}\n"
        "\t    }\n"
        "\t}\n"
        "\treturn;\n"
        "    }\n"
    )
    if old in text and "BE300_TOUCH_MOVE_MIN_DELTA" in text:
        text = text.replace(old, new, 1)
    old = (
        "    QSocketNotifier *mouseNotifier;\n"
        "    mouseNotifier = new QSocketNotifier( mouseFD, QSocketNotifier::Read,\n"
        "\t\t\t\t\t this );\n"
        "    connect(mouseNotifier, SIGNAL(activated(int)),this, SLOT(readMouseData()));\n"
        "\n"
        "    rtimer = new QTimer( this );\n"
        "    connect( rtimer, SIGNAL(timeout()), this, SLOT(sendRelease()));\n"
        "    mouseIdx = 0;\n"
        "    setFilterSize( 3 );\n"
    )
    new = (
        "    /* BE300_RAW_TPANEL_NO_QOBJECT_CONNECT\n"
        "       Keep the raw 2.4 touch panel open/configured, but do not install\n"
        "       Qt signal connections here.  On the BE-300 16 MiB OPIE image this\n"
        "       old Qt/MIPS path faults inside QObject::connect() before the server\n"
        "       reaches the launcher.  Touch input can be restored after boot is\n"
        "       stable. */\n"
    )
    if old in text and "BE300_RAW_TPANEL_NO_QOBJECT_CONNECT" not in text:
        text = text.replace(old, new, 1)
    write_text(path, text)


def patch_time64_redirects():
    replacements = {
        "src/kernel/qapplication_qws.cpp": (
            "#undef gettimeofday\n"
            "extern \"C\" int gettimeofday( struct timeval *, struct timezone * );\n"
            "#undef select\n"
            "extern \"C\" int select( int, void *, void *, void *, struct timeval * );",
            "#undef gettimeofday\n"
            "#undef select\n"
            "#if defined(_REDIR_TIME64) && _REDIR_TIME64\n"
            "extern \"C\" int __gettimeofday_time64( struct timeval *, void * );\n"
            "extern \"C\" int __select_time64( int, fd_set *, fd_set *, fd_set *, struct timeval * );\n"
            "#define gettimeofday __gettimeofday_time64\n"
            "#define select __select_time64\n"
            "#else\n"
            "extern \"C\" int gettimeofday( struct timeval *, void * );\n"
            "extern \"C\" int select( int, fd_set *, fd_set *, fd_set *, struct timeval * );\n"
            "#endif",
        ),
        "src/tools/qdatetime.cpp": (
            "#undef\tgettimeofday\n"
            "extern \"C\" int gettimeofday( struct timeval *, struct timezone * );",
            "#undef\tgettimeofday\n"
            "#if defined(_REDIR_TIME64) && _REDIR_TIME64\n"
            "extern \"C\" int __gettimeofday_time64( struct timeval *, void * );\n"
            "#define gettimeofday __gettimeofday_time64\n"
            "#else\n"
            "extern \"C\" int gettimeofday( struct timeval *, void * );\n"
            "#endif",
        ),
        "src/kernel/qthread_p.h": (
            "#undef\tgettimeofday\n"
            "extern \"C\" int gettimeofday( struct timeval *, struct timezone * );",
            "#undef\tgettimeofday\n"
            "#if defined(_REDIR_TIME64) && _REDIR_TIME64\n"
            "extern \"C\" int __gettimeofday_time64( struct timeval *, void * );\n"
            "#define gettimeofday __gettimeofday_time64\n"
            "#else\n"
            "extern \"C\" int gettimeofday( struct timeval *, void * );\n"
            "#endif",
        ),
    }

    for rel, (old, new) in replacements.items():
        path = ROOT / rel
        if not path.exists():
            continue
        text = read_text(path)
        if new in text:
            continue
        if old not in text:
            continue
        write_text(path, text.replace(old, new, 1))


def patch_be300_locale_paths():
    path = ROOT / "src/kernel/qapplication_qws.cpp"
    if path.exists():
        text = read_text(path)
        old = (
            "    setlocale( LC_ALL, \"\" );\t\t// use correct char set mapping\n"
            "    setlocale( LC_NUMERIC, \"C\" );\t// make sprintf()/scanf() work\n"
        )
        new = (
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "    setlocale( LC_ALL, \"C\" );\t\t// avoid locale env scanning on 2.4\n"
            "#else\n"
            "    setlocale( LC_ALL, \"\" );\t\t// use correct char set mapping\n"
            "#endif\n"
            "    setlocale( LC_NUMERIC, \"C\" );\t// make sprintf()/scanf() work\n"
        )
        if old in text and "avoid locale env scanning on 2.4" not in text:
            text = text.replace(old, new, 1)
            write_text(path, text)

    path = ROOT / "src/tools/qstring.cpp"
    if not path.exists():
        return

    text = read_text(path)
    old = (
        "#ifdef _WS_QWS_\n"
        "    QTextCodec* codec = QTextCodec::codecForLocale();\n"
        "    return codec\n"
        "\t    ? codec->fromUnicode(*this)\n"
        "\t    : utf8();\n"
        "    //return latin1(); // ##### if there is ANY 8 bit format supported?\n"
        "#endif\n"
    )
    new = (
        "#ifdef _WS_QWS_\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    return latin1();\n"
        "#else\n"
        "    QTextCodec* codec = QTextCodec::codecForLocale();\n"
        "    return codec\n"
        "\t    ? codec->fromUnicode(*this)\n"
        "\t    : utf8();\n"
        "    //return latin1(); // ##### if there is ANY 8 bit format supported?\n"
        "#endif\n"
        "#endif\n"
    )
    if old in text and "return latin1();\n#else\n    QTextCodec* codec = QTextCodec::codecForLocale();" not in text:
        text = text.replace(old, new, 1)

    old = (
        "#ifdef _WS_QWS_\n"
        "    QTextCodec* codec = QTextCodec::codecForLocale();\n"
        "    if( len < 0) len = qstrlen(local8Bit);\n"
        "    return codec\n"
        "\t    ? codec->toUnicode(local8Bit, len)\n"
        "\t    : QString::fromUtf8(local8Bit,len);\n"
        "//    return fromLatin1(local8Bit,len);\n"
        "#endif\n"
    )
    new = (
        "#ifdef _WS_QWS_\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    return fromLatin1(local8Bit, len);\n"
        "#else\n"
        "    QTextCodec* codec = QTextCodec::codecForLocale();\n"
        "    if( len < 0) len = qstrlen(local8Bit);\n"
        "    return codec\n"
        "\t    ? codec->toUnicode(local8Bit, len)\n"
        "\t    : QString::fromUtf8(local8Bit,len);\n"
        "//    return fromLatin1(local8Bit,len);\n"
        "#endif\n"
        "#endif\n"
    )
    if old in text and "return fromLatin1(local8Bit, len);" not in text:
        text = text.replace(old, new, 1)

    write_text(path, text)


def patch_be300_message_output():
    path = ROOT / "src/tools/qglobal.cpp"
    if not path.exists():
        return

    text = read_text(path)
    if "#include <unistd.h>" not in text:
        text = text.replace("#include <limits.h>\n", "#include <limits.h>\n#include <unistd.h>\n", 1)

    old = (
        "static void qtMessageOutput(QtMsgType msgType, const char *msg, va_list ap)\n"
        "{\n"
        "    if ( handler ) {\n"
        "        char buf[1024];\n"
        "#if (defined __GLIBC__ || (defined __STDC_VERSION__ && __STDC_VERSION__ >= 199901L))\n"
        " \tvsnprintf(buf, 1024, msg, ap);\n"
        "#else\n"
        " \tvsprintf(buf, msg, ap); // vsnprintf would be safer here if all platforms supported it\n"
        "#endif\n"
        "\t(*handler)(msgType, buf);\n"
        "    } else {\n"
        "#ifdef _OS_MAC_\n"
        "\tFILE *mac_debug = fopen(\"debug.txt\", \"a+\");\n"
        "        if (mac_debug) {\n"
        " \t    vfprintf(mac_debug, msg, ap);\n"
        " \t    fprintf(mac_debug, \"\\n\"); // add newline\n"
        " \t    fflush(mac_debug);\n"
        " \t    fclose(mac_debug);\n"
        " \t}\n"
        "#else\n"
        "        vfprintf(stderr, msg, ap);\n"
        "        fprintf(stderr, \"\\n\"); // add newline\n"
        "#endif\n"
        "\tif (msgType == QtFatalMsg) {\n"
        "#if defined(_OS_UNIX_) && defined(DEBUG)\n"
        "\t    abort(); // trap; generates core dump\n"
        "#else\n"
        "\t    exit(1); // goodbye cruel world\n"
        "#endif\n"
        " \t}\n"
        "    }\n"
        "}\n"
    )
    new = (
        "static void qtMessageOutput(QtMsgType msgType, const char *msg, va_list ap)\n"
        "{\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    /* BE300_QT_MESSAGE_NO_VFPRINTF\n"
        "       The 16 MiB Linux 2.4 image has repeatedly crashed in uClibc\n"
        "       vfprintf while formatting Qt startup diagnostics.  Do not let\n"
        "       warning text block the server from reaching the launcher. */\n"
        "    const char *line = msgType == QtFatalMsg ? \"Qt fatal\\n\" :\n"
        "                       msgType == QtWarningMsg ? \"Qt warning\\n\" :\n"
        "                       \"Qt debug\\n\";\n"
        "    unsigned int len = msgType == QtFatalMsg ? 9 :\n"
        "                       msgType == QtWarningMsg ? 11 : 9;\n"
        "    (void)msg;\n"
        "    (void)ap;\n"
        "    write( 2, line, len );\n"
        "    if ( msgType == QtFatalMsg )\n"
        "\texit(1);\n"
        "    return;\n"
        "#endif\n"
        "    if ( handler ) {\n"
        "        char buf[1024];\n"
        "#if (defined __GLIBC__ || (defined __STDC_VERSION__ && __STDC_VERSION__ >= 199901L))\n"
        " \tvsnprintf(buf, 1024, msg, ap);\n"
        "#else\n"
        " \tvsprintf(buf, msg, ap); // vsnprintf would be safer here if all platforms supported it\n"
        "#endif\n"
        "\t(*handler)(msgType, buf);\n"
        "    } else {\n"
        "#ifdef _OS_MAC_\n"
        "\tFILE *mac_debug = fopen(\"debug.txt\", \"a+\");\n"
        "        if (mac_debug) {\n"
        " \t    vfprintf(mac_debug, msg, ap);\n"
        " \t    fprintf(mac_debug, \"\\n\"); // add newline\n"
        " \t    fflush(mac_debug);\n"
        " \t    fclose(mac_debug);\n"
        " \t}\n"
        "#else\n"
        "        vfprintf(stderr, msg, ap);\n"
        "        fprintf(stderr, \"\\n\"); // add newline\n"
        "#endif\n"
        "\tif (msgType == QtFatalMsg) {\n"
        "#if defined(_OS_UNIX_) && defined(DEBUG)\n"
        "\t    abort(); // trap; generates core dump\n"
        "#else\n"
        "\t    exit(1); // goodbye cruel world\n"
        "#endif\n"
        " \t}\n"
        "    }\n"
        "}\n"
    )
    if old in text and "BE300_QT_MESSAGE_NO_VFPRINTF" not in text:
        text = text.replace(old, new, 1)
        write_text(path, text)


def patch_be300_qfile_destructor():
    path = ROOT / "src/tools/qfile.cpp"
    if not path.exists():
        return

    text = read_text(path)
    old = (
        "QFile::~QFile()\n"
        "{\n"
        "    close();\n"
        "}\n"
    )
    new = (
        "QFile::~QFile()\n"
        "{\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    /* BE300_QFILE_DTOR_NO_CLOSE\n"
        "       QFile::close() returns with the generated destructor's saved\n"
        "       this pointer clobbered on the 16 MiB Linux 2.4 OPIE image.\n"
        "       Explicit close() calls still work; the destructor must only\n"
        "       tear down Qt members. */\n"
        "    return;\n"
        "#else\n"
        "    close();\n"
        "#endif\n"
        "}\n"
    )
    old_open_only = (
        "QFile::~QFile()\n"
        "{\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    /* BE300_QFILE_DTOR_OPEN_ONLY\n"
        "       Closed temporary QFile objects were re-entering close(), then\n"
        "       faulting in generated member destructors on the 16 MiB Linux\n"
        "       2.4 OPIE image.  Only close live file handles here. */\n"
        "    if ( isOpen() )\n"
        "\tclose();\n"
        "#else\n"
        "    close();\n"
        "#endif\n"
        "}\n"
    )
    if old_open_only in text:
        text = text.replace(old_open_only, new, 1)
        write_text(path, text)
    elif old in text and "BE300_QFILE_DTOR_NO_CLOSE" not in text:
        text = text.replace(old, new, 1)
        write_text(path, text)


def patch_be300_qstring_destructor_null_guard():
    path = ROOT / "src/tools/qstring.h"
    if not path.exists():
        return

    text = read_text(path)
    old = (
        "inline QString::~QString()\n"
        "{\n"
        "    if ( d->deref() ) {\n"
        "\tif ( d == shared_null )\n"
        "\t    shared_null = 0;\n"
        "\td->deleteSelf();\n"
        "    }\n"
        "}\n"
    )
    new = (
        "inline QString::~QString()\n"
        "{\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    /* BE300_QSTRING_DTOR_NULL_GUARD\n"
        "       The 16 MiB Linux 2.4 OPIE image can reach QFile member\n"
        "       teardown with an already-null QString data pointer. */\n"
        "    if ( !d )\n"
        "\treturn;\n"
        "#endif\n"
        "    if ( d->deref() ) {\n"
        "\tif ( d == shared_null )\n"
        "\t    shared_null = 0;\n"
        "\td->deleteSelf();\n"
        "    }\n"
        "}\n"
    )
    if old in text and "BE300_QSTRING_DTOR_NULL_GUARD" not in text:
        text = text.replace(old, new, 1)
        write_text(path, text)


def patch_widget_regions():
    path = ROOT / "src/kernel/qwidget_qws.cpp"
    if not path.exists():
        return

    text = read_text(path)
    old = (
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    if ( isVisible() && topLevelWidget()->isVisible() ) {\n"
        "        QRect be300r( offset.x(), offset.y(), width(), height() );\n"
        "        be300r = qt_screen->mapToDevice( be300r, QSize( qt_screen->width(), qt_screen->height() ) );\n"
        "        r = QRegion( be300r );\n"
        "    }\n"
        "#endif\n"
        "    qgfx_qws->setWidgetDeviceRegion(r);\n"
    )
    new = "    qgfx_qws->setWidgetDeviceRegion(r);\n"
    if old in text:
        text = text.replace(old, new, 1)
        write_text(path, text)


def patch_be300_disable_qws_screensaver():
    path = ROOT / "src/kernel/qwindowsystem_qws.cpp"
    if not path.exists():
        return

    text = read_text(path)

    old = (
        "void QWSServer::setScreenSaverIntervals(int* ms, int eventBlockLevel)\n"
        "{\n"
        "    if ( !qwsServer )\n"
        "\treturn;\n"
    )
    new = (
        "void QWSServer::setScreenSaverIntervals(int* ms, int eventBlockLevel)\n"
        "{\n"
        "    if ( !qwsServer )\n"
        "\treturn;\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    /* BE300_DISABLE_QWS_SCREENSAVER\n"
        "       The 2.4/uClibc build uses a synthetic Qt timer source to avoid\n"
        "       the unsafe gettimeofday wrapper.  That makes inactivity timers\n"
        "       advance faster than wall time, so keep QWS from blanking the\n"
        "       framebuffer while Opie is booting. */\n"
        "    delete [] qwsServer->d->screensaverintervals;\n"
        "    qwsServer->d->screensaverintervals = 0;\n"
        "    qwsServer->d->screensavereventblocklevel = -1;\n"
        "    qwsServer->screensaverinterval = 0;\n"
        "    qwsServer->d->screensavertimer->stop();\n"
        "    qt_screen->blank(FALSE);\n"
        "    extern bool qt_disable_lowpriority_timers;\n"
        "    qt_disable_lowpriority_timers = FALSE;\n"
        "    return;\n"
        "#endif\n"
    )
    if old in text and "BE300_DISABLE_QWS_SCREENSAVER" not in text:
        text = text.replace(old, new, 1)
    text = text.replace(
        "    qt_screen->blank(FALSE);\n"
        "    qt_disable_lowpriority_timers = FALSE;\n"
        "    return;\n"
        "#endif\n"
        "    delete [] qwsServer->d->screensaverintervals;\n",
        "    qt_screen->blank(FALSE);\n"
        "    extern bool qt_disable_lowpriority_timers;\n"
        "    qt_disable_lowpriority_timers = FALSE;\n"
        "    return;\n"
        "#endif\n"
        "    delete [] qwsServer->d->screensaverintervals;\n",
        1,
    )

    old = "void QWSServer::screenSaverWake()\n{\n"
    new = (
        "void QWSServer::screenSaverWake()\n"
        "{\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    if ( d->screensavertimer )\n"
        "\td->screensavertimer->stop();\n"
        "    qt_screen->blank(FALSE);\n"
        "    screensaverinterval = 0;\n"
        "    d->screensaverblockevents = FALSE;\n"
        "    qt_disable_lowpriority_timers = FALSE;\n"
        "    return;\n"
        "#endif\n"
    )
    if old in text and "d->screensavertimer->stop();" not in text[text.find(old):text.find(old) + 260]:
        text = text.replace(old, new, 1)

    old = "void QWSServer::screenSaverSleep()\n{\n"
    new = (
        "void QWSServer::screenSaverSleep()\n"
        "{\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    qt_screen->blank(FALSE);\n"
        "    if ( d->screensavertimer )\n"
        "\td->screensavertimer->stop();\n"
        "    screensaverinterval = 0;\n"
        "    d->screensaverblockevents = FALSE;\n"
        "    qt_disable_lowpriority_timers = FALSE;\n"
        "    return;\n"
        "#endif\n"
    )
    if old in text and "void QWSServer::screenSaverSleep()\n{\n#ifdef QT_QWS_CASSIOPEIA" not in text:
        text = text.replace(old, new, 1)

    old = "void QWSServer::screenSave(int level)\n{\n"
    new = (
        "void QWSServer::screenSave(int level)\n"
        "{\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    if ( qwsServer )\n"
        "\tqwsServer->screenSaverWake();\n"
        "    return;\n"
        "#endif\n"
    )
    if old in text and "void QWSServer::screenSave(int level)\n{\n#ifdef QT_QWS_CASSIOPEIA" not in text:
        text = text.replace(old, new, 1)

    old = "void QWSServer::screenSaverTimeout()\n{\n"
    new = (
        "void QWSServer::screenSaverTimeout()\n"
        "{\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    if ( qwsServer )\n"
        "\tqwsServer->screenSaverWake();\n"
        "    return;\n"
        "#endif\n"
    )
    if old in text and "void QWSServer::screenSaverTimeout()\n{\n#ifdef QT_QWS_CASSIOPEIA" not in text:
        text = text.replace(old, new, 1)

    old = "bool QWSServer::screenSaverActive()\n{\n"
    new = (
        "bool QWSServer::screenSaverActive()\n"
        "{\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    return FALSE;\n"
        "#endif\n"
    )
    if old in text and "bool QWSServer::screenSaverActive()\n{\n#ifdef QT_QWS_CASSIOPEIA" not in text:
        text = text.replace(old, new, 1)

    old = "void QWSServer::screenSaverActivate(bool activate)\n{\n"
    new = (
        "void QWSServer::screenSaverActivate(bool activate)\n"
        "{\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    screenSaverWake();\n"
        "    return;\n"
        "#endif\n"
    )
    if old in text and "void QWSServer::screenSaverActivate(bool activate)\n{\n#ifdef QT_QWS_CASSIOPEIA" not in text:
        text = text.replace(old, new, 1)

    old = "void QWSServer::restartScreenSaverTimer()\n{\n"
    new = (
        "void QWSServer::restartScreenSaverTimer()\n"
        "{\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    screenSaverWake();\n"
        "    return;\n"
        "#endif\n"
    )
    if old in text and "void QWSServer::restartScreenSaverTimer()\n{\n#ifdef QT_QWS_CASSIOPEIA" not in text:
        text = text.replace(old, new, 1)

    text = text.replace(
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    screenSaverWake();\n"
        "    return;\n"
        "#endif\n"
        "    if ( activate )\n",
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    if ( qwsServer )\n"
        "\tqwsServer->screenSaverWake();\n"
        "    return;\n"
        "#endif\n"
        "    if ( activate )\n",
        1,
    )
    text = text.replace(
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    screenSaverWake();\n"
        "    return;\n"
        "#endif\n"
        "    if ( qwsServer->screensaverinterval",
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    if ( qwsServer )\n"
        "\tqwsServer->screenSaverWake();\n"
        "    return;\n"
        "#endif\n"
        "    if ( qwsServer->screensaverinterval",
        1,
    )

    write_text(path, text)


def patch_metaobject_pools():
    path = ROOT / "src/kernel/qmetaobject.cpp"
    if not path.exists():
        return

    text = read_text(path)
    old = (
        "QMetaData *QMetaObject::new_metadata( int numEntries )\n"
        "{\n"
        "    return numEntries > 0 ? new QMetaData[numEntries] : 0;\n"
        "}\n"
    )
    new = (
        "QMetaData *QMetaObject::new_metadata( int numEntries )\n"
        "{\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    enum { be300_metadata_pool_entries = 2048 };\n"
        "    static QMetaData be300_metadata_pool[be300_metadata_pool_entries];\n"
        "    static int be300_metadata_used = 0;\n"
        "\n"
        "    if ( numEntries <= 0 )\n"
        "\treturn 0;\n"
        "    if ( be300_metadata_used + numEntries <= be300_metadata_pool_entries ) {\n"
        "\tQMetaData *data = be300_metadata_pool + be300_metadata_used;\n"
        "\tbe300_metadata_used += numEntries;\n"
        "\treturn data;\n"
        "    }\n"
        "#endif\n"
        "    return numEntries > 0 ? new QMetaData[numEntries] : 0;\n"
        "}\n"
    )
    if old in text and "be300_metadata_pool_entries" not in text:
        text = text.replace(old, new, 1)

    old = (
        "QMetaData::Access *QMetaObject::new_metaaccess( int numEntries )\n"
        "{\n"
        "    return numEntries > 0 ? new QMetaData::Access[numEntries] : 0;\n"
        "}\n"
    )
    new = (
        "QMetaData::Access *QMetaObject::new_metaaccess( int numEntries )\n"
        "{\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    enum { be300_metaaccess_pool_entries = 1024 };\n"
        "    static QMetaData::Access be300_metaaccess_pool[be300_metaaccess_pool_entries];\n"
        "    static int be300_metaaccess_used = 0;\n"
        "\n"
        "    if ( numEntries <= 0 )\n"
        "\treturn 0;\n"
        "    if ( be300_metaaccess_used + numEntries <= be300_metaaccess_pool_entries ) {\n"
        "\tQMetaData::Access *access = be300_metaaccess_pool + be300_metaaccess_used;\n"
        "\tbe300_metaaccess_used += numEntries;\n"
        "\treturn access;\n"
        "    }\n"
        "#endif\n"
        "    return numEntries > 0 ? new QMetaData::Access[numEntries] : 0;\n"
        "}\n"
    )
    if old in text and "be300_metaaccess_pool_entries" not in text:
        text = text.replace(old, new, 1)

    write_text(path, text)


def replace_linuxfb_accel_block(text):
    start_marker = (
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "#ifndef BE300_VRC4173_QWS_ACCEL\n"
        "#define BE300_VRC4173_QWS_ACCEL\n"
    )
    start = text.find(start_marker)
    if start >= 0:
        end_marker = "\n#endif\n#endif\n"
        end = text.find(end_marker, start)
        if end < 0:
            raise RuntimeError("unterminated BE-300 LinuxFb accel block")
        end += len(end_marker)
        return text[:start] + BE300_QWS_ACCEL + text[end:]

    anchor = "static volatile int * optype=0;\nstatic volatile int * lastop=0;\n"
    if anchor in text:
        return text.replace(anchor, anchor + "\n" + BE300_QWS_ACCEL + "\n", 1)
    return text


def patch_linuxfb_accel():
    path = ROOT / "src/kernel/qgfxraster_qws.cpp"
    if not path.exists():
        return

    text = read_text(path)

    if "#include <stdlib.h>" not in text:
        text = text.replace("#include <errno.h>\n", "#include <errno.h>\n#include <stdlib.h>\n", 1)

    text = replace_linuxfb_accel_block(text)

    if "BE300_ACCEL_FILL_HOOK" not in text:
        anchor = "    GFX_START(QRect(rx+xoffs, ry+yoffs, w+1, h+1))\n"
        if anchor in text:
            text = text.replace(anchor, anchor + BE300_FILL_HOOK, 1)

    if "BE300_ACCEL_SCROLL_HOOK" not in text:
        anchor = (
            "    GFX_START(QRect(QMIN(rx+xoffs,sx+xoffs), QMIN(ry+yoffs,sy+yoffs), "
            "w+QABS(dx)+1, h+QABS(dy)+1))\n\n"
        )
        if anchor in text:
            text = text.replace(anchor, anchor + BE300_SCROLL_HOOK + "\n", 1)

    write_text(path, text)


def patch_be300_stretchblt_integer_scale():
    path = ROOT / "src/kernel/qgfxraster_qws.cpp"
    if not path.exists():
        return

    text = read_text(path)

    if "BE300_STRETCHBLT_INTEGER_SCALE" not in text:
        old = (
            "void QGfxRaster<depth,type>::stretchBlt( int rx,int ry,int w,int h,\n"
            "\t\t\t\t\t int sw,int sh )\n"
            "{\n"
            "    if((*optype))\n"
        )
        new = (
            "void QGfxRaster<depth,type>::stretchBlt( int rx,int ry,int w,int h,\n"
            "\t\t\t\t\t int sw,int sh )\n"
            "{\n"
            "#ifdef QT_QWS_CASSIOPEIA\n"
            "    /* BE300_STRETCHBLT_INTEGER_SCALE\n"
            "       Keep 2.4/16 MiB OPIE startup out of libgcc soft-float\n"
            "       helpers while scaling launcher bitmaps. */\n"
            "    if ( w <= 0 || h <= 0 || sw <= 0 || sh <= 0 )\n"
            "\treturn;\n"
            "    if ( depth != 8 && depth != 16 && depth != 24 && depth != 32 )\n"
            "\treturn;\n"
            "#endif\n"
            "    if((*optype))\n"
        )
        if old in text:
            text = text.replace(old, new, 1)

    old = (
        "    double xfac=sw;\n"
        "    xfac=xfac/((double)w);\n"
        "    double yfac=sh;\n"
        "    yfac=yfac/((double)h);\n"
    )
    new = (
        "#ifndef QT_QWS_CASSIOPEIA\n"
        "    double xfac=sw;\n"
        "    xfac=xfac/((double)w);\n"
        "    double yfac=sh;\n"
        "    yfac=yfac/((double)h);\n"
        "#endif\n"
    )
    if old in text and new not in text:
        text = text.replace(old, new, 1)

    old = "\tint yp=(int) ( ( (double) j )*yfac );\n"
    new = (
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "\tint yp = ( j * sh ) / h;\n"
        "#else\n"
        "\tint yp=(int) ( ( (double) j )*yfac );\n"
        "#endif\n"
    )
    if old in text and new not in text:
        text = text.replace(old, new, 1)

    old = "\t\tint sp=(int) ( ( (double) loopc )*xfac );\n"
    new = (
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "\t\tint sp = ( loopc * sw ) / w;\n"
        "#else\n"
        "\t\tint sp=(int) ( ( (double) loopc )*xfac );\n"
        "#endif\n"
    )
    if old in text and new not in text:
        text = text.replace(old, new, 1)

    write_text(path, text)


def patch_be300_wait_timer_null_guard():
    path = ROOT / "src/kernel/qapplication_qws.cpp"
    if not path.exists():
        return

    text = read_text(path)
    old = (
        "static inline void getTime( timeval &t )\t// get time of day\n"
        "{\n"
        "    gettimeofday( &t, 0 );\n"
        "    while ( t.tv_usec >= 1000000 ) {\t\t// NTP-related fix\n"
        "\tt.tv_usec -= 1000000;\n"
        "\tt.tv_sec++;\n"
        "    }\n"
        "    while ( t.tv_usec < 0 ) {\n"
        "\tif ( t.tv_sec > 0 ) {\n"
        "\t    t.tv_usec += 1000000;\n"
        "\t    t.tv_sec--;\n"
        "\t} else {\n"
        "\t    t.tv_usec = 0;\n"
        "\t    break;\n"
        "\t}\n"
        "    }\n"
        "}\n"
    )
    new = (
        "static inline void getTime( timeval &t )\t// get time of day\n"
        "{\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "    /* BE300_TIMER_FAKE_GETTIME\n"
        "       The uClibc gettimeofday wrapper used by the 2.4/16 MiB OPIE\n"
        "       image clobbers saved registers on this Qt startup path.  Timers\n"
        "       only need a monotonic source to drive the event loop here. */\n"
        "    static unsigned int be300_timer_msec = 0;\n"
        "    be300_timer_msec += 20;\n"
        "    t.tv_sec = be300_timer_msec / 1000;\n"
        "    t.tv_usec = ( be300_timer_msec % 1000 ) * 1000;\n"
        "#else\n"
        "    gettimeofday( &t, 0 );\n"
        "    while ( t.tv_usec >= 1000000 ) {\t\t// NTP-related fix\n"
        "\tt.tv_usec -= 1000000;\n"
        "\tt.tv_sec++;\n"
        "    }\n"
        "    while ( t.tv_usec < 0 ) {\n"
        "\tif ( t.tv_sec > 0 ) {\n"
        "\t    t.tv_usec += 1000000;\n"
        "\t    t.tv_sec--;\n"
        "\t} else {\n"
        "\t    t.tv_usec = 0;\n"
        "\t    break;\n"
        "\t}\n"
        "    }\n"
        "#endif\n"
        "}\n"
    )
    if old in text and "BE300_TIMER_FAKE_GETTIME" not in text:
        text = text.replace(old, new, 1)

    old = (
        "\tif ( first ) {\n"
        "\t    if ( currentTime < watchtime )\t// clock was turned back\n"
        "\t\trepairTimer( currentTime );\n"
        "\t    first = FALSE;\n"
        "\t    watchtime = currentTime;\n"
        "\t}\n"
    )
    new = (
        "\tif ( first ) {\n"
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "\t    /* BE300_WAIT_TIMER_POINTER_SAFE\n"
        "\t       Avoid the out-of-line timeval comparison helper during early\n"
        "\t       OPIE startup; the 2.4/16 MiB image has trapped there with a\n"
        "\t       null first argument while entering the event loop. */\n"
        "\t    watchtime = currentTime;\n"
        "#else\n"
        "\t    if ( currentTime < watchtime )\t// clock was turned back\n"
        "\t\trepairTimer( currentTime );\n"
        "\t    watchtime = currentTime;\n"
        "#endif\n"
        "\t    first = FALSE;\n"
        "\t}\n"
    )
    if old in text and "BE300_WAIT_TIMER_POINTER_SAFE" not in text:
        text = text.replace(old, new, 1)

    old = (
        "\tTimerInfo *t = timerList->first();\t// first waiting timer\n"
        "\tif ( currentTime < t->timeout ) {\t// time to wait\n"
    )
    new = (
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "\tTimerInfo *t = timerList ? timerList->first() : 0;\t// first waiting timer\n"
        "\t/* BE300_WAIT_TIMER_NULL_GUARD\n"
        "\t   The 2.4/16 MiB OPIE image can observe timerList becoming null\n"
        "\t   between the count() probe and this first() call during startup. */\n"
        "\tif ( !t ) {\n"
        "\t    if ( qt_wait_timer_max ) {\n"
        "\t\ttm = *qt_wait_timer_max;\n"
        "\t\treturn &tm;\n"
        "\t    }\n"
        "\t    return 0;\n"
        "\t}\n"
        "#else\n"
        "\tTimerInfo *t = timerList->first();\t// first waiting timer\n"
        "#endif\n"
        "\tif ( currentTime < t->timeout ) {\t// time to wait\n"
    )
    if old in text and "BE300_WAIT_TIMER_NULL_GUARD" not in text:
        text = text.replace(old, new, 1)

    old = "\tif ( currentTime < t->timeout ) {\t// time to wait\n"
    new = (
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "\tbool be300_timer_wait =\n"
        "\t    currentTime.tv_sec < t->timeout.tv_sec ||\n"
        "\t    ( currentTime.tv_sec == t->timeout.tv_sec &&\n"
        "\t      currentTime.tv_usec < t->timeout.tv_usec );\n"
        "\tif ( be300_timer_wait ) {\t\t// time to wait\n"
        "#else\n"
        "\tif ( currentTime < t->timeout ) {\t// time to wait\n"
        "#endif\n"
    )
    if old in text and "be300_timer_wait" not in text:
        text = text.replace(old, new, 1)

    old = (
        "\tif ( qt_wait_timer_max && *qt_wait_timer_max < tm )\n"
        "\t    tm = *qt_wait_timer_max;\n"
    )
    new = (
        "#ifdef QT_QWS_CASSIOPEIA\n"
        "\tif ( qt_wait_timer_max &&\n"
        "\t     ( qt_wait_timer_max->tv_sec < tm.tv_sec ||\n"
        "\t       ( qt_wait_timer_max->tv_sec == tm.tv_sec &&\n"
        "\t\t qt_wait_timer_max->tv_usec < tm.tv_usec ) ) )\n"
        "\t    tm = *qt_wait_timer_max;\n"
        "#else\n"
        "\tif ( qt_wait_timer_max && *qt_wait_timer_max < tm )\n"
        "\t    tm = *qt_wait_timer_max;\n"
        "#endif\n"
    )
    if old in text and "qt_wait_timer_max->tv_sec" not in text:
        text = text.replace(old, new, 1)

    write_text(path, text)


def main():
    patch_file("src/kernel/qapplication_qws.cpp")
    patch_file("src/kernel/qwindowsystem_qws.cpp")
    patch_time64_redirects()
    patch_be300_locale_paths()
    patch_be300_message_output()
    patch_be300_qfile_destructor()
    patch_be300_qstring_destructor_null_guard()
    patch_metaobject_pools()
    patch_mouse()
    patch_widget_regions()
    patch_be300_disable_qws_screensaver()
    patch_linuxfb_accel()
    patch_be300_stretchblt_integer_scale()
    patch_be300_wait_timer_null_guard()


if __name__ == "__main__":
    main()
