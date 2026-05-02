#!/usr/bin/env python3
"""Final BE-300 Qt/Embedded source fixes applied before building."""

from pathlib import Path
import sys


ROOT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("/work/qt-2.3.10-be300")


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


def main():
    patch_file("src/kernel/qapplication_qws.cpp")
    patch_file("src/kernel/qwindowsystem_qws.cpp")
    patch_time64_redirects()
    patch_mouse()


if __name__ == "__main__":
    main()
