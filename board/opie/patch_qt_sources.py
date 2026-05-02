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
    text = text.replace(
        "\tif ( n < 0 && errno != EAGAIN )\n"
        "\t    qWarning(\"touch read error %s\", strerror(errno));\n"
        "\treturn;\n",
        "\treturn;\n",
    )
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


def main():
    patch_file("src/kernel/qapplication_qws.cpp")
    patch_file("src/kernel/qwindowsystem_qws.cpp")
    patch_time64_redirects()
    patch_mouse()
    patch_widget_regions()
    patch_linuxfb_accel()


if __name__ == "__main__":
    main()
