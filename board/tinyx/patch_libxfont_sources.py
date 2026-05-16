#!/usr/bin/env python3
"""BE-300 libXfont source patches.

libXfont 1.5.x is designed to be linked against several X server vintages.  It
ships weak stubs for server-side callbacks, including RegisterFPEFunctions().
On the BE-300 uClibc/MIPS dynamic link path, calls from libXfont's built-in and
fontfile FPE registration code bind to the local weak no-op instead of the
Xfbdev implementation exported from the main executable.  That leaves no font
path element types registered, so both /usr/share/X11/fonts/misc and built-ins
are rejected during server startup.

Patch the stub to prefer a BE-300 bridge symbol exported by Xfbdev.  The bridge
is weakly referenced so the library still links as a shared object without
adding a new hard dependency.
"""

from __future__ import annotations

import sys
from pathlib import Path


def fail(msg: str) -> None:
    sys.stderr.write(f"patch_libxfont_sources: {msg}\n")
    sys.exit(1)


def rewrite_in_place(path: Path, transform) -> bool:
    if not path.is_file():
        return False
    original = path.read_text(errors="replace")
    updated = transform(original)
    if updated != original:
        path.write_text(updated)
        return True
    return False


def patch_register_fpe_bridge(tree: Path) -> int:
    f = tree / "src" / "stubs" / "regfpefunc.c"
    if not f.is_file():
        return 0

    def transform(text: str) -> str:
        decl = """\
#include "stubs.h"

#ifdef __GNUC__
#pragma weak __be300_xserver_RegisterFPEFunctions
#endif
extern int __be300_xserver_RegisterFPEFunctions();
"""
        old_decl = """\
#include "stubs.h"

extern int __be300_xserver_RegisterFPEFunctions(NameCheckFunc name_func,
\t\t     InitFpeFunc init_func,
\t\t     FreeFpeFunc free_func,
\t\t     ResetFpeFunc reset_func,
\t\t     OpenFontFunc open_func,
\t\t     CloseFontFunc close_func,
\t\t     ListFontsFunc list_func,
\t\t     StartLfwiFunc start_lfwi_func,
\t\t     NextLfwiFunc next_lfwi_func,
\t\t     WakeupFpeFunc wakeup_func,
\t\t     ClientDiedFunc client_died,
\t\t     LoadGlyphsFunc load_glyphs,
\t\t     StartLaFunc start_list_alias_func,
\t\t     NextLaFunc next_list_alias_func,
\t\t     SetPathFunc set_path_func) __attribute__((weak));
"""
        if old_decl in text:
            text = text.replace(old_decl, decl, 1)
        elif "__be300_xserver_RegisterFPEFunctions" not in text:
            if '#include "stubs.h"\n' not in text:
                fail("regfpefunc.c include context not found")
            text = text.replace('#include "stubs.h"\n', decl, 1)

        if "be300-tinyx: prefer Xfbdev FPE registry bridge" in text:
            return text

        old = """\
{
    OVERRIDE_SYMBOL(RegisterFPEFunctions, name_func, init_func, free_func,
                    reset_func, open_func, close_func, list_func, start_lfwi_func,
                    next_lfwi_func, wakeup_func, client_died, load_glyphs,
                    start_list_alias_func, next_list_alias_func, set_path_func);
    return 0;
}
"""
        new = """\
{
    /* be300-tinyx: prefer Xfbdev FPE registry bridge. */
    if (__be300_xserver_RegisterFPEFunctions)
        return __be300_xserver_RegisterFPEFunctions(name_func, init_func,
                    free_func, reset_func, open_func, close_func, list_func,
                    start_lfwi_func, next_lfwi_func, wakeup_func, client_died,
                    load_glyphs, start_list_alias_func, next_list_alias_func,
                    set_path_func);

    OVERRIDE_SYMBOL(RegisterFPEFunctions, name_func, init_func, free_func,
                    reset_func, open_func, close_func, list_func, start_lfwi_func,
                    next_lfwi_func, wakeup_func, client_died, load_glyphs,
                    start_list_alias_func, next_list_alias_func, set_path_func);
    return 0;
}
"""
        if old not in text:
            fail("regfpefunc.c RegisterFPEFunctions body not found")
        return text.replace(old, new, 1)

    return 1 if rewrite_in_place(f, transform) else 0


def main() -> int:
    if len(sys.argv) != 2:
        fail("usage: patch_libxfont_sources.py <libXfont-tree>")
    tree = Path(sys.argv[1])
    if not tree.is_dir():
        fail(f"not a directory: {tree}")

    total = patch_register_fpe_bridge(tree)
    if total == 0:
        print(f"patch_libxfont_sources: no changes needed ({tree})")
    else:
        print(f"patch_libxfont_sources: applied {total} edit(s) under {tree}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
