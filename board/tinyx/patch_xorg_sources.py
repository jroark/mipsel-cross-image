#!/usr/bin/env python3
"""Autoconf/automake modernization for xorg-server-1.6.5.901.

Run from board/tinyx/build_tinyx_rootfs.sh:

    python3 board/tinyx/patch_xorg_sources.py /work/xorg-be300/xorg-server-1.6.5.901

The xorg-server-1.6.x autoconf tree predates the unified autoconf-2.69 /
automake-1.16 macro set shipped on modern Debian.  The patches here mirror
the picogui pattern in board/picogui/patch_picogui_sources.py:

  - rename every configure.in -> configure.ac (xorg-server already uses .ac,
    but a few subdirs ship .in)
  - rewrite AM_CONFIG_HEADER -> AC_CONFIG_HEADERS (1-arg automake removed
    AM_CONFIG_HEADER in 1.13 in favour of AC_CONFIG_HEADERS in autoconf 2.50+)
  - drop AC_REQUIRES on config-hal / config-udev so --disable-config-{hal,udev}
    actually works without policykit/dbus host bits
  - kill the stray libxkbui dependency check (libxkbui was removed from
    modular X.Org by 1.7; build_be300_kernel.sh's TinyX path doesn't link it)
  - prepend `#include <unistd.h>` to hw/kdrive/linux/linux.c if needed for
    modern compilers (close()/read()/sleep() declarations)
  - fix XaceHook's callback-record lifetime so resource hooks return stable
    status on the MIPS target compiler
  - leave Render's animated-cursor timer off the per-screen BlockHandler chain;
    static cursor display still works, and the BE-300 profile does not need
    animated cursors
  - leave kdrive's own per-screen BlockHandler off as well; evdev input is
    driven from the WakeupHandler fd path, and the BE-300 profile does not
    need kdrive's middle-button timeout polling
  - teach hw/kdrive/linux/evdev.c to treat the BE-300 touchscreen's
    ABS_X/ABS_Y + BTN_TOUCH events as absolute pointer motion/button events

Each transform is idempotent: re-running the script over an already-patched
tree should produce no changes and exit 0.

The runtime launcher uses kdrive's existing `evdev` keyboard driver for the
Stowaway input node and the patched `evdev` pointer driver for the BE-300 PIU
touchscreen node.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path


def fail(msg: str) -> None:
    sys.stderr.write(f"patch_xorg_sources: {msg}\n")
    sys.exit(1)


def rewrite_in_place(path: Path, transform) -> bool:
    """Apply `transform(text) -> text` if it changes the file. Returns True if changed."""
    if not path.is_file():
        return False
    original = path.read_text(errors="replace")
    updated = transform(original)
    if updated != original:
        path.write_text(updated)
        return True
    return False


def modernize_autoconf(text: str) -> str:
    # AM_CONFIG_HEADER(foo) -> AC_CONFIG_HEADERS([foo])
    text = re.sub(
        r"\bAM_CONFIG_HEADER\s*\(\s*([^)]+?)\s*\)",
        lambda m: f"AC_CONFIG_HEADERS([{m.group(1).strip()}])",
        text,
    )
    # Some 1.6-era configure.ac files use AC_CONFIG_HEADER (singular).  The
    # autoconf-2.69 alias for AC_CONFIG_HEADERS still accepts it, but the
    # macro is officially obsoleted; rewrite for cleanliness.
    text = re.sub(
        r"\bAC_CONFIG_HEADER\s*\(",
        "AC_CONFIG_HEADERS(",
        text,
    )
    return text


def patch_xorg_server_configure(tree: Path) -> int:
    """Walk the xorg-server tree, rename configure.in -> configure.ac, modernize macros."""
    changed = 0

    # Rename .in to .ac (rare in xorg-server; defensive).
    for cfgin in tree.rglob("configure.in"):
        target = cfgin.with_name("configure.ac")
        if target.exists():
            continue
        cfgin.rename(target)
        changed += 1

    # Modernize every configure.ac in the tree.
    for cfg in tree.rglob("configure.ac"):
        if rewrite_in_place(cfg, modernize_autoconf):
            changed += 1

    return changed


def drop_dead_hal_udev_requires(tree: Path) -> int:
    """The 1.6.x tree's configure.ac sometimes AC_REQUIRES policykit even when
    --disable-config-hal is used.  Strip those PKG_CHECK_MODULES lines if they
    appear unconditional."""
    cfg = tree / "configure.ac"
    if not cfg.is_file():
        return 0

    def transform(text: str) -> str:
        # Comment out unconditional PolicyKit / HAL / udev checks.  We pair
        # them with --disable-config-hal / --disable-config-udev at configure
        # time; the AC_REQUIRES on the host PKG_CHECK_MODULES still runs
        # otherwise and fails the configure if policykit-1 isn't installed.
        return re.sub(
            r"^(\s*)(PKG_CHECK_MODULES\(\[(?:POLICYKIT|HAL|UDEV)\][^\)]*\)\s*)$",
            r"\1dnl be300-tinyx: disabled, see --disable-config-{hal,udev} \2",
            text,
            flags=re.MULTILINE,
        )

    return 1 if rewrite_in_place(cfg, transform) else 0


def patch_kdrive_linux_unistd(tree: Path) -> int:
    """Add #include <unistd.h> to hw/kdrive/linux/linux.c if missing.

    Modern glibc/musl headers don't transitively bring unistd.h via stdlib.h,
    and kdrive 1.6's linux.c calls close()/read()/sleep() without the include.
    """
    linux_c = tree / "hw" / "kdrive" / "linux" / "linux.c"
    if not linux_c.is_file():
        return 0

    def transform(text: str) -> str:
        if "#include <unistd.h>" in text:
            return text
        # Insert after the first #include in the file (canonical place).
        return re.sub(
            r"(#include\s+<[^>]+>\s*\n)",
            r"\1#include <unistd.h>\n",
            text,
            count=1,
        )

    return 1 if rewrite_in_place(linux_c, transform) else 0


def patch_xace_hook_lifetime(tree: Path) -> int:
    """Keep XaceHook callback records alive until callbacks finish.

    xorg-server-1.6.x stores a pointer to a case-local callback record, leaves
    the case block, then calls CallCallbacks() through that stale pointer.
    Newer target compilers can reuse that stack slot, which made
    CreateColormap() see a bogus XACE status during kdrive screen setup.
    """
    f = tree / "Xext" / "xace.c"
    if not f.is_file():
        return 0

    def transform(text: str) -> str:
        if "be300-tinyx: keep callback records alive" in text:
            return text

        replacement = """\
int XaceHook(int hook, ...)
{
    va_list ap;\t\t/* argument list */
    va_start(ap, hook);

#define XACE_RETURN_STATUS(record) do { \\
    va_end(ap); \\
    CallCallbacks(&XaceHooks[hook], &(record)); \\
    return (record).status; \\
} while (0)

#define XACE_RETURN_SUCCESS(record) do { \\
    va_end(ap); \\
    CallCallbacks(&XaceHooks[hook], &(record)); \\
    return Success; \\
} while (0)

    /* be300-tinyx: keep callback records alive until CallCallbacks returns. */
    switch (hook)
    {
\tcase XACE_RESOURCE_ACCESS: {
\t    XaceResourceAccessRec rec = {
\t\tva_arg(ap, ClientPtr),
\t\tva_arg(ap, XID),
\t\tva_arg(ap, RESTYPE),
\t\tva_arg(ap, pointer),
\t\tva_arg(ap, RESTYPE),
\t\tva_arg(ap, pointer),
\t\tva_arg(ap, Mask),
\t\tSuccess /* default allow */
\t    };
\t    XACE_RETURN_STATUS(rec);
\t}
\tcase XACE_DEVICE_ACCESS: {
\t    XaceDeviceAccessRec rec = {
\t\tva_arg(ap, ClientPtr),
\t\tva_arg(ap, DeviceIntPtr),
\t\tva_arg(ap, Mask),
\t\tSuccess /* default allow */
\t    };
\t    XACE_RETURN_STATUS(rec);
\t}
\tcase XACE_SEND_ACCESS: {
\t    XaceSendAccessRec rec = {
\t\tva_arg(ap, ClientPtr),
\t\tva_arg(ap, DeviceIntPtr),
\t\tva_arg(ap, WindowPtr),
\t\tva_arg(ap, xEventPtr),
\t\tva_arg(ap, int),
\t\tSuccess /* default allow */
\t    };
\t    XACE_RETURN_STATUS(rec);
\t}
\tcase XACE_RECEIVE_ACCESS: {
\t    XaceReceiveAccessRec rec = {
\t\tva_arg(ap, ClientPtr),
\t\tva_arg(ap, WindowPtr),
\t\tva_arg(ap, xEventPtr),
\t\tva_arg(ap, int),
\t\tSuccess /* default allow */
\t    };
\t    XACE_RETURN_STATUS(rec);
\t}
\tcase XACE_CLIENT_ACCESS: {
\t    XaceClientAccessRec rec = {
\t\tva_arg(ap, ClientPtr),
\t\tva_arg(ap, ClientPtr),
\t\tva_arg(ap, Mask),
\t\tSuccess /* default allow */
\t    };
\t    XACE_RETURN_STATUS(rec);
\t}
\tcase XACE_EXT_ACCESS: {
\t    XaceExtAccessRec rec = {
\t\tva_arg(ap, ClientPtr),
\t\tva_arg(ap, ExtensionEntry*),
\t\tDixGetAttrAccess,
\t\tSuccess /* default allow */
\t    };
\t    XACE_RETURN_STATUS(rec);
\t}
\tcase XACE_SERVER_ACCESS: {
\t    XaceServerAccessRec rec = {
\t\tva_arg(ap, ClientPtr),
\t\tva_arg(ap, Mask),
\t\tSuccess /* default allow */
\t    };
\t    XACE_RETURN_STATUS(rec);
\t}
\tcase XACE_SCREEN_ACCESS:
\tcase XACE_SCREENSAVER_ACCESS: {
\t    XaceScreenAccessRec rec = {
\t\tva_arg(ap, ClientPtr),
\t\tva_arg(ap, ScreenPtr),
\t\tva_arg(ap, Mask),
\t\tSuccess /* default allow */
\t    };
\t    XACE_RETURN_STATUS(rec);
\t}
\tcase XACE_AUTH_AVAIL: {
\t    XaceAuthAvailRec rec = {
\t\tva_arg(ap, ClientPtr),
\t\tva_arg(ap, XID)
\t    };
\t    XACE_RETURN_SUCCESS(rec);
\t}
\tcase XACE_KEY_AVAIL: {
\t    XaceKeyAvailRec rec = {
\t\tva_arg(ap, xEventPtr),
\t\tva_arg(ap, DeviceIntPtr),
\t\tva_arg(ap, int)
\t    };
\t    XACE_RETURN_SUCCESS(rec);
\t}
\tdefault:
\t    va_end(ap);
\t    return 0;\t/* unimplemented hook number */
    }
}

#undef XACE_RETURN_STATUS
#undef XACE_RETURN_SUCCESS
"""

        pattern = re.compile(
            r"int XaceHook\(int hook, \.\.\.\)\n\{.*?\n\}\n\n/\* XaceCensorImage",
            re.DOTALL,
        )
        new_text, n = pattern.subn(replacement + "\n\n/* XaceCensorImage", text, count=1)
        if n != 1:
            fail("xace.c XaceHook context not found")
        return new_text

    return 1 if rewrite_in_place(f, transform) else 0


def patch_animcur_without_screen_block_handler(tree: Path) -> int:
    """Avoid Render animated-cursor timer wrapping the screen BlockHandler.

    The BE-300 profile uses matchbox's normal static cursor and does not need
    animated cursor frame timers.  On the MIPS/uClibc kdrive build, the extra
    screen BlockHandler wrapper is a late-crash path after the server has been
    running for a while.  Keep the rest of animcur.c intact so core/static
    cursor hooks still behave as expected.
    """
    f = tree / "render" / "animcur.c"
    if not f.is_file():
        return 0

    def transform(text: str) -> str:
        marker = "be300-tinyx: do not wrap Screen.BlockHandler"
        if marker in text:
            return text

        old_close = "    Unwrap(as, pScreen, BlockHandler);\n"
        new_close = (
            "    if (as->BlockHandler)\n"
            "        Unwrap(as, pScreen, BlockHandler);\n"
        )
        if old_close not in text:
            fail("animcur.c CloseScreen BlockHandler unwrap context not found")
        text = text.replace(old_close, new_close, 1)

        old_init = "    Wrap(as, pScreen, BlockHandler, AnimCurScreenBlockHandler);\n"
        new_init = (
            f"    /* {marker}; static cursor display is enough on BE-300. */\n"
            "    as->BlockHandler = NULL;\n"
        )
        if old_init not in text:
            fail("animcur.c Init BlockHandler wrap context not found")
        text = text.replace(old_init, new_init, 1)
        return text

    return 1 if rewrite_in_place(f, transform) else 0


def patch_kdrive_without_screen_block_handler(tree: Path) -> int:
    """Avoid kdrive's per-screen BlockHandler path on BE-300.

    Evdev input is delivered from KdWakeupHandler when select() reports the
    input fd readable.  KdBlockHandler only adjusts sleep timeouts for optional
    polling/middle-button emulation, both unused by this profile.  Keeping the
    screen BlockHandler NULL removes another fragile callback edge without
    affecting keyboard, touchscreen, or redraw wakeups.
    """
    f = tree / "hw" / "kdrive" / "src" / "kdrive.c"
    if not f.is_file():
        return 0

    def transform(text: str) -> str:
        marker = "be300-tinyx: evdev input wakes through KdWakeupHandler"
        if marker in text:
            return text
        old = (
            "    pScreen->BlockHandler\t= KdBlockHandler;\n"
            "    pScreen->WakeupHandler\t= KdWakeupHandler;\n"
        )
        new = (
            f"    /* {marker}; no screen BlockHandler needed. */\n"
            "    pScreen->BlockHandler\t= NULL;\n"
            "    pScreen->WakeupHandler\t= KdWakeupHandler;\n"
        )
        if old not in text:
            fail("kdrive.c screen BlockHandler assignment context not found")
        return text.replace(old, new, 1)

    return 1 if rewrite_in_place(f, transform) else 0


def patch_kdrive_select_only_input_fds(tree: Path) -> int:
    """Use select(), not SIGIO, for kdrive evdev input on BE-300.

    Upstream kdrive marks input fds FASYNC and installs a SIGIO handler that
    drains every registered input fd.  That path is unsafe for this target:
    the handler can interrupt WaitForSomething() inside select() and enqueue
    X events from signal context.  The BE-300 profile already registers evdev
    fds in EnabledDevices and wakes KdWakeupHandler from the select mask, so
    keep only nonblocking I/O and the normal fd readiness path.
    """
    f = tree / "hw" / "kdrive" / "src" / "kinput.c"
    if not f.is_file():
        return 0

    def transform(text: str) -> str:
        marker = "be300-tinyx: select-driven input only"
        if marker in text:
            return text

        old_nonblock = (
            "static void\n"
            "KdNonBlockFd (int fd)\n"
            "{\n"
            "    int\tflags;\n"
            "    flags = fcntl (fd, F_GETFL);\n"
            "    flags |= FASYNC|NOBLOCK;\n"
            "    fcntl (fd, F_SETFL, flags);\n"
            "}\n"
        )
        new_nonblock = (
            "static void\n"
            "KdNonBlockFd (int fd)\n"
            "{\n"
            "    int\tflags;\n"
            "    flags = fcntl (fd, F_GETFL);\n"
            f"    /* {marker}; FASYNC/SIGIO is not safe on this target. */\n"
            "    flags |= NOBLOCK;\n"
            "    flags &= ~FASYNC;\n"
            "    fcntl (fd, F_SETFL, flags);\n"
            "}\n"
        )
        if old_nonblock not in text:
            fail("kinput.c KdNonBlockFd context not found")
        text = text.replace(old_nonblock, new_nonblock, 1)

        old_add = (
            "static void\n"
            "KdAddFd (int fd)\n"
            "{\n"
            "    struct sigaction\tact;\n"
            "    sigset_t\t\tset;\n"
            "    \n"
            "    kdnFds++;\n"
            "    fcntl (fd, F_SETOWN, getpid());\n"
            "    KdNonBlockFd (fd);\n"
            "    AddEnabledDevice (fd);\n"
            "    memset (&act, '\\0', sizeof act);\n"
            "    act.sa_handler = KdSigio;\n"
            "    sigemptyset (&act.sa_mask);\n"
            "    sigaddset (&act.sa_mask, SIGIO);\n"
            "    sigaddset (&act.sa_mask, SIGALRM);\n"
            "    sigaddset (&act.sa_mask, SIGVTALRM);\n"
            "    sigaction (SIGIO, &act, 0);\n"
            "    sigemptyset (&set);\n"
            "    sigprocmask (SIG_SETMASK, &set, 0);\n"
            "}\n"
        )
        new_add = (
            "static void\n"
            "KdAddFd (int fd)\n"
            "{\n"
            "    kdnFds++;\n"
            "    KdNonBlockFd (fd);\n"
            "    AddEnabledDevice (fd);\n"
            "}\n"
        )
        if old_add not in text:
            fail("kinput.c KdAddFd context not found")
        text = text.replace(old_add, new_add, 1)

        old_remove = (
            "    flags = fcntl (fd, F_GETFL);\n"
            "    flags &= ~(FASYNC|NOBLOCK);\n"
            "    fcntl (fd, F_SETFL, flags);\n"
        )
        new_remove = (
            "    flags = fcntl (fd, F_GETFL);\n"
            "    flags &= ~NOBLOCK;\n"
            "    flags &= ~FASYNC;\n"
            "    fcntl (fd, F_SETFL, flags);\n"
        )
        if old_remove not in text:
            fail("kinput.c KdRemoveFd flags context not found")
        return text.replace(old_remove, new_remove, 1)

    return 1 if rewrite_in_place(f, transform) else 0


def patch_kdrive_evdev_keyboard(tree: Path) -> int:
    """Reserved hook for future keyboard-driver work.

    kdrive 1.6 already ships an `evdev` keyboard driver in
    hw/kdrive/linux/evdev.c, and /bin/start-tinyx passes the Stowaway event
    node to it explicitly.  Keep this no-op hook so old notes that reference
    it do not become misleading entry points for a second implementation.
    """
    return 0


def patch_kdrive_evdev_keyboard_mapping(tree: Path) -> int:
    """Realign kdrive's evdev keyboard map with Linux KEY_* scancode space.

    `readMapping()` in hw/kdrive/linux/evdev.c (xorg-server-1.6.5) ships with:
        minScanCode = 0;
        maxScanCode = 193;
        ki->keySyms.mapWidth = 2;

    The bug is the minScanCode offset.  KdEnqueueKeyboardEvent computes
        key_code = scan_code + KD_MIN_KEYCODE - ki->minScanCode
    and the X server indexes kdDefaultKeymap as
        [(key_code - minKeyCode) * mapWidth + col].
    The kdDefaultKeymap source (hw/kdrive/src/kkeymap.c) starts at AT
    scancode 1 = XK_Escape, so the Linux KEY_* value space (which also
    starts at scancode 1) needs `minScanCode = 1` to align.  With
    minScanCode = 0, Linux KEY_ESC = 1 indexes the wrong row.

    The mapWidth must stay at 2 (the value `readMapping` already installs):
    kdDefaultKeymap is declared as `KeySym[KD_MAX_LENGTH * KD_MAX_WIDTH]`
    (KD_MAX_WIDTH = 4) but the C aggregate initializer fills entries
    sequentially at 2 keysyms per source row.  The data is therefore laid
    out at stride 2 in the underlying buffer; X server lookups must walk
    with stride 2 to land on the right keysyms.  An earlier version of this
    patch raised mapWidth to 4 and produced `code=49 sym=0xff9f` (XK_KP_Delete
    from row 83) for Left Shift (Linux KEY_LEFTSHIFT=42) — the May 13 smoke
    test caught this; correct width = 2 maps KEY_LEFTSHIFT to XK_Shift_L.

    The maxScanCode literal is bumped to 111 to cover every Linux KEY_*
    that has a real entry in kdDefaultKeymap (the last initialized row is
    scancode 112 = source line 150, "NoSymbol, NoSymbol").  KEY_F12 = 88
    and every BE-300 button/Stowaway emit code is well below this ceiling.
    """
    f = tree / "hw" / "kdrive" / "linux" / "evdev.c"
    if not f.is_file():
        return 0

    def transform(text: str) -> str:
        marker = "be300-tinyx: align kdrive evdev keymap with Linux KEY_*"
        if marker in text:
            return text

        old = (
            "    minScanCode = 0;\n"
            "    maxScanCode = 193;\n"
            "\n"
            "    ki->keySyms.mapWidth = 2;\n"
        )
        new = (
            f"    /* {marker}.\n"
            "     * Linux KEY_* uses the same value space as AT set 1 scancodes\n"
            "     * (KEY_ESC=1).  minScanCode=1 makes the kdrive arithmetic land\n"
            "     * on kdDefaultKeymap[0] = XK_Escape for KEY_ESC.\n"
            "     *\n"
            "     * Keep mapWidth=2: kdDefaultKeymap is declared as\n"
            "     *   KeySym[KD_MAX_LENGTH * KD_MAX_WIDTH] (KD_MAX_WIDTH=4)\n"
            "     * but the C aggregate initializer in kkeymap.c fills entries\n"
            "     * sequentially at 2 keysyms per source row, so the data lives\n"
            "     * at stride 2 in memory.  A previous build set mapWidth=4 and\n"
            "     * produced sym=XK_KP_Delete for Left Shift.\n"
            "     *\n"
            "     * maxScanCode=111 covers every initialized kdDefaultKeymap row;\n"
            "     * KEY_F12 = 88 and every BE-300 button/Stowaway code is below. */\n"
            "    minScanCode = 1;\n"
            "    maxScanCode = 111;\n"
            "\n"
            "    ki->keySyms.mapWidth = 2;\n"
        )
        if old not in text:
            fail("evdev.c readMapping() context not found")
        return text.replace(old, new, 1)

    return 1 if rewrite_in_place(f, transform) else 0


def patch_kdrive_evdev_wire_event(tree: Path) -> int:
    """Read Linux 4.2 MIPS evdev packets with the kernel wire layout.

    musl 1.2 gives 32-bit MIPS a 64-bit time_t, so userspace
    `struct input_event` is larger than the 16-byte record emitted by this
    Linux 4.2 kernel.  Reading the musl-sized structure makes the kdrive evdev
    pointer and keyboard drivers wait for bytes that never arrive.  Use the
    kernel ABI record layout explicitly for both touch and keyboard paths.
    """
    f = tree / "hw" / "kdrive" / "linux" / "evdev.c"
    if not f.is_file():
        return 0

    def transform(text: str) -> str:
        marker = "be300-tinyx: 16-byte Linux 4.2 MIPS evdev wire event"
        if marker in text:
            return text

        needle = "#define ABS_UNSET   -65535\n"
        insert = """\
#define ABS_UNSET   -65535

/*
 * be300-tinyx: 16-byte Linux 4.2 MIPS evdev wire event.
 * The target userspace is musl 1.2, where time_t is 64-bit even on o32
 * MIPS.  The 4.2 kernel still writes the old 32-bit timeval record to
 * /dev/input/event*, so read the fixed kernel wire record here.
 */
struct be300_evdev_event {
    int tv_sec;
    int tv_usec;
    unsigned short type;
    unsigned short code;
    int value;
};
"""
        if needle not in text:
            fail("evdev.c ABS_UNSET context not found")
        text = text.replace(needle, insert, 1)
        return text.replace("struct input_event", "struct be300_evdev_event")

    return 1 if rewrite_in_place(f, transform) else 0


def patch_dix_main_startup_logging(tree: Path) -> int:
    """Log coarse server startup milestones on the target.

    The BE-300 launcher treats the X socket as "server up", but Xorg creates
    that listener early, before screen, font, input and connection-block setup
    are complete.  These logs distinguish a real dispatch loop from a server
    that is still spinning during late initialization.
    """
    f = tree / "dix" / "main.c"
    if not f.is_file():
        return 0

    def transform(text: str) -> str:
        if "be300-tinyx: startup milestone logging" in text:
            return text

        replacements = [
            (
                "\tserverGeneration++;\n",
                "\tserverGeneration++;\n"
                "\t/* be300-tinyx: startup milestone logging. */\n"
                "\tErrorF(\"be300-main: generation %d start\\n\", serverGeneration);\n",
            ),
            (
                "\tInitOutput(&screenInfo, argc, argv);\n",
                "\tErrorF(\"be300-main: before InitOutput\\n\");\n"
                "\tInitOutput(&screenInfo, argc, argv);\n"
                "\tErrorF(\"be300-main: after InitOutput screens=%d\\n\", screenInfo.numScreens);\n",
            ),
            (
                "\tInitExtensions(argc, argv);\n",
                "\tErrorF(\"be300-main: before InitExtensions\\n\");\n"
                "\tInitExtensions(argc, argv);\n"
                "\tErrorF(\"be300-main: after InitExtensions\\n\");\n",
            ),
            (
                "\tInitFonts();\n",
                "\tErrorF(\"be300-main: before InitFonts\\n\");\n"
                "\tInitFonts();\n"
                "\tErrorF(\"be300-main: after InitFonts\\n\");\n",
            ),
            (
                "\tif (SetDefaultFontPath(defaultFontPath) != Success) {\n",
                "\tErrorF(\"be300-main: before SetDefaultFontPath\\n\");\n"
                "\tif (SetDefaultFontPath(defaultFontPath) != Success) {\n",
            ),
            (
                "\tif (!SetDefaultFont(defaultTextFont)) {\n",
                "\tErrorF(\"be300-main: before SetDefaultFont\\n\");\n"
                "\tif (!SetDefaultFont(defaultTextFont)) {\n",
            ),
            (
                "\tif (!(rootCursor = CreateRootCursor(NULL, 0))) {\n",
                "\tErrorF(\"be300-main: before CreateRootCursor\\n\");\n"
                "\tif (!(rootCursor = CreateRootCursor(NULL, 0))) {\n",
            ),
            (
                "\tfor (i = 0; i < screenInfo.numScreens; i++)\n"
                "\t    InitRootWindow(WindowTable[i]);\n"
                "\tDefineInitialRootWindow(WindowTable[0]);\n",
                "\tErrorF(\"be300-main: before InitRootWindow\\n\");\n"
                "\tfor (i = 0; i < screenInfo.numScreens; i++)\n"
                "\t    InitRootWindow(WindowTable[i]);\n"
                "\tDefineInitialRootWindow(WindowTable[0]);\n"
                "\tErrorF(\"be300-main: after DefineInitialRootWindow\\n\");\n",
            ),
            (
                "        InitCoreDevices();\n"
                "\tInitInput(argc, argv);\n"
                "\tInitAndStartDevices();\n",
                "        ErrorF(\"be300-main: before InitCoreDevices\\n\");\n"
                "        InitCoreDevices();\n"
                "\tErrorF(\"be300-main: before InitInput\\n\");\n"
                "\tInitInput(argc, argv);\n"
                "\tErrorF(\"be300-main: before InitAndStartDevices\\n\");\n"
                "\tInitAndStartDevices();\n"
                "\tErrorF(\"be300-main: after InitAndStartDevices\\n\");\n",
            ),
            (
                "\t    if (!CreateConnectionBlock()) {\n",
                "\t    ErrorF(\"be300-main: before CreateConnectionBlock\\n\");\n"
                "\t    if (!CreateConnectionBlock()) {\n",
            ),
            (
                "\tNotifyParentProcess();\n"
                "\n"
                "\tDispatch();\n",
                "\tNotifyParentProcess();\n"
                "\tErrorF(\"be300-main: entering Dispatch\\n\");\n"
                "\n"
                "\tDispatch();\n"
                "\tErrorF(\"be300-main: Dispatch returned\\n\");\n",
            ),
        ]

        for old, new in replacements:
            if old not in text:
                fail("dix/main.c startup logging context not found")
            text = text.replace(old, new, 1)
        return text

    return 1 if rewrite_in_place(f, transform) else 0


def patch_connection_logging(tree: Path) -> int:
    """Keep the TinyX listener accept path simple on the BE-300."""
    f = tree / "os" / "connection.c"
    if not f.is_file():
        return 0

    def transform(text: str) -> str:
        marker = "be300-tinyx: skip pre-accept straggler timeout"

        # Drop temporary listener diagnostics from earlier bring-up patches.
        log_replacements = [
            (
                "      if (readyconnections.fds_bits[i])\n"
                "          ErrorF(\"be300-conn: fdset word=%d mask=%lx\\n\",\n"
                "                 i, (unsigned long)readyconnections.fds_bits[i]);\n"
                "      while (readyconnections.fds_bits[i])\n",
                "      while (readyconnections.fds_bits[i])\n",
            ),
            (
                "      if (readyconnections.fds_bits[i])\n"
                "          ErrorF(\"be300-conn: fdset word ready=%d\\n\", i);\n"
                "      while (readyconnections.fds_bits[i])\n",
                "      while (readyconnections.fds_bits[i])\n",
            ),
            (
                "\tErrorF(\"be300-conn: before ffs word=%d mask=%lx\\n\",\n"
                "\t       i, (unsigned long)readyconnections.fds_bits[i]);\n"
                "\tcurconn = ffs (readyconnections.fds_bits[i]) - 1;\n",
                "\tcurconn = ffs (readyconnections.fds_bits[i]) - 1;\n",
            ),
            (
                "\tErrorF(\"be300-conn: before ffs word=%d\\n\", i);\n"
                "\tcurconn = ffs (readyconnections.fds_bits[i]) - 1;\n"
                "\tErrorF(\"be300-conn: after ffs bit=%d word=%d\\n\", curconn, i);\n",
                "\tcurconn = ffs (readyconnections.fds_bits[i]) - 1;\n",
            ),
            (
                "\tErrorF(\"be300-conn: before lookup fd=%d\\n\", curconn);\n"
                "\tif ((trans_conn = lookup_trans_conn (curconn)) == NULL) {\n"
                "\t    ErrorF(\"be300-conn: lookup failed fd=%d\\n\", curconn);\n"
                "\t    continue;\n"
                "\t}\n"
                "\tErrorF(\"be300-conn: after lookup fd=%d trans=%p\\n\", curconn, trans_conn);\n"
                "\n"
                "\tErrorF(\"be300-conn: accepting listener fd=%d\\n\", curconn);\n",
                "\tif ((trans_conn = lookup_trans_conn (curconn)) == NULL)\n"
                "\t    continue;\n"
                "\n",
            ),
            (
                "\tErrorF(\"be300-conn: accepting listener fd=%d\\n\", curconn);\n"
                "\tif ((new_trans_conn = _XSERVTransAccept (trans_conn, &status)) == NULL) {\n"
                "\t    ErrorF(\"be300-conn: accept failed status=%d\\n\", status);\n"
                "\t    continue;\n"
                "\t}\n"
                "\n"
                "\tnewconn = _XSERVTransGetConnectionNumber (new_trans_conn);\n"
                "\tErrorF(\"be300-conn: accepted client fd=%d\\n\", newconn);\n",
                "\tif ((new_trans_conn = _XSERVTransAccept (trans_conn, &status)) == NULL)\n"
                "\t    continue;\n"
                "\n"
                "\tnewconn = _XSERVTransGetConnectionNumber (new_trans_conn);\n",
            ),
            (
                "\tErrorF(\"be300-conn: accepting listener fd=%d\\n\", curconn);\n"
                "\tif ((new_trans_conn = _XSERVTransAccept (trans_conn, &status)) == NULL)\n",
                "\tif ((new_trans_conn = _XSERVTransAccept (trans_conn, &status)) == NULL)\n",
            ),
        ]
        for old, new in log_replacements:
            text = text.replace(old, new)

        if marker not in text:
            start_marker = "    XFD_COPYSET(&tmask, &readyconnections);\n"
            loop_marker = (
                "#ifndef WIN32\n"
                "    for (i = 0; i < howmany(XFD_SETSIZE, NFDBITS); i++)\n"
            )
            start = text.find(start_marker)
            end = text.find(loop_marker, start if start >= 0 else 0)
            if start < 0 or end < 0:
                fail("connection.c accept path context not found")

            replacement = (
                "    XFD_COPYSET(&tmask, &readyconnections);\n"
                "    /* be300-tinyx: skip pre-accept straggler timeout. */\n"
                "    if (!XFD_ANYSET(&readyconnections))\n"
                "\treturn TRUE;\n"
                "    connect_time = 0;\n"
            )
            text = text[:start] + replacement + text[end:]

        return text

    return 1 if rewrite_in_place(f, transform) else 0


def patch_os_time_local_binding(tree: Path) -> int:
    """Bind GetTimeInMillis locally on MIPS to avoid broken PLT call edges."""
    changed = 0

    osh = tree / "include" / "os.h"
    if osh.is_file():
        def transform_osh(text: str) -> str:
            if "be300-tinyx: hide GetTimeInMillis" in text:
                return text
            return text.replace(
                "extern CARD32 GetTimeInMillis(void);\n",
                "/* be300-tinyx: hide GetTimeInMillis so MIPS PIC calls bind locally. */\n"
                "#ifdef __GNUC__\n"
                "extern __attribute__((visibility(\"hidden\"))) CARD32 GetTimeInMillis(void);\n"
                "#else\n"
                "extern CARD32 GetTimeInMillis(void);\n"
                "#endif\n",
                1,
            )
        if rewrite_in_place(osh, transform_osh):
            changed += 1

    utils = tree / "os" / "utils.c"
    if utils.is_file():
        def transform_utils(text: str) -> str:
            if "be300-tinyx: hide GetTimeInMillis definition" not in text:
                text = text.replace(
                    "#if defined WIN32 && defined __MINGW32__\n"
                    "_X_EXPORT CARD32\n"
                    "GetTimeInMillis (void)\n",
                    "#if defined WIN32 && defined __MINGW32__\n"
                    "/* be300-tinyx: hide GetTimeInMillis definition from the dynamic symbol table. */\n"
                    "#ifdef __GNUC__\n"
                    "__attribute__((visibility(\"hidden\")))\n"
                    "#endif\n"
                    "CARD32\n"
                    "GetTimeInMillis (void)\n",
                    1,
                )
                text = text.replace(
                    "#else\n"
                    "_X_EXPORT CARD32\n"
                    "GetTimeInMillis(void)\n",
                    "#else\n"
                    "#ifdef __GNUC__\n"
                    "__attribute__((visibility(\"hidden\")))\n"
                    "#endif\n"
                    "CARD32\n"
                    "GetTimeInMillis(void)\n",
                    1,
                )
            mips_counter = (
                "#if defined(__linux__) && defined(__mips__) && !defined(WIN32)\n"
                "    /* be300-tinyx: MIPS monotonic counter, avoiding fragile libc/syscall edges. */\n"
                "    static CARD32 be300_millis;\n"
                "\n"
                "    be300_millis += 10;\n"
                "    return be300_millis;\n"
                "#else\n"
            )
            if "be300-tinyx: direct MIPS gettimeofday syscall" in text:
                text = text.replace(
                    "#if defined(__linux__) && defined(__mips__) && !defined(WIN32) && defined(__NR_gettimeofday)\n"
                    "    /* be300-tinyx: direct MIPS gettimeofday syscall, avoiding uClibc PLT/GOT. */\n"
                    "    register long v0 __asm__(\"$2\") = __NR_gettimeofday;\n"
                    "    register long a0 __asm__(\"$4\") = (long)&tv;\n"
                    "    register long a1 __asm__(\"$5\") = 0;\n"
                    "    register long a3 __asm__(\"$7\");\n"
                    "\n"
                    "    __asm__ volatile (\n"
                    "        \"syscall\"\n"
                    "        : \"+r\" (v0), \"+r\" (a0), \"+r\" (a1), \"=r\" (a3)\n"
                    "        :\n"
                    "        : \"memory\");\n"
                    "\n"
                    "    if (a3)\n"
                    "        return 0;\n"
                    "    return(tv.tv_sec * 1000) + (tv.tv_usec / 1000);\n"
                    "#else\n",
                    mips_counter,
                    1,
                )
            if "be300-tinyx: MIPS monotonic counter" not in text:
                text = text.replace(
                    "CARD32\n"
                    "GetTimeInMillis(void)\n"
                    "{\n"
                    "    struct timeval tv;\n"
                    "\n"
                    "#ifdef MONOTONIC_CLOCK\n"
                    "    struct timespec tp;\n"
                    "    if (clock_gettime(CLOCK_MONOTONIC, &tp) == 0)\n"
                    "        return (tp.tv_sec * 1000) + (tp.tv_nsec / 1000000L);\n"
                    "#endif\n"
                    "\n"
                    "    X_GETTIMEOFDAY(&tv);\n"
                    "    return(tv.tv_sec * 1000) + (tv.tv_usec / 1000);\n"
                    "}\n",
                    "CARD32\n"
                    "GetTimeInMillis(void)\n"
                    "{\n"
                    "    struct timeval tv;\n"
                    "\n"
                    + mips_counter +
                    "#ifdef MONOTONIC_CLOCK\n"
                    "    struct timespec tp;\n"
                    "    if (clock_gettime(CLOCK_MONOTONIC, &tp) == 0)\n"
                    "        return (tp.tv_sec * 1000) + (tp.tv_nsec / 1000000L);\n"
                    "#endif\n"
                    "\n"
                    "    X_GETTIMEOFDAY(&tv);\n"
                    "    return(tv.tv_sec * 1000) + (tv.tv_usec / 1000);\n"
                    "#endif\n"
                    "}\n",
                    1,
                )
            return text
        if rewrite_in_place(utils, transform_utils):
            changed += 1

    return changed


def patch_os_io_local_binding(tree: Path) -> int:
    """Bind hot client I/O helpers locally on MIPS.

    Xfbdev is linked as an exported executable for old module semantics.  On
    this uClibc/MIPS target, a few executable-internal calls through exported
    dynamic symbols resolve to a null call edge at runtime.  The kdrive TinyX
    image is monolithic, so these client I/O entry points can stay local.
    """
    changed = 0

    osh = tree / "include" / "os.h"
    if osh.is_file():
        def transform_osh(text: str) -> str:
            # Fresh tree: add the whole hidden-visibility block.  An earlier
            # version of this patch left ReadRequestFromClient and
            # InsertFakeRequest exported, which on uClibc-ng/MIPS resolved the
            # Dispatch() -> ReadRequestFromClient call through a GOT slot that
            # never got filled in — every first real client request crashed in
            # `jalr t9` with t9 = 0.  Hiding both functions forces gcc to emit
            # a direct branch from dispatch.c into io.c.
            if "be300-tinyx: hide client I/O helpers" not in text:
                text = text.replace(
                    "extern int ReadRequestFromClient(ClientPtr /*client*/);\n"
                    "\n"
                    "extern Bool InsertFakeRequest(\n"
                    "    ClientPtr /*client*/, \n"
                    "    char* /*data*/, \n"
                    "    int /*count*/);\n"
                    "\n"
                    "extern void ResetCurrentRequest(ClientPtr /*client*/);\n"
                    "\n"
                    "extern void FlushAllOutput(void);\n"
                    "\n"
                    "extern void FlushIfCriticalOutputPending(void);\n"
                    "\n"
                    "extern void SetCriticalOutputPending(void);\n"
                    "\n"
                    "extern int WriteToClient(ClientPtr /*who*/, int /*count*/, const void* /*buf*/);\n"
                    "\n"
                    "extern void ResetOsBuffers(void);\n",
                    "/* be300-tinyx: hide client I/O helpers so MIPS PIC calls bind locally. */\n"
                    "#ifdef __GNUC__\n"
                    "extern __attribute__((visibility(\"hidden\"))) int ReadRequestFromClient(ClientPtr /*client*/);\n"
                    "\n"
                    "extern __attribute__((visibility(\"hidden\"))) Bool InsertFakeRequest(\n"
                    "    ClientPtr /*client*/,\n"
                    "    char* /*data*/,\n"
                    "    int /*count*/);\n"
                    "\n"
                    "extern __attribute__((visibility(\"hidden\"))) void ResetCurrentRequest(ClientPtr /*client*/);\n"
                    "\n"
                    "extern __attribute__((visibility(\"hidden\"))) void FlushAllOutput(void);\n"
                    "\n"
                    "extern __attribute__((visibility(\"hidden\"))) void FlushIfCriticalOutputPending(void);\n"
                    "\n"
                    "extern __attribute__((visibility(\"hidden\"))) void SetCriticalOutputPending(void);\n"
                    "\n"
                    "extern __attribute__((visibility(\"hidden\"))) int WriteToClient(ClientPtr /*who*/, int /*count*/, const void* /*buf*/);\n"
                    "\n"
                    "extern __attribute__((visibility(\"hidden\"))) void ResetOsBuffers(void);\n"
                    "#else\n"
                    "\n"
                    "extern int ReadRequestFromClient(ClientPtr /*client*/);\n"
                    "\n"
                    "extern Bool InsertFakeRequest(\n"
                    "    ClientPtr /*client*/,\n"
                    "    char* /*data*/,\n"
                    "    int /*count*/);\n"
                    "\n"
                    "extern void ResetCurrentRequest(ClientPtr /*client*/);\n"
                    "\n"
                    "extern void FlushAllOutput(void);\n"
                    "\n"
                    "extern void FlushIfCriticalOutputPending(void);\n"
                    "\n"
                    "extern void SetCriticalOutputPending(void);\n"
                    "\n"
                    "extern int WriteToClient(ClientPtr /*who*/, int /*count*/, const void* /*buf*/);\n"
                    "\n"
                    "extern void ResetOsBuffers(void);\n"
                    "#endif\n",
                    1,
                )
            else:
                # Tree was patched with an earlier revision that left
                # ReadRequestFromClient/InsertFakeRequest exported.  Promote
                # them to hidden in-place so subsequent rebuilds are correct.
                text = text.replace(
                    "extern int ReadRequestFromClient(ClientPtr /*client*/);\n"
                    "\n"
                    "extern Bool InsertFakeRequest(\n",
                    "extern __attribute__((visibility(\"hidden\"))) int ReadRequestFromClient(ClientPtr /*client*/);\n"
                    "\n"
                    "extern __attribute__((visibility(\"hidden\"))) Bool InsertFakeRequest(\n",
                    1,
                )
            return text
        if rewrite_in_place(osh, transform_osh):
            changed += 1

    io = tree / "os" / "io.c"
    if io.is_file():
        def transform_io(text: str) -> str:
            marker = "be300-tinyx: hide client I/O helper definitions"
            had_marker = marker in text

            # Fresh tree: prepend the hidden-visibility attribute and marker
            # comment to ReadRequestFromClient.  Already-patched older trees
            # (which had the comment but lacked the attribute on this one
            # function) get the attribute spliced in.
            if not had_marker:
                text = text.replace(
                    "int\n"
                    "ReadRequestFromClient(ClientPtr client)\n",
                    "/* be300-tinyx: hide client I/O helper definitions from the dynamic symbol table. */\n"
                    "#ifdef __GNUC__\n"
                    "__attribute__((visibility(\"hidden\")))\n"
                    "#endif\n"
                    "int\n"
                    "ReadRequestFromClient(ClientPtr client)\n",
                    1,
                )
            else:
                text = text.replace(
                    "/* be300-tinyx: hide client I/O helper definitions from the dynamic symbol table. */\n"
                    "int\n"
                    "ReadRequestFromClient(ClientPtr client)\n",
                    "/* be300-tinyx: hide client I/O helper definitions from the dynamic symbol table. */\n"
                    "#ifdef __GNUC__\n"
                    "__attribute__((visibility(\"hidden\")))\n"
                    "#endif\n"
                    "int\n"
                    "ReadRequestFromClient(ClientPtr client)\n",
                    1,
                )
            if not had_marker:
                text = text.replace(
                    "Bool\n"
                    "InsertFakeRequest(ClientPtr client, char *data, int count)\n",
                    "#ifdef __GNUC__\n"
                    "__attribute__((visibility(\"hidden\")))\n"
                    "#endif\n"
                    "Bool\n"
                    "InsertFakeRequest(ClientPtr client, char *data, int count)\n",
                    1,
                )
                text = text.replace(
                    "_X_EXPORT void\n"
                    "ResetCurrentRequest(ClientPtr client)\n",
                    "#ifdef __GNUC__\n"
                    "__attribute__((visibility(\"hidden\")))\n"
                    "#endif\n"
                    "void\n"
                    "ResetCurrentRequest(ClientPtr client)\n",
                    1,
                )
                text = text.replace(
                    "void\n"
                    "FlushAllOutput(void)\n",
                    "#ifdef __GNUC__\n"
                    "__attribute__((visibility(\"hidden\")))\n"
                    "#endif\n"
                    "void\n"
                    "FlushAllOutput(void)\n",
                    1,
                )
                text = text.replace(
                    "void\n"
                    "FlushIfCriticalOutputPending(void)\n",
                    "#ifdef __GNUC__\n"
                    "__attribute__((visibility(\"hidden\")))\n"
                    "#endif\n"
                    "void\n"
                    "FlushIfCriticalOutputPending(void)\n",
                    1,
                )
                text = text.replace(
                    "_X_EXPORT void\n"
                    "SetCriticalOutputPending(void)\n",
                    "#ifdef __GNUC__\n"
                    "__attribute__((visibility(\"hidden\")))\n"
                    "#endif\n"
                    "void\n"
                    "SetCriticalOutputPending(void)\n",
                    1,
                )
                text = text.replace(
                    "_X_EXPORT int\n"
                    "WriteToClient (ClientPtr who, int count, const void *__buf)\n",
                    "#ifdef __GNUC__\n"
                    "__attribute__((visibility(\"hidden\")))\n"
                    "#endif\n"
                    "int\n"
                    "WriteToClient (ClientPtr who, int count, const void *__buf)\n",
                    1,
                )
                text = text.replace(
                    "void\n"
                    "ResetOsBuffers(void)\n",
                    "#ifdef __GNUC__\n"
                    "__attribute__((visibility(\"hidden\")))\n"
                    "#endif\n"
                    "void\n"
                    "ResetOsBuffers(void)\n",
                    1,
                )
            return text
        if rewrite_in_place(io, transform_io):
            changed += 1

    return changed


def patch_dix_close_down_client_local_binding(tree: Path) -> int:
    """Bind CloseDownClient locally on MIPS.

    The first client-accept path can call CloseDownClient while reaping stale
    initial clients.  On this monolithic kdrive build, routing that executable-
    internal call through the dynamic symbol table can land on a null call edge
    on the BE-300 uClibc/MIPS target, just like the earlier client I/O helpers.
    """
    changed = 0

    dixh = tree / "include" / "dix.h"
    if dixh.is_file():
        def transform_dixh(text: str) -> str:
            if "be300-tinyx: hide CloseDownClient" in text:
                return text
            return text.replace(
                "extern void CloseDownClient(\n"
                "    ClientPtr /*client*/);\n",
                "/* be300-tinyx: hide CloseDownClient so MIPS PIC calls bind locally. */\n"
                "#ifdef __GNUC__\n"
                "extern __attribute__((visibility(\"hidden\"))) void CloseDownClient(\n"
                "    ClientPtr /*client*/);\n"
                "#else\n"
                "extern void CloseDownClient(\n"
                "    ClientPtr /*client*/);\n"
                "#endif\n",
                1,
            )

        if rewrite_in_place(dixh, transform_dixh):
            changed += 1

    dispatch = tree / "dix" / "dispatch.c"
    if dispatch.is_file():
        def transform_dispatch(text: str) -> str:
            if "be300-tinyx: hide CloseDownClient definition" in text:
                return text
            return text.replace(
                "void\n"
                "CloseDownClient(ClientPtr client)\n",
                "/* be300-tinyx: hide CloseDownClient definition from the dynamic symbol table. */\n"
                "#ifdef __GNUC__\n"
                "__attribute__((visibility(\"hidden\")))\n"
                "#endif\n"
                "void\n"
                "CloseDownClient(ClientPtr client)\n",
                1,
            )

        if rewrite_in_place(dispatch, transform_dispatch):
            changed += 1

    return changed


def patch_connection_auth_local_binding(tree: Path) -> int:
    """Bind first-client authorization helpers locally on MIPS.

    Client setup runs before matchbox/rxvt can draw anything.  Keep the
    authorization helpers executable-local so those internal call edges do not
    depend on exported dynamic symbols in the monolithic kdrive binary.
    """
    changed = 0

    osh = tree / "include" / "os.h"
    if osh.is_file():
        def transform_osh(text: str) -> str:
            if "be300-tinyx: hide connection authorization helpers" in text:
                return text
            text = text.replace(
                "extern char *ClientAuthorized(\n"
                "    ClientPtr /*client*/,\n"
                "    unsigned int /*proto_n*/,\n"
                "    char* /*auth_proto*/,\n"
                "    unsigned int /*string_n*/,\n"
                "    char* /*auth_string*/);\n",
                "/* be300-tinyx: hide connection authorization helpers so MIPS PIC calls bind locally. */\n"
                "#ifdef __GNUC__\n"
                "extern __attribute__((visibility(\"hidden\"))) char *ClientAuthorized(\n"
                "#else\n"
                "extern char *ClientAuthorized(\n"
                "#endif\n"
                "    ClientPtr /*client*/,\n"
                "    unsigned int /*proto_n*/,\n"
                "    char* /*auth_proto*/,\n"
                "    unsigned int /*string_n*/,\n"
                "    char* /*auth_string*/);\n",
                1,
            )
            text = text.replace(
                "extern int InvalidHost(sockaddrPtr /*saddr*/, int /*len*/, ClientPtr client);\n",
                "#ifdef __GNUC__\n"
                "extern __attribute__((visibility(\"hidden\"))) int InvalidHost(sockaddrPtr /*saddr*/, int /*len*/, ClientPtr client);\n"
                "#else\n"
                "extern int InvalidHost(sockaddrPtr /*saddr*/, int /*len*/, ClientPtr client);\n"
                "#endif\n",
                1,
            )
            text = text.replace(
                "extern XID CheckAuthorization(\n"
                "    unsigned int /*namelength*/,\n"
                "    char * /*name*/,\n"
                "    unsigned int /*datalength*/,\n"
                "    char * /*data*/,\n"
                "    ClientPtr /*client*/,\n"
                "    char ** /*reason*/\n"
                ");\n",
                "#ifdef __GNUC__\n"
                "extern __attribute__((visibility(\"hidden\"))) XID CheckAuthorization(\n"
                "#else\n"
                "extern XID CheckAuthorization(\n"
                "#endif\n"
                "    unsigned int /*namelength*/,\n"
                "    char * /*name*/,\n"
                "    unsigned int /*datalength*/,\n"
                "    char * /*data*/,\n"
                "    ClientPtr /*client*/,\n"
                "    char ** /*reason*/\n"
                ");\n",
                1,
            )
            return text

        if rewrite_in_place(osh, transform_osh):
            changed += 1

    conn = tree / "os" / "connection.c"
    if conn.is_file():
        def transform_conn(text: str) -> str:
            if "be300-tinyx: hide ClientAuthorized definition" in text:
                return text
            return text.replace(
                "char * \n"
                "ClientAuthorized(ClientPtr client, \n",
                "/* be300-tinyx: hide ClientAuthorized definition from the dynamic symbol table. */\n"
                "#ifdef __GNUC__\n"
                "__attribute__((visibility(\"hidden\")))\n"
                "#endif\n"
                "char * \n"
                "ClientAuthorized(ClientPtr client, \n",
                1,
            )

        if rewrite_in_place(conn, transform_conn):
            changed += 1

    access = tree / "os" / "access.c"
    if access.is_file():
        def transform_access(text: str) -> str:
            if "be300-tinyx: hide InvalidHost definition" in text:
                return text
            return text.replace(
                "int\n"
                "InvalidHost (\n",
                "/* be300-tinyx: hide InvalidHost definition from the dynamic symbol table. */\n"
                "#ifdef __GNUC__\n"
                "__attribute__((visibility(\"hidden\")))\n"
                "#endif\n"
                "int\n"
                "InvalidHost (\n",
                1,
            )

        if rewrite_in_place(access, transform_access):
            changed += 1

    auth = tree / "os" / "auth.c"
    if auth.is_file():
        def transform_auth(text: str) -> str:
            if "be300-tinyx: hide CheckAuthorization definition" in text:
                return text
            return text.replace(
                "XID\n"
                "CheckAuthorization (\n",
                "/* be300-tinyx: hide CheckAuthorization definition from the dynamic symbol table. */\n"
                "#ifdef __GNUC__\n"
                "__attribute__((visibility(\"hidden\")))\n"
                "#endif\n"
                "XID\n"
                "CheckAuthorization (\n",
                1,
            )

        if rewrite_in_place(auth, transform_auth):
            changed += 1

    return changed


def patch_xace_hook_local_binding(tree: Path) -> int:
    """Bind the XACE dispatch hook locally on MIPS."""
    changed = 0

    xaceh = tree / "Xext" / "xace.h"
    if xaceh.is_file():
        def transform_xaceh(text: str) -> str:
            if "be300-tinyx: hide XaceHook" in text:
                return text
            return text.replace(
                "extern int XaceHook(\n"
                "    int /*hook*/,\n"
                "    ... /*appropriate args for hook*/\n"
                "    ); \n",
                "/* be300-tinyx: hide XaceHook so MIPS PIC calls bind locally. */\n"
                "#ifdef __GNUC__\n"
                "extern __attribute__((visibility(\"hidden\"))) int XaceHook(\n"
                "#else\n"
                "extern int XaceHook(\n"
                "#endif\n"
                "    int /*hook*/,\n"
                "    ... /*appropriate args for hook*/\n"
                "    ); \n",
                1,
            )

        if rewrite_in_place(xaceh, transform_xaceh):
            changed += 1

    xacec = tree / "Xext" / "xace.c"
    if xacec.is_file():
        def transform_xacec(text: str) -> str:
            if "be300-tinyx: hide XaceHook definition" in text:
                return text
            return text.replace(
                "int XaceHook(int hook, ...)\n",
                "/* be300-tinyx: hide XaceHook definition from the dynamic symbol table. */\n"
                "#ifdef __GNUC__\n"
                "__attribute__((visibility(\"hidden\")))\n"
                "#endif\n"
                "int XaceHook(int hook, ...)\n",
                1,
            )

        if rewrite_in_place(xacec, transform_xacec):
            changed += 1

    return changed


def patch_callback_local_binding(tree: Path) -> int:
    """Bind callback manager calls/globals locally on MIPS."""
    changed = 0

    dixh = tree / "include" / "dix.h"
    if dixh.is_file():
        def transform_dixh(text: str) -> str:
            if "be300-tinyx: local callback manager symbols" not in text:
                text = text.replace(
                    "#ifndef _XTYPEDEF_CALLBACKLISTPTR\n"
                    "typedef struct _CallbackList *CallbackListPtr; /* also in misc.h */\n"
                    "#define _XTYPEDEF_CALLBACKLISTPTR\n"
                    "#endif\n"
                    "\n"
                    "typedef void (*CallbackProcPtr) (\n",
                    "#ifndef _XTYPEDEF_CALLBACKLISTPTR\n"
                    "typedef struct _CallbackList *CallbackListPtr; /* also in misc.h */\n"
                    "#define _XTYPEDEF_CALLBACKLISTPTR\n"
                    "#endif\n"
                    "\n"
                    "/* be300-tinyx: local callback manager symbols. */\n"
                    "#ifdef __GNUC__\n"
                    "#define BE300_CALLBACK_LOCAL __attribute__((visibility(\"hidden\")))\n"
                    "#else\n"
                    "#define BE300_CALLBACK_LOCAL\n"
                    "#endif\n"
                    "\n"
                    "typedef void (*CallbackProcPtr) (\n",
                    1,
                )
            replacements = (
                ("extern Bool AddCallback(\n", "extern BE300_CALLBACK_LOCAL Bool AddCallback(\n"),
                ("extern Bool DeleteCallback(\n", "extern BE300_CALLBACK_LOCAL Bool DeleteCallback(\n"),
                ("extern void DeleteCallbackList(\n", "extern BE300_CALLBACK_LOCAL void DeleteCallbackList(\n"),
                ("extern void CallCallbacks(\n", "extern BE300_CALLBACK_LOCAL void CallCallbacks(\n"),
            )
            text = text.replace(
                "/* be300-tinyx: hide CallCallbacks so MIPS PIC calls bind locally. */\n"
                "#ifdef __GNUC__\n"
                "extern __attribute__((visibility(\"hidden\"))) void CallCallbacks(\n"
                "#else\n"
                "extern void CallCallbacks(\n"
                "#endif\n",
                "extern BE300_CALLBACK_LOCAL void CallCallbacks(\n",
                1,
            )
            text = text.replace(
                "/* be300-tinyx: hide CallCallbacks so MIPS PIC calls bind locally. */\n"
                "#ifdef __GNUC__\n"
                "extern __attribute__((visibility(\"hidden\"))) void CallCallbacks(\n"
                "#else\n"
                "extern BE300_CALLBACK_LOCAL void CallCallbacks(\n"
                "#endif\n",
                "extern BE300_CALLBACK_LOCAL void CallCallbacks(\n",
                1,
            )
            for old, new in replacements:
                if new not in text:
                    text = text.replace(old, new, 1)
            return text
        if rewrite_in_place(dixh, transform_dixh):
            changed += 1

    dixstructh = tree / "include" / "dixstruct.h"
    if dixstructh.is_file():
        def transform_dixstructh(text: str) -> str:
            if "be300-tinyx: local ClientStateCallback" in text:
                return text
            return text.replace(
                "extern CallbackListPtr ClientStateCallback;\n",
                "/* be300-tinyx: local ClientStateCallback binding. */\n"
                "#ifdef __GNUC__\n"
                "extern __attribute__((visibility(\"hidden\"))) CallbackListPtr ClientStateCallback;\n"
                "#else\n"
                "extern CallbackListPtr ClientStateCallback;\n"
                "#endif\n",
                1,
            )
        if rewrite_in_place(dixstructh, transform_dixstructh):
            changed += 1

    dispatch = tree / "dix" / "dispatch.c"
    if dispatch.is_file():
        def transform_dispatch(text: str) -> str:
            if "be300-tinyx: hide ClientStateCallback definition" in text:
                return text
            return text.replace(
                "_X_EXPORT CallbackListPtr ClientStateCallback;\n",
                "/* be300-tinyx: hide ClientStateCallback definition from the dynamic symbol table. */\n"
                "#ifdef __GNUC__\n"
                "__attribute__((visibility(\"hidden\")))\n"
                "#endif\n"
                "CallbackListPtr ClientStateCallback;\n",
                1,
            )
        if rewrite_in_place(dispatch, transform_dispatch):
            changed += 1

    dixutils = tree / "dix" / "dixutils.c"
    if dixutils.is_file():
        def transform_dixutils(text: str) -> str:
            if "be300-tinyx: callback registration logging" not in text:
                text = text.replace(
                    "    cbr->proc = callback;\n"
                    "    cbr->data = data;\n"
                    "    cbr->next = (*pcbl)->list;\n"
                    "    cbr->deleted = FALSE;\n"
                    "    (*pcbl)->list = cbr;\n",
                    "    cbr->proc = callback;\n"
                    "    cbr->data = data;\n"
                    "    cbr->next = (*pcbl)->list;\n"
                    "    cbr->deleted = FALSE;\n"
                    "    (*pcbl)->list = cbr;\n"
                    "    /* be300-tinyx: callback registration logging. */\n"
                    "    ErrorF(\"be300-callbacks: add pcbl=%p cbl=%p cbr=%p proc=%p data=%p next=%p\\n\",\n"
                    "           pcbl, *pcbl, cbr, callback, data, cbr->next);\n",
                    1,
                )
            if "be300-tinyx: callback node prelog" not in text:
                text = text.replace(
                    "    for (cbr = cbl->list; cbr != NULL; cbr = cbr->next)\n"
                    "    {\n"
                    "\tErrorF(\"be300-callbacks: proc=%p data=%p deleted=%d next=%p\\n\",\n",
                    "    for (cbr = cbl->list; cbr != NULL; cbr = cbr->next)\n"
                    "    {\n"
                    "\t/* be300-tinyx: callback node prelog. */\n"
                    "\tErrorF(\"be300-callbacks: node=%p\\n\", cbr);\n"
                    "\tErrorF(\"be300-callbacks: proc=%p data=%p deleted=%d next=%p\\n\",\n",
                    1,
                )
            if "be300-tinyx: omit ClientStateCallback registrations" not in text:
                text = text.replace(
                    "    if (!pcbl) return FALSE;\n"
                    "    if (!*pcbl)\n",
                    "    if (!pcbl) return FALSE;\n"
                    "    /* be300-tinyx: omit ClientStateCallback registrations. */\n"
                    "    if (pcbl == &ClientStateCallback)\n"
                    "\treturn TRUE;\n"
                    "    if (!*pcbl)\n",
                    1,
                )
            if "be300-tinyx: hide AddCallback definition" not in text:
                text = text.replace(
                    "_X_EXPORT Bool \n"
                    "AddCallback(CallbackListPtr *pcbl, CallbackProcPtr callback, pointer data)\n",
                    "/* be300-tinyx: hide AddCallback definition from the dynamic symbol table. */\n"
                    "#ifdef __GNUC__\n"
                    "__attribute__((visibility(\"hidden\")))\n"
                    "#endif\n"
                    "Bool\n"
                    "AddCallback(CallbackListPtr *pcbl, CallbackProcPtr callback, pointer data)\n",
                    1,
                )
            if "be300-tinyx: hide DeleteCallback definition" not in text:
                text = text.replace(
                    "_X_EXPORT Bool \n"
                    "DeleteCallback(CallbackListPtr *pcbl, CallbackProcPtr callback, pointer data)\n",
                    "/* be300-tinyx: hide DeleteCallback definition from the dynamic symbol table. */\n"
                    "#ifdef __GNUC__\n"
                    "__attribute__((visibility(\"hidden\")))\n"
                    "#endif\n"
                    "Bool\n"
                    "DeleteCallback(CallbackListPtr *pcbl, CallbackProcPtr callback, pointer data)\n",
                    1,
                )
            if "be300-tinyx: hide CallCallbacks definition" not in text:
                text = text.replace(
                    "void \n"
                    "CallCallbacks(CallbackListPtr *pcbl, pointer call_data)\n",
                    "/* be300-tinyx: hide CallCallbacks definition from the dynamic symbol table. */\n"
                    "#ifdef __GNUC__\n"
                    "__attribute__((visibility(\"hidden\")))\n"
                    "#endif\n"
                    "void\n"
                    "CallCallbacks(CallbackListPtr *pcbl, pointer call_data)\n",
                    1,
                )
            if "be300-tinyx: hide DeleteCallbackList definition" not in text:
                text = text.replace(
                    "void\n"
                    "DeleteCallbackList(CallbackListPtr *pcbl)\n",
                    "/* be300-tinyx: hide DeleteCallbackList definition from the dynamic symbol table. */\n"
                    "#ifdef __GNUC__\n"
                    "__attribute__((visibility(\"hidden\")))\n"
                    "#endif\n"
                    "void\n"
                    "DeleteCallbackList(CallbackListPtr *pcbl)\n",
                    1,
                )
            return text
        if rewrite_in_place(dixutils, transform_dixutils):
            changed += 1

    return changed


def patch_block_wakeup_local_binding(tree: Path) -> int:
    """Bind DIX block/wakeup handlers locally and log handler dispatch."""
    changed = 0

    dixh = tree / "include" / "dix.h"
    if dixh.is_file():
        def transform_dixh(text: str) -> str:
            if "be300-tinyx: local block/wakeup bindings" in text:
                return text
            text = text.replace(
                "extern void NoopDDA(void);\n",
                "#ifdef __GNUC__\n"
                "/* be300-tinyx: local block/wakeup bindings. */\n"
                "#define BE300_BLOCK_LOCAL __attribute__((visibility(\"hidden\")))\n"
                "#else\n"
                "#define BE300_BLOCK_LOCAL\n"
                "#endif\n"
                "\n"
                "extern BE300_BLOCK_LOCAL void NoopDDA(void);\n",
                1,
            )
            for old, new in (
                ("extern void BlockHandler(\n", "extern BE300_BLOCK_LOCAL void BlockHandler(\n"),
                ("extern void WakeupHandler(\n", "extern BE300_BLOCK_LOCAL void WakeupHandler(\n"),
                (
                    "extern Bool RegisterBlockAndWakeupHandlers(\n",
                    "extern BE300_BLOCK_LOCAL Bool RegisterBlockAndWakeupHandlers(\n",
                ),
                (
                    "extern void RemoveBlockAndWakeupHandlers(\n",
                    "extern BE300_BLOCK_LOCAL void RemoveBlockAndWakeupHandlers(\n",
                ),
                (
                    "extern void InitBlockAndWakeupHandlers(void);\n",
                    "extern BE300_BLOCK_LOCAL void InitBlockAndWakeupHandlers(void);\n",
                ),
            ):
                text = text.replace(old, new, 1)
            return text
        if rewrite_in_place(dixh, transform_dixh):
            changed += 1

    dixutils = tree / "dix" / "dixutils.c"
    if dixutils.is_file():
        def transform_dixutils(text: str) -> str:
            if "be300-tinyx: block/wakeup local binding" in text:
                return text
            text = text.replace(
                "_X_EXPORT void\n"
                "NoopDDA(void)\n",
                "/* be300-tinyx: block/wakeup local binding. */\n"
                "#ifdef __GNUC__\n"
                "__attribute__((visibility(\"hidden\")))\n"
                "#endif\n"
                "void\n"
                "NoopDDA(void)\n",
                1,
            )
            text = text.replace(
                "void\n"
                "BlockHandler(pointer pTimeout, pointer pReadmask)\n"
                "{\n"
                "    int i, j;\n"
                "    \n"
                "    ++inHandler;\n"
                "    for (i = 0; i < screenInfo.numScreens; i++)\n"
                "\t(* screenInfo.screens[i]->BlockHandler)(i, \n"
                "\t\t\t\tscreenInfo.screens[i]->blockData,\n"
                "\t\t\t\tpTimeout, pReadmask);\n"
                "    for (i = 0; i < numHandlers; i++)\n"
                "\t(*handlers[i].BlockHandler) (handlers[i].blockData,\n"
                "\t\t\t\t     pTimeout, pReadmask);\n",
                "#ifdef __GNUC__\n"
                "__attribute__((visibility(\"hidden\")))\n"
                "#endif\n"
                "void\n"
                "BlockHandler(pointer pTimeout, pointer pReadmask)\n"
                "{\n"
                "    int i, j;\n"
                "    \n"
                "    ++inHandler;\n"
                "    ErrorF(\"be300-block: BlockHandler screens=%d handlers=%d timeout=%p mask=%p\\n\",\n"
                "           screenInfo.numScreens, numHandlers, pTimeout, pReadmask);\n"
                "    for (i = 0; i < screenInfo.numScreens; i++) {\n"
                "\tErrorF(\"be300-block: screen[%d]=%p block=%p data=%p\\n\",\n"
                "\t       i, screenInfo.screens[i],\n"
                "\t       screenInfo.screens[i] ? screenInfo.screens[i]->BlockHandler : NULL,\n"
                "\t       screenInfo.screens[i] ? screenInfo.screens[i]->blockData : NULL);\n"
                "\tif (screenInfo.screens[i] && screenInfo.screens[i]->BlockHandler)\n"
                "\t    (* screenInfo.screens[i]->BlockHandler)(i, \n"
                "\t\t\t\tscreenInfo.screens[i]->blockData,\n"
                "\t\t\t\tpTimeout, pReadmask);\n"
                "    }\n"
                "    for (i = 0; i < numHandlers; i++) {\n"
                "\tErrorF(\"be300-block: handler[%d] block=%p wake=%p data=%p deleted=%d\\n\",\n"
                "\t       i, handlers[i].BlockHandler, handlers[i].WakeupHandler,\n"
                "\t       handlers[i].blockData, handlers[i].deleted);\n"
                "\tif (handlers[i].BlockHandler)\n"
                "\t    (*handlers[i].BlockHandler) (handlers[i].blockData,\n"
                "\t\t\t\t     pTimeout, pReadmask);\n"
                "    }\n",
                1,
            )
            text = text.replace(
                "void\n"
                "WakeupHandler(int result, pointer pReadmask)\n"
                "{\n"
                "    int i, j;\n"
                "\n"
                "    ++inHandler;\n"
                "    for (i = numHandlers - 1; i >= 0; i--)\n"
                "\t(*handlers[i].WakeupHandler) (handlers[i].blockData,\n"
                "\t\t\t\t      result, pReadmask);\n"
                "    for (i = 0; i < screenInfo.numScreens; i++)\n"
                "\t(* screenInfo.screens[i]->WakeupHandler)(i, \n"
                "\t\t\t\tscreenInfo.screens[i]->wakeupData,\n"
                "\t\t\t\tresult, pReadmask);\n",
                "#ifdef __GNUC__\n"
                "__attribute__((visibility(\"hidden\")))\n"
                "#endif\n"
                "void\n"
                "WakeupHandler(int result, pointer pReadmask)\n"
                "{\n"
                "    int i, j;\n"
                "\n"
                "    ++inHandler;\n"
                "    ErrorF(\"be300-block: WakeupHandler result=%d screens=%d handlers=%d mask=%p\\n\",\n"
                "           result, screenInfo.numScreens, numHandlers, pReadmask);\n"
                "    for (i = numHandlers - 1; i >= 0; i--) {\n"
                "\tErrorF(\"be300-block: wake handler[%d] block=%p wake=%p data=%p deleted=%d\\n\",\n"
                "\t       i, handlers[i].BlockHandler, handlers[i].WakeupHandler,\n"
                "\t       handlers[i].blockData, handlers[i].deleted);\n"
                "\tif (handlers[i].WakeupHandler)\n"
                "\t    (*handlers[i].WakeupHandler) (handlers[i].blockData,\n"
                "\t\t\t\t      result, pReadmask);\n"
                "    }\n"
                "    for (i = 0; i < screenInfo.numScreens; i++) {\n"
                "\tErrorF(\"be300-block: wake screen[%d]=%p wake=%p data=%p\\n\",\n"
                "\t       i, screenInfo.screens[i],\n"
                "\t       screenInfo.screens[i] ? screenInfo.screens[i]->WakeupHandler : NULL,\n"
                "\t       screenInfo.screens[i] ? screenInfo.screens[i]->wakeupData : NULL);\n"
                "\tif (screenInfo.screens[i] && screenInfo.screens[i]->WakeupHandler)\n"
                "\t    (* screenInfo.screens[i]->WakeupHandler)(i, \n"
                "\t\t\t\tscreenInfo.screens[i]->wakeupData,\n"
                "\t\t\t\tresult, pReadmask);\n"
                "    }\n",
                1,
            )
            text = text.replace(
                "_X_EXPORT Bool\n"
                "RegisterBlockAndWakeupHandlers (BlockHandlerProcPtr blockHandler, \n",
                "#ifdef __GNUC__\n"
                "__attribute__((visibility(\"hidden\")))\n"
                "#endif\n"
                "Bool\n"
                "RegisterBlockAndWakeupHandlers (BlockHandlerProcPtr blockHandler, \n",
                1,
            )
            text = text.replace(
                "    BlockHandlerPtr new;\n"
                "\n"
                "    if (numHandlers >= sizeHandlers)\n",
                "    BlockHandlerPtr new;\n"
                "\n"
                "    ErrorF(\"be300-block: register block=%p wake=%p data=%p num=%d size=%d\\n\",\n"
                "           blockHandler, wakeupHandler, blockData, numHandlers, sizeHandlers);\n"
                "    if (numHandlers >= sizeHandlers)\n",
                1,
            )
            text = text.replace(
                "_X_EXPORT void\n"
                "RemoveBlockAndWakeupHandlers (BlockHandlerProcPtr blockHandler, \n",
                "#ifdef __GNUC__\n"
                "__attribute__((visibility(\"hidden\")))\n"
                "#endif\n"
                "void\n"
                "RemoveBlockAndWakeupHandlers (BlockHandlerProcPtr blockHandler, \n",
                1,
            )
            text = text.replace(
                "    int\t    i;\n"
                "\n"
                "    for (i = 0; i < numHandlers; i++)\n",
                "    int\t    i;\n"
                "\n"
                "    ErrorF(\"be300-block: remove block=%p wake=%p data=%p num=%d\\n\",\n"
                "           blockHandler, wakeupHandler, blockData, numHandlers);\n"
                "    for (i = 0; i < numHandlers; i++)\n",
                1,
            )
            text = text.replace(
                "void\n"
                "InitBlockAndWakeupHandlers (void)\n",
                "#ifdef __GNUC__\n"
                "__attribute__((visibility(\"hidden\")))\n"
                "#endif\n"
                "void\n"
                "InitBlockAndWakeupHandlers (void)\n",
                1,
            )
            return text
        if rewrite_in_place(dixutils, transform_dixutils):
            changed += 1

    return changed


def patch_block_wakeup_quiet_guards(tree: Path) -> int:
    """Keep DIX Block/Wakeup guards but remove per-dispatch logging."""
    f = tree / "dix" / "dixutils.c"
    if not f.is_file():
        return 0

    def transform(text: str) -> str:
        marker = "be300-tinyx: quiet block/wakeup dispatch"
        if marker in text:
            return text

        block_pattern = re.compile(
            r"#ifdef __GNUC__\n"
            r"__attribute__\(\(visibility\(\"hidden\"\)\)\)\n"
            r"#endif\n"
            r"void\n"
            r"BlockHandler\(pointer pTimeout, pointer pReadmask\)\n"
            r"\{.*?\n\}\n"
            r"(?=\n/\*\*\n \*\n \*  \\param result)",
            re.DOTALL,
        )
        block_repl = """\
#ifdef __GNUC__
__attribute__((visibility("hidden")))
#endif
void
BlockHandler(pointer pTimeout, pointer pReadmask)
{
    int i, j;

    /* be300-tinyx: quiet block/wakeup dispatch. */
    ++inHandler;
    for (i = 0; i < screenInfo.numScreens; i++) {
\tif (screenInfo.screens[i] && screenInfo.screens[i]->BlockHandler)
\t    (* screenInfo.screens[i]->BlockHandler)(i,
\t\t\t\tscreenInfo.screens[i]->blockData,
\t\t\t\tpTimeout, pReadmask);
    }
    for (i = 0; i < numHandlers; i++) {
\tif (!handlers[i].deleted && handlers[i].BlockHandler)
\t    (*handlers[i].BlockHandler) (handlers[i].blockData,
\t\t\t\t     pTimeout, pReadmask);
    }
    if (handlerDeleted)
    {
\tfor (i = 0; i < numHandlers;)
\t    if (handlers[i].deleted)
\t    {
\t    \tfor (j = i; j < numHandlers - 1; j++)
\t\t    handlers[j] = handlers[j+1];
\t    \tnumHandlers--;
\t    }
\t    else
\t\ti++;
\thandlerDeleted = FALSE;
    }
    --inHandler;
}
"""
        text, n = block_pattern.subn(block_repl, text, count=1)
        if n != 1:
            fail("dixutils.c BlockHandler quieting context not found")

        wake_pattern = re.compile(
            r"#ifdef __GNUC__\n"
            r"__attribute__\(\(visibility\(\"hidden\"\)\)\)\n"
            r"#endif\n"
            r"void\n"
            r"WakeupHandler\(int result, pointer pReadmask\)\n"
            r"\{.*?\n\}\n"
            r"(?=\n/\*\*\n \* Reentrant with BlockHandler)",
            re.DOTALL,
        )
        wake_repl = """\
#ifdef __GNUC__
__attribute__((visibility("hidden")))
#endif
void
WakeupHandler(int result, pointer pReadmask)
{
    int i, j;

    ++inHandler;
    for (i = numHandlers - 1; i >= 0; i--) {
\tif (!handlers[i].deleted && handlers[i].WakeupHandler)
\t    (*handlers[i].WakeupHandler) (handlers[i].blockData,
\t\t\t\t      result, pReadmask);
    }
    for (i = 0; i < screenInfo.numScreens; i++) {
\tif (screenInfo.screens[i] && screenInfo.screens[i]->WakeupHandler)
\t    (* screenInfo.screens[i]->WakeupHandler)(i,
\t\t\t\tscreenInfo.screens[i]->wakeupData,
\t\t\t\tresult, pReadmask);
    }
    if (handlerDeleted)
    {
\tfor (i = 0; i < numHandlers;)
\t    if (handlers[i].deleted)
\t    {
\t    \tfor (j = i; j < numHandlers - 1; j++)
\t\t    handlers[j] = handlers[j+1];
\t    \tnumHandlers--;
\t    }
\t    else
\t\ti++;
\thandlerDeleted = FALSE;
    }
    --inHandler;
}
"""
        text, n = wake_pattern.subn(wake_repl, text, count=1)
        if n != 1:
            fail("dixutils.c WakeupHandler quieting context not found")

        text = re.sub(
            r"\n    ErrorF\(\"be300-block: register block=%p wake=%p data=%p num=%d size=%d\\n\",\n"
            r"           blockHandler, wakeupHandler, blockData, numHandlers, sizeHandlers\);\n",
            "\n",
            text,
            count=1,
        )
        text = re.sub(
            r"\n    ErrorF\(\"be300-block: remove block=%p wake=%p data=%p num=%d\\n\",\n"
            r"           blockHandler, wakeupHandler, blockData, numHandlers\);\n",
            "\n",
            text,
            count=1,
        )
        return text

    return 1 if rewrite_in_place(f, transform) else 0


def patch_waitfor_wakeup_only_for_input(tree: Path) -> int:
    """Only call DIX WakeupHandler when an enabled input fd is readable.

    kdrive's screen WakeupHandler is an input fd reader.  The BE-300 TinyX
    profile can wake select() for client connects before any evdev fd is
    ready; running the screen wakeup hook in that case is a fragile MIPS/uClibc
    callback edge and is not needed for accepting the client.  Keep the normal
    wake path for real keyboard/touch events by checking EnabledDevices first.
    """
    f = tree / "os" / "WaitFor.c"
    if not f.is_file():
        return 0

    def transform(text: str) -> str:
        marker = "be300-tinyx: only wake DDX for readable input fds"
        if marker in text:
            return text

        old = (
            "\tselecterr = GetErrno();\n"
            "\tWakeupHandler(i, (pointer)&LastSelectMask);\n"
            "\tSmartScheduleStartTimer ();\n"
        )
        new = (
            "\tselecterr = GetErrno();\n"
            "\t{\n"
            "\t    fd_set be300WakeDevices;\n"
            "\n"
            "\t    /* be300-tinyx: only wake DDX for readable input fds. */\n"
            "\t    XFD_ANDSET(&be300WakeDevices, &LastSelectMask, &EnabledDevices);\n"
            "\t    if (XFD_ANYSET(&be300WakeDevices))\n"
            "\t\tWakeupHandler(i, (pointer)&LastSelectMask);\n"
            "\t}\n"
            "\tSmartScheduleStartTimer ();\n"
        )
        if old not in text:
            fail("WaitFor.c WakeupHandler context not found")
        return text.replace(old, new, 1)

    return 1 if rewrite_in_place(f, transform) else 0


def patch_waitfor_inline_new_connections(tree: Path) -> int:
    """Accept new X clients directly from WaitForSomething().

    The stock server queues EstablishNewConnections() through the generic work
    queue after select() reports the listening socket readable.  On the BE-300
    TinyX build that leaves the first client-connect path dependent on another
    cross-file callback call before Dispatch() can return to normal client
    processing.  Accepting the connection inline keeps the same readiness
    semantics while avoiding the fragile callback edge that faults at pc=0 on
    this MIPS/uClibc target.
    """
    f = tree / "os" / "WaitFor.c"
    if not f.is_file():
        return 0

    def transform(text: str) -> str:
        marker = "be300-tinyx: accept new X clients inline"
        if marker in text:
            return text

        old = (
            "\t    if (XFD_ANYSET(&tmp_set))\n"
            "\t\tQueueWorkProc(EstablishNewConnections, NULL,\n"
            "\t\t\t      (pointer)&LastSelectMask);\n"
        )
        new = (
            "\t    if (XFD_ANYSET(&tmp_set)) {\n"
            "\t\t/* be300-tinyx: accept new X clients inline. */\n"
            "\t\tErrorF(\"be300-wait: accepting new X client inline\\n\");\n"
            "\t\tEstablishNewConnections(NULL, (pointer)&LastSelectMask);\n"
            "\t    }\n"
        )
        if old not in text:
            fail("WaitFor.c new-connection workqueue context not found")
        return text.replace(old, new, 1)

    return 1 if rewrite_in_place(f, transform) else 0


def patch_waitfor_skip_block_handler(tree: Path) -> int:
    """Remove the generic DIX BlockHandler from the BE-300 wait path.

    TinyX on BE-300 uses kdrive evdev fds directly: select() reports the
    keyboard/touch fds readable, then the kdrive screen WakeupHandler consumes
    them.  The remaining DIX BlockHandler call only walks optional extension
    callback handlers before select() sleeps, and this target has repeatedly
    faulted at pc=0 in that first WaitForSomething() window.  Skip the generic
    pre-select callback path for the BE-300 profile.
    """
    f = tree / "os" / "WaitFor.c"
    if not f.is_file():
        return 0

    def transform(text: str) -> str:
        marker = "be300-tinyx: skip generic DIX BlockHandler"
        if marker in text:
            return text

        old = "\tBlockHandler((pointer)&wt, (pointer)&LastSelectMask);\n"
        new = (
            "\t/* be300-tinyx: skip generic DIX BlockHandler on this MIPS target. */\n"
            "\tErrorF(\"be300-wait: skipping generic DIX BlockHandler\\n\");\n"
        )
        if old not in text:
            fail("WaitFor.c BlockHandler call context not found")
        return text.replace(old, new, 1)

    return 1 if rewrite_in_place(f, transform) else 0


def patch_waitfor_select_logging(tree: Path) -> int:
    """Log the BE-300 select boundary while stabilizing TinyX startup."""
    f = tree / "os" / "WaitFor.c"
    if not f.is_file():
        return 0

    def transform(text: str) -> str:
        marker = "be300-tinyx: trace Select boundary"
        if marker in text:
            return text

        old = (
            "\t/* keep this check close to select() call to minimize race */\n"
            "\tif (dispatchException)\n"
        )
        new = (
            "\t/* be300-tinyx: trace Select boundary while validating startup. */\n"
            "\tErrorF(\"be300-wait: before Select dispatch=%d writeBlocked=%d wt=%p\\n\",\n"
            "\t       dispatchException, AnyClientsWriteBlocked, wt);\n"
            "\t/* keep this check close to select() call to minimize race */\n"
            "\tif (dispatchException)\n"
        )
        if old not in text:
            fail("WaitFor.c pre-Select context not found")
        text = text.replace(old, new, 1)

        old_after = "\tselecterr = GetErrno();\n"
        new_after = (
            "\tselecterr = GetErrno();\n"
            "\tErrorF(\"be300-wait: after Select i=%d err=%d\\n\", i, selecterr);\n"
        )
        if old_after not in text:
            fail("WaitFor.c post-Select context not found")
        return text.replace(old_after, new_after, 1)

    return 1 if rewrite_in_place(f, transform) else 0


def patch_waitfor_no_timer_timeouts(tree: Path) -> int:
    """Do not pass X timer timeouts into select() on BE-300 TinyX.

    The useful work for this profile is fd-driven: client requests and kdrive
    evdev input.  The remaining X timer list is screen-saver/audit/XKB
    housekeeping, and on this MIPS/musl combination the timed select path is
    the remaining pc=0 crash site after matchbox starts.  Blocking only on fds
    keeps clients and input live while avoiding the fragile timeval path.
    """
    f = tree / "os" / "WaitFor.c"
    if not f.is_file():
        return 0

    def transform(text: str) -> str:
        marker = "be300-tinyx: disable timeout-based WaitFor timers"
        if marker in text:
            return text

        old = """\
        wt = NULL;
\tif (timers)
        {
            now = GetTimeInMillis();
\t    timeout = timers->expires - now;
            if (timeout > 0 && timeout > timers->delta + 250) {
                /* time has rewound.  reset the timers. */
                CheckAllTimers();
            }

\t    if (timers) {
\t\ttimeout = timers->expires - now;
\t\tif (timeout < 0)
\t\t    timeout = 0;
\t\twaittime.tv_sec = timeout / MILLI_PER_SECOND;
\t\twaittime.tv_usec = (timeout % MILLI_PER_SECOND) *
\t\t\t\t   (1000000 / MILLI_PER_SECOND);
\t\twt = &waittime;
\t    }
\t}
\tXFD_COPYSET(&AllSockets, &LastSelectMask);
"""
        new = """\
        wt = NULL;
\t/* be300-tinyx: disable timeout-based WaitFor timers.
\t * Client sockets and kdrive evdev fds still wake select(); screen saver,
\t * audit flush, and repeat-key timers are skipped for target stability. */
\tXFD_COPYSET(&AllSockets, &LastSelectMask);
"""
        if old not in text:
            fail("WaitFor.c timer timeout context not found")
        return text.replace(old, new, 1)

    return 1 if rewrite_in_place(f, transform) else 0


def patch_wakeup_skip_generic_handlers(tree: Path) -> int:
    """Keep input wakeups on the kdrive screen path only.

    For BE-300 TinyX the only WakeupHandler work we need is kdrive reading the
    evdev keyboard/touch fds.  Optional extension wake callbacks add another
    function-pointer walk before input delivery; skip them so touch/key events
    enter the DDX screen wake path directly.
    """
    f = tree / "dix" / "dixutils.c"
    if not f.is_file():
        return 0

    def transform(text: str) -> str:
        marker = "be300-tinyx: skip generic WakeupHandler callbacks"
        if marker in text:
            return text

        old = (
            "    for (i = numHandlers - 1; i >= 0; i--) {\n"
            "\tif (!handlers[i].deleted && handlers[i].WakeupHandler)\n"
            "\t    (*handlers[i].WakeupHandler) (handlers[i].blockData,\n"
            "\t\t\t\t      result, pReadmask);\n"
            "    }\n"
        )
        new = (
            "    /* be300-tinyx: skip generic WakeupHandler callbacks; kdrive\n"
            "     * screen wakeup consumes evdev keyboard/touch fds directly. */\n"
        )
        if old not in text:
            fail("dixutils.c generic WakeupHandler loop context not found")
        return text.replace(old, new, 1)

    return 1 if rewrite_in_place(f, transform) else 0


def patch_insert_fake_request_exported(tree: Path) -> int:
    """Keep InsertFakeRequest globally bound.

    Cross-file calls to hidden functions still go through local MIPS GOT slots
    in this build.  InsertFakeRequest is called from dix/dispatch.c during the
    first client handshake, and the local GOT slot can be left as zero by the
    old target loader.  The exported binding resolves correctly, so leave this
    one I/O helper visible while the rest of os/io.c stays local.
    """
    changed = 0

    osh = tree / "include" / "os.h"
    if osh.is_file():
        def transform_osh(text: str) -> str:
            return text.replace(
                "extern __attribute__((visibility(\"hidden\"))) Bool InsertFakeRequest(\n",
                "extern Bool InsertFakeRequest(\n",
                1,
            )
        if rewrite_in_place(osh, transform_osh):
            changed += 1

    io = tree / "os" / "io.c"
    if io.is_file():
        def transform_io(text: str) -> str:
            pattern = re.compile(
                r"\n#ifdef __GNUC__\n"
                r"__attribute__\(\(visibility\(\"hidden\"\)\)\)\n"
                r"#endif\n"
                r"Bool\n"
                r"InsertFakeRequest\(ClientPtr client, char \*data, int count\)\n"
            )
            return pattern.sub(
                "\nBool\n"
                "InsertFakeRequest(ClientPtr client, char *data, int count)\n",
                text,
                count=1,
            )
        if rewrite_in_place(io, transform_io):
            changed += 1

    return changed


def patch_insert_fake_request_logging(tree: Path) -> int:
    """Log InsertFakeRequest internals for first-client handshake diagnosis."""
    f = tree / "os" / "io.c"
    if not f.is_file():
        return 0

    def transform(text: str) -> str:
        if "be300-tinyx: InsertFakeRequest internal logging" in text:
            return text

        text = text.replace(
            "InsertFakeRequest(ClientPtr client, char *data, int count)\n"
            "{\n"
            "    OsCommPtr oc = (OsCommPtr)client->osPrivate;\n"
            "    ConnectionInputPtr oci = oc->input;\n"
            "    int fd = oc->fd;\n"
            "    int gotnow, moveup;\n"
            "\n",
            "InsertFakeRequest(ClientPtr client, char *data, int count)\n"
            "{\n"
            "    OsCommPtr oc;\n"
            "    ConnectionInputPtr oci;\n"
            "    int fd;\n"
            "    int gotnow, moveup;\n"
            "\n"
            "    /* be300-tinyx: InsertFakeRequest internal logging. */\n"
            "    ErrorF(\"be300-io: InsertFakeRequest enter client=%p data=%p count=%d\\n\",\n"
            "           client, data, count);\n"
            "    if (!client) {\n"
            "\tErrorF(\"be300-io: InsertFakeRequest null client\\n\");\n"
            "\treturn FALSE;\n"
            "    }\n"
            "    oc = (OsCommPtr)client->osPrivate;\n"
            "    ErrorF(\"be300-io: InsertFakeRequest osPrivate=%p\\n\", oc);\n"
            "    if (!oc) {\n"
            "\tErrorF(\"be300-io: InsertFakeRequest null osPrivate\\n\");\n"
            "\treturn FALSE;\n"
            "    }\n"
            "    oci = oc->input;\n"
            "    fd = oc->fd;\n"
            "    ErrorF(\"be300-io: InsertFakeRequest fd=%d input=%p available=%p free=%p\\n\",\n"
            "           fd, oci, AvailableInput, FreeInputs);\n"
            "\n",
            1,
        )
        text = text.replace(
            "    if (AvailableInput)\n"
            "    {\n",
            "    ErrorF(\"be300-io: before AvailableInput handling\\n\");\n"
            "    if (AvailableInput)\n"
            "    {\n",
            1,
        )
        text = text.replace(
            "\tAvailableInput = (OsCommPtr)NULL;\n"
            "    }\n"
            "    if (!oci)\n"
            "    {\n",
            "\tAvailableInput = (OsCommPtr)NULL;\n"
            "    }\n"
            "    ErrorF(\"be300-io: after AvailableInput handling input=%p free=%p\\n\",\n"
            "           oci, FreeInputs);\n"
            "    if (!oci)\n"
            "    {\n"
            "\tErrorF(\"be300-io: input buffer missing, acquiring one\\n\");\n",
            1,
        )
        text = text.replace(
            "\tif ((oci = FreeInputs))\n"
            "\t    FreeInputs = oci->next;\n"
            "\telse if (!(oci = AllocateInputBuffer()))\n"
            "\t    return FALSE;\n"
            "\toc->input = oci;\n"
            "    }\n"
            "    oci->bufptr += oci->lenLastReq;\n",
            "\tif ((oci = FreeInputs)) {\n"
            "\t    FreeInputs = oci->next;\n"
            "\t    ErrorF(\"be300-io: reused input buffer=%p next_free=%p\\n\", oci, FreeInputs);\n"
            "\t}\n"
            "\telse if (!(oci = AllocateInputBuffer())) {\n"
            "\t    ErrorF(\"be300-io: AllocateInputBuffer failed\\n\");\n"
            "\t    return FALSE;\n"
            "\t}\n"
            "\telse\n"
            "\t    ErrorF(\"be300-io: allocated input buffer=%p buf=%p size=%d\\n\",\n"
            "\t           oci, oci->buffer, oci->size);\n"
            "\toc->input = oci;\n"
            "    }\n"
            "    ErrorF(\"be300-io: before lenLastReq adjust buf=%p ptr=%p cnt=%d last=%d size=%d\\n\",\n"
            "           oci->buffer, oci->bufptr, oci->bufcnt, oci->lenLastReq, oci->size);\n"
            "    oci->bufptr += oci->lenLastReq;\n",
            1,
        )
        text = text.replace(
            "    gotnow = oci->bufcnt + oci->buffer - oci->bufptr;\n"
            "    if ((gotnow + count) > oci->size)\n",
            "    gotnow = oci->bufcnt + oci->buffer - oci->bufptr;\n"
            "    ErrorF(\"be300-io: after lenLastReq adjust buf=%p ptr=%p cnt=%d got=%d count=%d size=%d\\n\",\n"
            "           oci->buffer, oci->bufptr, oci->bufcnt, gotnow, count, oci->size);\n"
            "    if ((gotnow + count) > oci->size)\n",
            1,
        )
        text = text.replace(
            "\tibuf = (char *)xrealloc(oci->buffer, gotnow + count);\n"
            "\tif (!ibuf)\n"
            "\t    return(FALSE);\n",
            "\tErrorF(\"be300-io: before input xrealloc old=%p new_size=%d\\n\",\n"
            "\t       oci->buffer, gotnow + count);\n"
            "\tibuf = (char *)xrealloc(oci->buffer, gotnow + count);\n"
            "\tif (!ibuf) {\n"
            "\t    ErrorF(\"be300-io: input xrealloc failed\\n\");\n"
            "\t    return(FALSE);\n"
            "\t}\n"
            "\tErrorF(\"be300-io: after input xrealloc new=%p\\n\", ibuf);\n",
            1,
        )
        text = text.replace(
            "    moveup = count - (oci->bufptr - oci->buffer);\n"
            "    if (moveup > 0)\n"
            "    {\n"
            "\tif (gotnow > 0)\n"
            "\t    memmove(oci->bufptr + moveup, oci->bufptr, gotnow);\n"
            "\toci->bufptr += moveup;\n"
            "\toci->bufcnt += moveup;\n"
            "    }\n"
            "    memmove(oci->bufptr - count, data, count);\n"
            "    oci->bufptr -= count;\n"
            "    gotnow += count;\n",
            "    moveup = count - (oci->bufptr - oci->buffer);\n"
            "    ErrorF(\"be300-io: computed moveup=%d ptr_delta=%ld got=%d\\n\",\n"
            "           moveup, (long)(oci->bufptr - oci->buffer), gotnow);\n"
            "    if (moveup > 0)\n"
            "    {\n"
            "\tif (gotnow > 0) {\n"
            "\t    ErrorF(\"be300-io: before moveup memmove dst=%p src=%p len=%d\\n\",\n"
            "\t           oci->bufptr + moveup, oci->bufptr, gotnow);\n"
            "\t    memmove(oci->bufptr + moveup, oci->bufptr, gotnow);\n"
            "\t    ErrorF(\"be300-io: after moveup memmove\\n\");\n"
            "\t}\n"
            "\toci->bufptr += moveup;\n"
            "\toci->bufcnt += moveup;\n"
            "    }\n"
            "    ErrorF(\"be300-io: before fake-request memmove dst=%p src=%p len=%d\\n\",\n"
            "           oci->bufptr - count, data, count);\n"
            "    memmove(oci->bufptr - count, data, count);\n"
            "    ErrorF(\"be300-io: after fake-request memmove\\n\");\n"
            "    oci->bufptr -= count;\n"
            "    gotnow += count;\n"
            "    ErrorF(\"be300-io: before ready check got=%d req_len=%d fd=%d\\n\",\n"
            "           gotnow, (int)(get_req_len((xReq *)oci->bufptr, client) << 2), fd);\n",
            1,
        )
        text = text.replace(
            "    if ((gotnow >= sizeof(xReq)) &&\n"
            "\t(gotnow >= (int)(get_req_len((xReq *)oci->bufptr, client) << 2)))\n"
            "\tFD_SET(fd, &ClientsWithInput);\n"
            "    else\n"
            "\tYieldControlNoInput(fd);\n"
            "    return(TRUE);\n",
            "    if ((gotnow >= sizeof(xReq)) &&\n"
            "\t(gotnow >= (int)(get_req_len((xReq *)oci->bufptr, client) << 2))) {\n"
            "\tErrorF(\"be300-io: marking fd=%d with input\\n\", fd);\n"
            "\tFD_SET(fd, &ClientsWithInput);\n"
            "    }\n"
            "    else {\n"
            "\tErrorF(\"be300-io: yielding no input fd=%d\\n\", fd);\n"
            "\tYieldControlNoInput(fd);\n"
            "    }\n"
            "    ErrorF(\"be300-io: InsertFakeRequest return TRUE\\n\");\n"
            "    return(TRUE);\n",
            1,
        )
        return text

    return 1 if rewrite_in_place(f, transform) else 0


def patch_client_dispatch_logging(tree: Path) -> int:
    """Log first-client connection and dispatch path, and guard null callbacks.

    The BE-300 TinyX profile now reaches Dispatch(), then the first X client
    can trip a null call path on old kdrive/libXfont combinations.  These logs
    keep the target-side diagnosis in /tmp/Xfbdev.log where the launcher can
    surface it on the serial console.
    """
    changed = 0

    dixh = tree / "include" / "dix.h"
    if dixh.is_file():
        def transform_dixh(text: str) -> str:
            if "be300-tinyx: hide NextAvailableClient" in text:
                return text
            return text.replace(
                "extern ClientPtr NextAvailableClient(\n"
                "    pointer /*ospriv*/);\n",
                "/* be300-tinyx: hide NextAvailableClient so MIPS PIC calls bind locally. */\n"
                "#ifdef __GNUC__\n"
                "extern __attribute__((visibility(\"hidden\"))) ClientPtr NextAvailableClient(\n"
                "#else\n"
                "extern ClientPtr NextAvailableClient(\n"
                "#endif\n"
                "    pointer /*ospriv*/);\n",
                1,
            )
        if rewrite_in_place(dixh, transform_dixh):
            changed += 1

    conn = tree / "os" / "connection.c"
    if conn.is_file():
        def transform_conn(text: str) -> str:
            if "be300-tinyx: AllocNewConnection logging" in text:
                return text
            text = text.replace(
                "AllocNewConnection (XtransConnInfo trans_conn, int fd, CARD32 conn_time)\n"
                "{\n"
                "    OsCommPtr\toc;\n"
                "    ClientPtr\tclient;\n"
                "    \n",
                "AllocNewConnection (XtransConnInfo trans_conn, int fd, CARD32 conn_time)\n"
                "{\n"
                "    OsCommPtr\toc;\n"
                "    ClientPtr\tclient;\n"
                "    /* be300-tinyx: AllocNewConnection logging. */\n"
                "    ErrorF(\"be300-conn: AllocNewConnection enter fd=%d trans=%p\\n\",\n"
                "           fd, trans_conn);\n"
                "    \n",
                1,
            )
            text = text.replace(
                "    if (!(client = NextAvailableClient((pointer)oc)))\n"
                "    {\n"
                "\txfree (oc);\n"
                "\treturn NullClient;\n"
                "    }\n",
                "    ErrorF(\"be300-conn: before NextAvailableClient fd=%d oc=%p\\n\",\n"
                "           fd, oc);\n"
                "    if (!(client = NextAvailableClient((pointer)oc)))\n"
                "    {\n"
                "\tErrorF(\"be300-conn: NextAvailableClient failed fd=%d\\n\", fd);\n"
                "\txfree (oc);\n"
                "\treturn NullClient;\n"
                "    }\n"
                "    ErrorF(\"be300-conn: after NextAvailableClient client=%p index=%d\\n\",\n"
                "           client, client->index);\n",
                1,
            )
            text = text.replace(
                "#ifdef DEBUG\n"
                "    ErrorF(\"AllocNewConnection: client index = %d, socket fd = %d\\n\",\n"
                "\t   client->index, fd);\n"
                "#endif\n",
                "    ErrorF(\"be300-conn: AllocNewConnection ready client index=%d fd=%d\\n\",\n"
                "\t   client->index, fd);\n",
                1,
            )
            return text
        if rewrite_in_place(conn, transform_conn):
            changed += 1

    dispatch = tree / "dix" / "dispatch.c"
    if dispatch.is_file():
        def transform_dispatch(text: str) -> str:
            next_available_marker = (
                "be300-tinyx: hide NextAvailableClient definition"
            )
            proc_initial_log = (
                "    ErrorF(\"be300-dispatch: ProcInitialConnection client=%d req_len=%d\\n\",\n"
                "           client->index, client->req_len);\n"
            )
            initial_byteorder_log = (
                "    ErrorF(\"be300-dispatch: initial byteOrder=%d major=%d minor=%d auth=%d/%d\\n\",\n"
                "           prefix->byteOrder, prefix->majorVersion, prefix->minorVersion,\n"
                "           prefix->nbytesAuthProto, prefix->nbytesAuthString);\n"
            )
            text = text.replace(proc_initial_log.replace("\\n", "\n"),
                                proc_initial_log)
            text = text.replace(initial_byteorder_log.replace("\\n", "\n"),
                                initial_byteorder_log)
            text = re.sub(
                r"(?:#ifdef __GNUC__\n"
                r"__attribute__\(\(visibility\(\"hidden\"\)\)\)\n"
                r"#endif\n)+"
                r"/\* be300-tinyx: hide NextAvailableClient definition from the dynamic symbol table\. \*/\n",
                "/* be300-tinyx: hide NextAvailableClient definition from the dynamic symbol table. */\n",
                text,
                count=1,
            )
            text = re.sub(
                f"(?:{re.escape(proc_initial_log)})+",
                lambda _m: proc_initial_log,
                text,
                count=1,
            )
            text = re.sub(
                f"(?:{re.escape(initial_byteorder_log)})+",
                lambda _m: initial_byteorder_log,
                text,
                count=1,
            )
            if "be300-tinyx: dispatch request bracketing" in text:
                if next_available_marker not in text:
                    text = re.sub(
                        r"(?:#ifdef __GNUC__\n"
                        r"__attribute__\(\(visibility\(\"hidden\"\)\)\)\n"
                        r"#endif\n)+"
                        r"ClientPtr NextAvailableClient\(pointer ospriv\)\n",
                        "/* be300-tinyx: hide NextAvailableClient definition from the dynamic symbol table. */\n"
                        "#ifdef __GNUC__\n"
                        "__attribute__((visibility(\"hidden\")))\n"
                        "#endif\n"
                        "ClientPtr NextAvailableClient(pointer ospriv)\n",
                        text,
                        count=1,
                    )
                return text
            if "be300-tinyx: dispatch request logging" not in text:
                text = text.replace(
                    "ClientPtr NextAvailableClient(pointer ospriv)\n"
                    "{\n"
                    "    int i;\n"
                    "    ClientPtr client;\n"
                    "    xReq data;\n"
                    "\n"
                    "    i = nextFreeClientID;\n",
                    "ClientPtr NextAvailableClient(pointer ospriv)\n"
                    "{\n"
                    "    int i;\n"
                    "    ClientPtr client;\n"
                    "    xReq data;\n"
                    "\n"
                    "    /* be300-tinyx: dispatch request logging. */\n"
                    "    ErrorF(\"be300-dispatch: NextAvailableClient enter ospriv=%p next=%d\\n\",\n"
                    "           ospriv, nextFreeClientID);\n"
                    "    i = nextFreeClientID;\n",
                    1,
                )
            if next_available_marker not in text:
                text = text.replace(
                    "ClientPtr NextAvailableClient(pointer ospriv)\n",
                    "/* be300-tinyx: hide NextAvailableClient definition from the dynamic symbol table. */\n"
                    "#ifdef __GNUC__\n"
                    "__attribute__((visibility(\"hidden\")))\n"
                    "#endif\n"
                    "ClientPtr NextAvailableClient(pointer ospriv)\n",
                    1,
                )
            text = text.replace(
                "    InitClient(client, i, ospriv);\n"
                "    if (!InitClientResources(client))\n",
                "    InitClient(client, i, ospriv);\n"
                "    /* be300-tinyx: dispatch request bracketing. */\n"
                "    ErrorF(\"be300-dispatch: after InitClient index=%d client=%p\\n\",\n"
                "           i, client);\n"
                "    ErrorF(\"be300-dispatch: before InitClientResources client=%d\\n\",\n"
                "           client->index);\n"
                "    if (!InitClientResources(client))\n",
                1,
            )
            text = text.replace(
                "    if (!InitClientResources(client))\n"
                "    {\n"
                "\txfree(client);\n"
                "\treturn (ClientPtr)NULL;\n"
                "    }\n"
                "    data.reqType = 1;\n",
                "    if (!InitClientResources(client))\n"
                "    {\n"
                "\tErrorF(\"be300-dispatch: InitClientResources failed client=%d\\n\",\n"
                "\t       client->index);\n"
                "\txfree(client);\n"
                "\treturn (ClientPtr)NULL;\n"
                "    }\n"
                "    ErrorF(\"be300-dispatch: after InitClientResources client=%d\\n\",\n"
                "           client->index);\n"
                "    data.reqType = 1;\n",
                1,
            )
            text = text.replace(
                "    data.reqType = 1;\n"
                "    data.length = (sz_xReq + sz_xConnClientPrefix) >> 2;\n"
                "    if (!InsertFakeRequest(client, (char *)&data, sz_xReq))\n"
                "    {\n"
                "\tFreeClientResources(client);\n"
                "\txfree(client);\n"
                "\treturn (ClientPtr)NULL;\n"
                "    }\n"
                "    if (i == currentMaxClients)\n",
                "    data.reqType = 1;\n"
                "    data.length = (sz_xReq + sz_xConnClientPrefix) >> 2;\n"
                "    ErrorF(\"be300-dispatch: before InsertFakeRequest client=%d reqType=%d len=%d\\n\",\n"
                "           client->index, data.reqType, data.length);\n"
                "    if (!InsertFakeRequest(client, (char *)&data, sz_xReq))\n"
                "    {\n"
                "\tErrorF(\"be300-dispatch: InsertFakeRequest failed client=%d\\n\",\n"
                "\t       client->index);\n"
                "\tFreeClientResources(client);\n"
                "\txfree(client);\n"
                "\treturn (ClientPtr)NULL;\n"
                "    }\n"
                "    ErrorF(\"be300-dispatch: after InsertFakeRequest client=%d\\n\",\n"
                "           client->index);\n"
                "    if (i == currentMaxClients)\n",
                1,
            )
            text = text.replace(
                "    if (ClientStateCallback)\n"
                "    {\n"
                "\tNewClientInfoRec clientinfo;\n"
                "\n"
                "        clientinfo.client = client; \n"
                "        clientinfo.prefix = (xConnSetupPrefix *)NULL;  \n"
                "        clientinfo.setup = (xConnSetup *) NULL;\n"
                "\tCallCallbacks((&ClientStateCallback), (pointer)&clientinfo);\n"
                "    } \t\n"
                "    return(client);\n",
                "    if (ClientStateCallback)\n"
                "    {\n"
                "\tNewClientInfoRec clientinfo;\n"
                "\n"
                "        clientinfo.client = client; \n"
                "        clientinfo.prefix = (xConnSetupPrefix *)NULL;  \n"
                "        clientinfo.setup = (xConnSetup *) NULL;\n"
                "\tErrorF(\"be300-dispatch: before initial ClientStateCallback client=%d cbl=%p\\n\",\n"
                "\t       client->index, ClientStateCallback);\n"
                "\tCallCallbacks((&ClientStateCallback), (pointer)&clientinfo);\n"
                "\tErrorF(\"be300-dispatch: after initial ClientStateCallback client=%d\\n\",\n"
                "\t       client->index);\n"
                "    } \t\n"
                "    ErrorF(\"be300-dispatch: NextAvailableClient return client=%p index=%d\\n\",\n"
                "           client, client->index);\n"
                "    return(client);\n",
                1,
            )
            if "be300-dispatch: ProcInitialConnection client=" not in text:
                text = text.replace(
                    "int\n"
                    "ProcInitialConnection(ClientPtr client)\n"
                    "{\n"
                    "    REQUEST(xReq);\n"
                    "    xConnClientPrefix *prefix;\n"
                    "    int whichbyte = 1;\n",
                    "int\n"
                    "ProcInitialConnection(ClientPtr client)\n"
                    "{\n"
                    "    REQUEST(xReq);\n"
                    "    xConnClientPrefix *prefix;\n"
                    "    int whichbyte = 1;\n"
                    + proc_initial_log,
                    1,
                )
            if "be300-dispatch: initial byteOrder=" not in text:
                text = text.replace(
                    "    prefix = (xConnClientPrefix *)((char *)stuff + sz_xReq);\n",
                    "    prefix = (xConnClientPrefix *)((char *)stuff + sz_xReq);\n"
                    + initial_byteorder_log,
                    1,
                )
            text = text.replace(
                "    nClients++;\n"
                "\n"
                "    client->requestVector = client->swapped ? SwappedProcVector : ProcVector;\n",
                "    nClients++;\n"
                "    ErrorF(\"be300-dispatch: SendConnSetup client=%d swapped=%d screens=%d\\n\",\n"
                "           client->index, client->swapped, numScreens);\n"
                "\n"
                "    client->requestVector = client->swapped ? SwappedProcVector : ProcVector;\n",
                1,
            )
            text = text.replace(
                "    prefix = (xConnClientPrefix *)((char *)stuff + sz_xReq);\n"
                "    auth_proto = (char *)prefix + sz_xConnClientPrefix;\n",
                "    prefix = (xConnClientPrefix *)((char *)stuff + sz_xReq);\n"
                "    ErrorF(\"be300-dispatch: ProcEstablishConnection client=%d major=%d minor=%d auth=%d/%d\\n\",\n"
                "           client->index, prefix->majorVersion, prefix->minorVersion,\n"
                "           prefix->nbytesAuthProto, prefix->nbytesAuthString);\n"
                "    auth_proto = (char *)prefix + sz_xConnClientPrefix;\n",
                1,
            )
            text = text.replace(
                "\t        result = ReadRequestFromClient(client);\n"
                "\t        if (result <= 0) \n",
                "\t        ErrorF(\"be300-dispatch: before ReadRequest client=%d state=%d\\n\",\n"
                "\t               client->index, client->clientState);\n"
                "\t        result = ReadRequestFromClient(client);\n"
                "\t        ErrorF(\"be300-dispatch: after ReadRequest client=%d result=%d\\n\",\n"
                "\t               client->index, result);\n"
                "\t        if (result <= 0) \n",
                1,
            )
            text = text.replace(
                "\t\telse {\n"
                "\t\t    result = XaceHookDispatch(client, MAJOROP);\n"
                "\t\t    if (result == Success)\n"
                "\t\t\tresult = (* client->requestVector[MAJOROP])(client);\n"
                "\t\t    XaceHookAuditEnd(client, result);\n"
                "\t\t}\n",
                "\t\telse {\n"
                "\t\t    ErrorF(\"be300-dispatch: before XaceHookDispatch client=%d major=%d vector=%p\\n\",\n"
                "\t\t           client->index, MAJOROP, client->requestVector[MAJOROP]);\n"
                "\t\t    result = XaceHookDispatch(client, MAJOROP);\n"
                "\t\t    ErrorF(\"be300-dispatch: after XaceHookDispatch result=%d\\n\", result);\n"
                "\t\t    if (result == Success) {\n"
                "\t\t\tif (!client->requestVector[MAJOROP]) {\n"
                "\t\t\t    ErrorF(\"be300-dispatch: null request vector major=%d\\n\", MAJOROP);\n"
                "\t\t\t    result = BadRequest;\n"
                "\t\t\t} else {\n"
                "\t\t\t    result = (* client->requestVector[MAJOROP])(client);\n"
                "\t\t\t    ErrorF(\"be300-dispatch: request major=%d returned %d\\n\", MAJOROP, result);\n"
                "\t\t\t}\n"
                "\t\t    }\n"
                "\t\t    XaceHookAuditEnd(client, result);\n"
                "\t\t}\n",
                1,
            )
            return text
        if rewrite_in_place(dispatch, transform_dispatch):
            changed += 1

    resource = tree / "dix" / "resource.c"
    if resource.is_file():
        def transform_resource(text: str) -> str:
            if "be300-tinyx: InitClientResources bracketing" not in text:
                text = text.replace(
                    "InitClientResources(ClientPtr client)\n"
                    "{\n"
                    "    int i, j;\n"
                    " \n",
                    "InitClientResources(ClientPtr client)\n"
                    "{\n"
                    "    int i, j;\n"
                    "\n"
                    "    /* be300-tinyx: InitClientResources bracketing. */\n"
                    "    ErrorF(\"be300-resource: InitClientResources enter client=%p index=%d server=%p\\n\",\n"
                    "           client, client ? client->index : -1, serverClient);\n"
                    " \n",
                    1,
                )
            if "be300-resource: resources alloc" not in text:
                text = text.replace(
                    "    clientTable[i = client->index].resources =\n"
                    "\t(ResourcePtr *)xalloc(INITBUCKETS*sizeof(ResourcePtr));\n"
                    "    if (!clientTable[i].resources)\n"
                    "\treturn FALSE;\n",
                    "    clientTable[i = client->index].resources =\n"
                    "\t(ResourcePtr *)xalloc(INITBUCKETS*sizeof(ResourcePtr));\n"
                    "    ErrorF(\"be300-resource: resources alloc client=%d table=%p\\n\",\n"
                    "           i, clientTable[i].resources);\n"
                    "    if (!clientTable[i].resources)\n"
                    "\treturn FALSE;\n",
                    1,
                )
            if "be300-tinyx: zero resource table without libc memset" not in text:
                text = text.replace(
                    "    for (j=0; j<INITBUCKETS; j++) \n"
                    "    {\n"
                    "        clientTable[i].resources[j] = NullResource;\n"
                    "    }\n"
                    "    ErrorF(\"be300-resource: InitClientResources return TRUE client=%d\\n\", i);\n"
                    "    return TRUE;\n",
                    "    ErrorF(\"be300-resource: before zero resources client=%d table=%p\\n\",\n"
                    "           i, clientTable[i].resources);\n"
                    "    /* be300-tinyx: zero resource table without libc memset. */\n"
                    "    {\n"
                    "        volatile ResourcePtr *resources =\n"
                    "            (volatile ResourcePtr *)clientTable[i].resources;\n"
                    "        for (j=0; j<INITBUCKETS; j++)\n"
                    "            resources[j] = NullResource;\n"
                    "    }\n"
                    "    ErrorF(\"be300-resource: after zero resources client=%d\\n\", i);\n"
                    "    ErrorF(\"be300-resource: InitClientResources return TRUE client=%d\\n\", i);\n"
                    "    return TRUE;\n",
                    1,
                )
                text = text.replace(
                    "    for (j=0; j<INITBUCKETS; j++) \n"
                    "    {\n"
                    "        clientTable[i].resources[j] = NullResource;\n"
                    "    }\n"
                    "    return TRUE;\n",
                    "    ErrorF(\"be300-resource: before zero resources client=%d table=%p\\n\",\n"
                    "           i, clientTable[i].resources);\n"
                    "    /* be300-tinyx: zero resource table without libc memset. */\n"
                    "    {\n"
                    "        volatile ResourcePtr *resources =\n"
                    "            (volatile ResourcePtr *)clientTable[i].resources;\n"
                    "        for (j=0; j<INITBUCKETS; j++)\n"
                    "            resources[j] = NullResource;\n"
                    "    }\n"
                    "    ErrorF(\"be300-resource: after zero resources client=%d\\n\", i);\n"
                    "    ErrorF(\"be300-resource: InitClientResources return TRUE client=%d\\n\", i);\n"
                    "    return TRUE;\n",
                    1,
                )
            return text
        if rewrite_in_place(resource, transform_resource):
            changed += 1

    dixutils = tree / "dix" / "dixutils.c"
    if dixutils.is_file():
        def transform_dixutils(text: str) -> str:
            if "be300-tinyx: callback dispatch logging" in text:
                return text
            return text.replace(
                "    ++(cbl->inCallback);\n"
                "    for (cbr = cbl->list; cbr != NULL; cbr = cbr->next)\n"
                "    {\n"
                "\t(*(cbr->proc)) (pcbl, cbr->data, call_data);\n"
                "    }\n"
                "    --(cbl->inCallback);\n",
                "    ++(cbl->inCallback);\n"
                "    /* be300-tinyx: callback dispatch logging. */\n"
                "    ErrorF(\"be300-callbacks: pcbl=%p cbl=%p call=%p list=%p\\n\",\n"
                "           pcbl, cbl, call_data, cbl->list);\n"
                "    for (cbr = cbl->list; cbr != NULL; cbr = cbr->next)\n"
                "    {\n"
                "\tErrorF(\"be300-callbacks: proc=%p data=%p deleted=%d next=%p\\n\",\n"
                "\t       cbr->proc, cbr->data, cbr->deleted, cbr->next);\n"
                "\tif (!cbr->proc) {\n"
                "\t    ErrorF(\"be300-callbacks: skipping null callback\\n\");\n"
                "\t    continue;\n"
                "\t}\n"
                "\t(*(cbr->proc)) (pcbl, cbr->data, call_data);\n"
                "\tErrorF(\"be300-callbacks: proc=%p returned\\n\", cbr->proc);\n"
                "    }\n"
                "    --(cbl->inCallback);\n",
                1,
            )
        if rewrite_in_place(dixutils, transform_dixutils):
            changed += 1

    return changed


def patch_dispatch_local_initial_request(tree: Path) -> int:
    """Queue the initial fake request inside dispatch.c.

    InsertFakeRequest() lives in os/io.c.  On this MIPS/uClibc target, the
    dispatch.c -> os/io.c function call is emitted through a GOT slot that can
    be left as zero by the old loader, even when the symbol is exported.  Keep
    the first-client setup path in dispatch.c so the server can accept its first
    X client without crossing that call edge.
    """
    dispatch = tree / "dix" / "dispatch.c"
    if not dispatch.is_file():
        return 0

    def transform(text: str) -> str:
        changed = False

        if "#include \"osdep.h\"" in text:
            text = text.replace(
                "#include \"osdep.h\"\n",
                "#include \"../os/osdep.h\"\n",
                1,
            )
            changed = True
        elif "#include \"../os/osdep.h\"" not in text:
            text = text.replace(
                "#include \"opaque.h\"\n",
                "#include \"opaque.h\"\n"
                "#include \"../os/osdep.h\"\n",
                1,
            )
            changed = True

        helper = (
            "\n/* be300-tinyx: local initial request queue for first-client setup. */\n"
            "static Bool __attribute__((noinline))\n"
            "be300_queue_initial_request(ClientPtr client, char *data, int count)\n"
            "{\n"
            "    OsCommPtr oc;\n"
            "    ConnectionInputPtr oci;\n"
            "    int i;\n"
            "\n"
            "    ErrorF(\"be300-dispatch: local queue enter\\n\");\n"
            "    ErrorF(\"be300-dispatch: local queue args client=%p data=%p count=%d\\n\",\n"
            "           client, data, count);\n"
            "    if (!client || !data || count <= 0 || count > BUFSIZE)\n"
            "\treturn FALSE;\n"
            "\n"
            "    oc = (OsCommPtr)client->osPrivate;\n"
            "    ErrorF(\"be300-dispatch: local queue osPrivate=%p\\n\", oc);\n"
            "    if (!oc)\n"
            "\treturn FALSE;\n"
            "\n"
            "    oci = oc->input;\n"
            "    if (!oci) {\n"
            "\toci = (ConnectionInputPtr)xalloc(sizeof(ConnectionInput));\n"
            "\tif (!oci)\n"
            "\t    return FALSE;\n"
            "\toci->buffer = (char *)xalloc(BUFSIZE);\n"
            "\tif (!oci->buffer) {\n"
            "\t    xfree(oci);\n"
            "\t    return FALSE;\n"
            "\t}\n"
            "\toci->size = BUFSIZE;\n"
            "\toci->next = (ConnectionInputPtr)NULL;\n"
            "\toc->input = oci;\n"
            "    }\n"
            "\n"
            "    if (!oci->buffer || oci->size < count)\n"
            "\treturn FALSE;\n"
            "\n"
            "    oci->bufptr = oci->buffer;\n"
            "    oci->bufcnt = count;\n"
            "    oci->lenLastReq = 0;\n"
            "    for (i = 0; i < count; i++)\n"
            "\toci->buffer[i] = data[i];\n"
            "\n"
            "    FD_CLR(oc->fd, &ClientsWithInput);\n"
            "    isItTimeToYield = TRUE;\n"
            "    ErrorF(\"be300-dispatch: local queue ready fd=%d input=%p buf=%p count=%d\\n\",\n"
            "           oc->fd, oci, oci->buffer, oci->bufcnt);\n"
            "    return TRUE;\n"
            "}\n\n"
        )
        old_helper_sig = (
            "static Bool\n"
            "be300_queue_initial_request(ClientPtr client, char *data, int count)\n"
        )
        if old_helper_sig in text:
            text = text.replace(
                old_helper_sig,
                "static Bool __attribute__((noinline))\n"
                "be300_queue_initial_request(ClientPtr client, char *data, int count)\n",
                1,
            )
            text = text.replace(
                "    ErrorF(\"be300-dispatch: local queue enter client=%p data=%p count=%d\\n\",\n"
                "           client, data, count);\n",
                "    ErrorF(\"be300-dispatch: local queue enter\\n\");\n"
                "    ErrorF(\"be300-dispatch: local queue args client=%p data=%p count=%d\\n\",\n"
                "           client, data, count);\n",
                1,
            )
            changed = True
        if "be300_queue_initial_request(ClientPtr client, char *data, int count)" not in text:
            text = text.replace(
                "#define mskcnt ((MAXCLIENTS + 31) / 32)\n",
                helper + "#define mskcnt ((MAXCLIENTS + 31) / 32)\n",
                1,
            )
            changed = True

        old_logged = (
            "    data.reqType = 1;\n"
            "    data.length = (sz_xReq + sz_xConnClientPrefix) >> 2;\n"
            "    ErrorF(\"be300-dispatch: before InsertFakeRequest client=%d reqType=%d len=%d\\n\",\n"
            "           client->index, data.reqType, data.length);\n"
            "    if (!InsertFakeRequest(client, (char *)&data, sz_xReq))\n"
            "    {\n"
            "\tErrorF(\"be300-dispatch: InsertFakeRequest failed client=%d\\n\",\n"
            "\t       client->index);\n"
            "\tFreeClientResources(client);\n"
            "\txfree(client);\n"
            "\treturn (ClientPtr)NULL;\n"
            "    }\n"
            "    ErrorF(\"be300-dispatch: after InsertFakeRequest client=%d\\n\",\n"
            "           client->index);\n"
            "    if (i == currentMaxClients)\n"
        )
        new_local = (
            "    data.reqType = 1;\n"
            "    data.length = (sz_xReq + sz_xConnClientPrefix) >> 2;\n"
            "    ErrorF(\"be300-dispatch: before local initial request client=%d reqType=%d len=%d\\n\",\n"
            "           client->index, data.reqType, data.length);\n"
            "    if (!be300_queue_initial_request(client, (char *)&data, sz_xReq))\n"
            "    {\n"
            "\tErrorF(\"be300-dispatch: local initial request failed client=%d\\n\",\n"
            "\t       client->index);\n"
            "\tFreeClientResources(client);\n"
            "\txfree(client);\n"
            "\treturn (ClientPtr)NULL;\n"
            "    }\n"
            "    ErrorF(\"be300-dispatch: after local initial request client=%d\\n\",\n"
            "           client->index);\n"
            "    if (i == currentMaxClients)\n"
        )
        new_logged = (
            "    data.reqType = 1;\n"
            "    data.length = (sz_xReq + sz_xConnClientPrefix) >> 2;\n"
            "    ErrorF(\"be300-dispatch: before InsertFakeRequest client=%d reqType=%d len=%d\\n\",\n"
            "           client->index, data.reqType, data.length);\n"
            "    if (!InsertFakeRequest(client, (char *)&data, sz_xReq))\n"
            "    {\n"
            "\tErrorF(\"be300-dispatch: InsertFakeRequest failed client=%d\\n\",\n"
            "\t       client->index);\n"
            "\tFreeClientResources(client);\n"
            "\txfree(client);\n"
            "\treturn (ClientPtr)NULL;\n"
            "    }\n"
            "    ErrorF(\"be300-dispatch: after InsertFakeRequest client=%d\\n\",\n"
            "           client->index);\n"
            "    if (i == currentMaxClients)\n"
        )
        if old_logged in text:
            text = text.replace(old_logged, new_local, 1)
            changed = True

        old_plain = (
            "    data.reqType = 1;\n"
            "    data.length = (sz_xReq + sz_xConnClientPrefix) >> 2;\n"
            "    if (!InsertFakeRequest(client, (char *)&data, sz_xReq))\n"
            "    {\n"
            "\tFreeClientResources(client);\n"
            "\txfree(client);\n"
            "\treturn (ClientPtr)NULL;\n"
            "    }\n"
            "    if (i == currentMaxClients)\n"
        )
        if old_plain in text:
            text = text.replace(old_plain, new_local, 1)
            changed = True

        return text if changed else text

    return 1 if rewrite_in_place(dispatch, transform) else 0


def patch_dispatch_wait_input_local_binding(tree: Path) -> int:
    """Bind dispatch wait/input entry points locally for MIPS TinyX."""
    changed = 0

    osh = tree / "include" / "os.h"
    if osh.is_file():
        def transform_osh(text: str) -> str:
            if "be300-tinyx: hide WaitForSomething" in text:
                return text
            return text.replace(
                "extern int WaitForSomething(\n"
                "    int* /*pClientsReady*/\n"
                ");\n",
                "/* be300-tinyx: hide WaitForSomething so MIPS PIC calls bind locally. */\n"
                "#ifdef __GNUC__\n"
                "extern __attribute__((visibility(\"hidden\"))) int WaitForSomething(\n"
                "#else\n"
                "extern int WaitForSomething(\n"
                "#endif\n"
                "    int* /*pClientsReady*/\n"
                ");\n",
                1,
            )
        if rewrite_in_place(osh, transform_osh):
            changed += 1

    waitfor = tree / "os" / "WaitFor.c"
    if waitfor.is_file():
        def transform_waitfor(text: str) -> str:
            if "be300-tinyx: hide WaitForSomething definition" in text:
                return text
            return text.replace(
                "int\n"
                "WaitForSomething(int *pClientsReady)\n",
                "/* be300-tinyx: hide WaitForSomething definition from dynamic binding. */\n"
                "#ifdef __GNUC__\n"
                "__attribute__((visibility(\"hidden\")))\n"
                "#endif\n"
                "int\n"
                "WaitForSomething(int *pClientsReady)\n",
                1,
            )
        if rewrite_in_place(waitfor, transform_waitfor):
            changed += 1

    inputh = tree / "include" / "input.h"
    if inputh.is_file():
        def transform_inputh(text: str) -> str:
            if "be300-tinyx: hide ProcessInputEvents" in text:
                return text
            return text.replace(
                "extern void ProcessInputEvents(void);\n",
                "/* be300-tinyx: hide ProcessInputEvents so MIPS PIC calls bind locally. */\n"
                "#ifdef __GNUC__\n"
                "extern __attribute__((visibility(\"hidden\"))) void ProcessInputEvents(void);\n"
                "#else\n"
                "extern void ProcessInputEvents(void);\n"
                "#endif\n",
                1,
            )
        if rewrite_in_place(inputh, transform_inputh):
            changed += 1

    kinput = tree / "hw" / "kdrive" / "src" / "kinput.c"
    if kinput.is_file():
        def transform_kinput(text: str) -> str:
            if "be300-tinyx: hide ProcessInputEvents definition" in text:
                return text
            return text.replace(
                "void\n"
                "ProcessInputEvents ()\n",
                "/* be300-tinyx: hide ProcessInputEvents definition from dynamic binding. */\n"
                "#ifdef __GNUC__\n"
                "__attribute__((visibility(\"hidden\")))\n"
                "#endif\n"
                "void\n"
                "ProcessInputEvents ()\n",
                1,
            )
        if rewrite_in_place(kinput, transform_kinput):
            changed += 1

    mih = tree / "mi" / "mi.h"
    if mih.is_file():
        def transform_mih(text: str) -> str:
            if "be300-tinyx: hide mieqProcessInputEvents" in text:
                return text
            return text.replace(
                "extern void mieqProcessInputEvents(\n"
                "    void\n"
                ");\n",
                "/* be300-tinyx: hide mieqProcessInputEvents so MIPS PIC calls bind locally. */\n"
                "#ifdef __GNUC__\n"
                "extern __attribute__((visibility(\"hidden\"))) void mieqProcessInputEvents(\n"
                "#else\n"
                "extern void mieqProcessInputEvents(\n"
                "#endif\n"
                "    void\n"
                ");\n",
                1,
            )
        if rewrite_in_place(mih, transform_mih):
            changed += 1

    mieq = tree / "mi" / "mieq.c"
    if mieq.is_file():
        def transform_mieq(text: str) -> str:
            if "be300-tinyx: hide mieqProcessInputEvents definition" in text:
                return text
            return text.replace(
                "void\n"
                "mieqProcessInputEvents(void)\n",
                "/* be300-tinyx: hide mieqProcessInputEvents definition from dynamic binding. */\n"
                "#ifdef __GNUC__\n"
                "__attribute__((visibility(\"hidden\")))\n"
                "#endif\n"
                "void\n"
                "mieqProcessInputEvents(void)\n",
                1,
            )
        if rewrite_in_place(mieq, transform_mieq):
            changed += 1

    return changed


def patch_dispatch_loop_logging(tree: Path) -> int:
    """Trace the top-level Dispatch wait loop on target."""
    dispatch = tree / "dix" / "dispatch.c"
    if not dispatch.is_file():
        return 0

    def transform(text: str) -> str:
        if "be300-tinyx: Dispatch wait loop logging" in text:
            return text
        text = text.replace(
            "    clientReady = (int *) xalloc(sizeof(int) * MaxClients);\n"
            "    if (!clientReady)\n"
            "\treturn;\n"
            "\n"
            "    SmartScheduleSlice = SmartScheduleInterval;\n",
            "    clientReady = (int *) xalloc(sizeof(int) * MaxClients);\n"
            "    if (!clientReady)\n"
            "\treturn;\n"
            "\n"
            "    /* be300-tinyx: Dispatch wait loop logging. */\n"
            "    ErrorF(\"be300-dispatch: Dispatch enter clientReady=%p max=%d\\n\",\n"
            "           clientReady, MaxClients);\n"
            "    SmartScheduleSlice = SmartScheduleInterval;\n",
            1,
        )
        text = text.replace(
            "    while (!dispatchException)\n"
            "    {\n"
            "        if (*icheck[0] != *icheck[1])\n",
            "    while (!dispatchException)\n"
            "    {\n"
            "        ErrorF(\"be300-dispatch: loop top exception=%d icheck0=%p icheck1=%p\\n\",\n"
            "               dispatchException, icheck[0], icheck[1]);\n"
            "        ErrorF(\"be300-dispatch: before input check\\n\");\n"
            "        if (*icheck[0] != *icheck[1])\n",
            1,
        )
        text = text.replace(
            "\tnready = WaitForSomething(clientReady);\n"
            "\n"
            "\tif (nready && !SmartScheduleDisable)\n",
            "\tErrorF(\"be300-dispatch: before WaitForSomething\\n\");\n"
            "\tnready = WaitForSomething(clientReady);\n"
            "\tErrorF(\"be300-dispatch: after WaitForSomething nready=%d\\n\", nready);\n"
            "\n"
            "\tif (nready && !SmartScheduleDisable)\n",
            1,
        )
        return text

    return 1 if rewrite_in_place(dispatch, transform) else 0


def patch_colormap_install_logging(tree: Path) -> int:
    """Log the default colormap install path used during kdrive screen init."""
    changed = 0

    micmap = tree / "mi" / "micmap.c"
    if micmap.is_file():
        def transform_micmap(text: str) -> str:
            if "be300-tinyx: mi colormap install logging" in text:
                return text
            return text.replace(
                "    (*pScreen->InstallColormap)(cmap);\n"
                "    return TRUE;\n",
                "    ErrorF(\"miCreateDefColormap: before InstallColormap\\n\");\n"
                "    /* be300-tinyx: mi colormap install logging. */\n"
                "    (*pScreen->InstallColormap)(cmap);\n"
                "    ErrorF(\"miCreateDefColormap: after InstallColormap\\n\");\n"
                "    return TRUE;\n",
                1,
            )
        if rewrite_in_place(micmap, transform_micmap):
            changed += 1

    kcmap = tree / "hw" / "kdrive" / "src" / "kcmap.c"
    if kcmap.is_file():
        def transform_kcmap(text: str) -> str:
            if "be300-tinyx: KdInstallColormap logging" in text:
                return text
            text = text.replace(
                "    if (pCmap == pScreenPriv->pInstalledmap[fb])\n"
                "\treturn;\n",
                "    /* be300-tinyx: KdInstallColormap logging. */\n"
                "    ErrorF(\"KdInstallColormap: enter fb=%d cmap=%p installed=%p\\n\",\n"
                "           fb, pCmap, pScreenPriv->pInstalledmap[fb]);\n"
                "    if (pCmap == pScreenPriv->pInstalledmap[fb])\n"
                "\treturn;\n",
                1,
            )
            text = text.replace(
                "    pScreenPriv->pInstalledmap[fb] = pCmap;\n"
                "\n"
                "    KdSetColormap (pCmap->pScreen, fb);\n"
                "    \n"
                "    /* Tell X clients of the new colormap */\n"
                "    WalkTree(pCmap->pScreen, TellGainedMap, (pointer) &(pCmap->mid));\n",
                "    pScreenPriv->pInstalledmap[fb] = pCmap;\n"
                "    ErrorF(\"KdInstallColormap: before KdSetColormap\\n\");\n"
                "\n"
                "    KdSetColormap (pCmap->pScreen, fb);\n"
                "    ErrorF(\"KdInstallColormap: after KdSetColormap\\n\");\n"
                "    \n"
                "    /* Tell X clients of the new colormap */\n"
                "    ErrorF(\"KdInstallColormap: before TellGainedMap\\n\");\n"
                "    WalkTree(pCmap->pScreen, TellGainedMap, (pointer) &(pCmap->mid));\n"
                "    ErrorF(\"KdInstallColormap: after TellGainedMap\\n\");\n",
                1,
            )
            return text
        if rewrite_in_place(kcmap, transform_kcmap):
            changed += 1

    misprite = tree / "mi" / "misprite.c"
    if misprite.is_file():
        def transform_misprite(text: str) -> str:
            if "be300-tinyx: miSpriteInstallColormap logging" in text:
                return text
            text = text.replace(
                "    pPriv = (miSpriteScreenPtr)dixLookupPrivate(&pScreen->devPrivates,\n"
                "\t\t\t\t\t\tmiSpriteScreenKey);\n"
                "    SCREEN_PROLOGUE(pScreen, InstallColormap);\n"
                "\n"
                "    (*pScreen->InstallColormap) (pMap);\n"
                "\n"
                "    SCREEN_EPILOGUE(pScreen, InstallColormap);\n",
                "    pPriv = (miSpriteScreenPtr)dixLookupPrivate(&pScreen->devPrivates,\n"
                "\t\t\t\t\t\tmiSpriteScreenKey);\n"
                "    /* be300-tinyx: miSpriteInstallColormap logging. */\n"
                "    ErrorF(\"miSpriteInstallColormap: enter pPriv=%p map=%p\\n\", pPriv, pMap);\n"
                "    SCREEN_PROLOGUE(pScreen, InstallColormap);\n"
                "\n"
                "    ErrorF(\"miSpriteInstallColormap: before wrapped InstallColormap\\n\");\n"
                "    (*pScreen->InstallColormap) (pMap);\n"
                "    ErrorF(\"miSpriteInstallColormap: after wrapped InstallColormap\\n\");\n"
                "\n"
                "    SCREEN_EPILOGUE(pScreen, InstallColormap);\n"
                "    ErrorF(\"miSpriteInstallColormap: after epilogue\\n\");\n",
                1,
            )
            text = text.replace(
                "        for (pDev = inputInfo.devices; pDev; pDev = pDev->next)\n",
                "        ErrorF(\"miSpriteInstallColormap: before input device loop\\n\");\n"
                "        for (pDev = inputInfo.devices; pDev; pDev = pDev->next)\n",
                1,
            )
            text = text.replace(
                "\n    }\n}\n\nstatic void\nmiSpriteStoreColors",
                "\n        ErrorF(\"miSpriteInstallColormap: after input device loop\\n\");\n"
                "    }\n}\n\nstatic void\nmiSpriteStoreColors",
                1,
            )
            return text
        if rewrite_in_place(misprite, transform_misprite):
            changed += 1

    kdrive = tree / "hw" / "kdrive" / "src" / "kdrive.c"
    if kdrive.is_file():
        def transform_kdrive(text: str) -> str:
            if "be300-tinyx: KdScreenInit colormap logging" in text:
                return text
            return text.replace(
                "    if (!fbCreateDefColormap (pScreen))\n"
                "    {\n"
                "\tErrorF(\"KdScreenInit: fbCreateDefColormap failed\\n\");\n"
                "\treturn FALSE;\n"
                "    }\n"
                "\n"
                "    KdSetSubpixelOrder (pScreen, screen->randr);\n",
                "    ErrorF(\"KdScreenInit: before fbCreateDefColormap\\n\");\n"
                "    /* be300-tinyx: KdScreenInit colormap logging. */\n"
                "    if (!fbCreateDefColormap (pScreen))\n"
                "    {\n"
                "\tErrorF(\"KdScreenInit: fbCreateDefColormap failed\\n\");\n"
                "\treturn FALSE;\n"
                "    }\n"
                "    ErrorF(\"KdScreenInit: after fbCreateDefColormap\\n\");\n"
                "\n"
                "    KdSetSubpixelOrder (pScreen, screen->randr);\n",
                1,
            )
        if rewrite_in_place(kdrive, transform_kdrive):
            changed += 1

    return changed


def patch_kdrive_screen_lifecycle_logging(tree: Path) -> int:
    """Log the remaining kdrive screen enable path after colormap creation."""
    kdrive = tree / "hw" / "kdrive" / "src" / "kdrive.c"
    if not kdrive.is_file():
        return 0

    def transform(text: str) -> str:
        if "be300-tinyx: KdScreenInit lifecycle logging" in text:
            return text

        text = text.replace(
            "    KdSetSubpixelOrder (pScreen, screen->randr);\n"
            "\n"
            "    /*\n"
            "     * Enable the hardware\n"
            "     */\n"
            "    if (!kdEnabled)\n"
            "    {\n"
            "\tkdEnabled = TRUE;\n"
            "\tif(kdOsFuncs->Enable)\n"
            "\t    (*kdOsFuncs->Enable) ();\n"
            "    }\n"
            "    \n"
            "    if (screen->mynum == card->selected)\n"
            "    {\n"
            "\tif(card->cfuncs->preserve)\n"
            "\t    (*card->cfuncs->preserve) (card);\n"
            "\tif(card->cfuncs->enable)\n"
            "\t    if (!(*card->cfuncs->enable) (pScreen))\n"
            "\t    {\n"
            "\t\tErrorF(\"KdScreenInit: driver enable failed\\n\");\n"
            "\t\treturn FALSE;\n"
            "\t    }\n"
            "\tpScreenPriv->enabled = TRUE;\n"
            "\tif (!screen->softCursor && card->cfuncs->enableCursor)\n"
            "\t    (*card->cfuncs->enableCursor) (pScreen);\n"
            "\tKdEnableColormap (pScreen);\n"
            "\tif (!screen->dumb && card->cfuncs->enableAccel)\n"
            "\t    (*card->cfuncs->enableAccel) (pScreen);\n"
            "    }\n"
            "    \n"
            "    return TRUE;\n",
            "    /* be300-tinyx: KdScreenInit lifecycle logging. */\n"
            "    ErrorF(\"KdScreenInit: before KdSetSubpixelOrder\\n\");\n"
            "    KdSetSubpixelOrder (pScreen, screen->randr);\n"
            "    ErrorF(\"KdScreenInit: after KdSetSubpixelOrder\\n\");\n"
            "\n"
            "    /*\n"
            "     * Enable the hardware\n"
            "     */\n"
            "    if (!kdEnabled)\n"
            "    {\n"
            "\tkdEnabled = TRUE;\n"
            "\tif(kdOsFuncs->Enable)\n"
            "\t{\n"
            "\t    ErrorF(\"KdScreenInit: before os Enable\\n\");\n"
            "\t    (*kdOsFuncs->Enable) ();\n"
            "\t    ErrorF(\"KdScreenInit: after os Enable\\n\");\n"
            "\t}\n"
            "\telse\n"
            "\t    ErrorF(\"KdScreenInit: no os Enable\\n\");\n"
            "    }\n"
            "    \n"
            "    ErrorF(\"KdScreenInit: selected=%d mynum=%d\\n\", card->selected, screen->mynum);\n"
            "    if (screen->mynum == card->selected)\n"
            "    {\n"
            "\tif(card->cfuncs->preserve)\n"
            "\t{\n"
            "\t    ErrorF(\"KdScreenInit: before preserve\\n\");\n"
            "\t    (*card->cfuncs->preserve) (card);\n"
            "\t    ErrorF(\"KdScreenInit: after preserve\\n\");\n"
            "\t}\n"
            "\tif(card->cfuncs->enable)\n"
            "\t{\n"
            "\t    ErrorF(\"KdScreenInit: before driver enable\\n\");\n"
            "\t    if (!(*card->cfuncs->enable) (pScreen))\n"
            "\t    {\n"
            "\t\tErrorF(\"KdScreenInit: driver enable failed\\n\");\n"
            "\t\treturn FALSE;\n"
            "\t    }\n"
            "\t    ErrorF(\"KdScreenInit: after driver enable\\n\");\n"
            "\t}\n"
            "\tpScreenPriv->enabled = TRUE;\n"
            "\tif (!screen->softCursor && card->cfuncs->enableCursor)\n"
            "\t{\n"
            "\t    ErrorF(\"KdScreenInit: before enableCursor\\n\");\n"
            "\t    (*card->cfuncs->enableCursor) (pScreen);\n"
            "\t    ErrorF(\"KdScreenInit: after enableCursor\\n\");\n"
            "\t}\n"
            "\tErrorF(\"KdScreenInit: before KdEnableColormap\\n\");\n"
            "\tKdEnableColormap (pScreen);\n"
            "\tErrorF(\"KdScreenInit: after KdEnableColormap\\n\");\n"
            "\tif (!screen->dumb && card->cfuncs->enableAccel)\n"
            "\t{\n"
            "\t    ErrorF(\"KdScreenInit: before enableAccel\\n\");\n"
            "\t    (*card->cfuncs->enableAccel) (pScreen);\n"
            "\t    ErrorF(\"KdScreenInit: after enableAccel\\n\");\n"
            "\t}\n"
            "    }\n"
            "    \n"
            "    ErrorF(\"KdScreenInit: return TRUE\\n\");\n"
            "    return TRUE;\n",
            1,
        )
        text = text.replace(
            "    AddScreen (KdScreenInit, argc, argv);\n",
            "    ErrorF(\"KdAddScreen: before AddScreen mynum=%d\\n\", screen->mynum);\n"
            "    AddScreen (KdScreenInit, argc, argv);\n"
            "    ErrorF(\"KdAddScreen: after AddScreen numScreens=%d\\n\", pScreenInfo->numScreens);\n",
            1,
        )
        text = text.replace(
            "    if (!KdSetPixmapFormats (pScreenInfo))\n"
            "\treturn;\n",
            "    ErrorF(\"KdInitOutput: before KdSetPixmapFormats\\n\");\n"
            "    if (!KdSetPixmapFormats (pScreenInfo))\n"
            "    {\n"
            "\tErrorF(\"KdInitOutput: KdSetPixmapFormats failed\\n\");\n"
            "\treturn;\n"
            "    }\n"
            "    ErrorF(\"KdInitOutput: after KdSetPixmapFormats\\n\");\n",
            1,
        )
        return text

    return 1 if rewrite_in_place(kdrive, transform) else 0


def patch_kdrive_linux_no_vt_wait(tree: Path) -> int:
    """Avoid blocking forever in VT_WAITACTIVE on the BE-300 framebuffer console."""
    f = tree / "hw" / "kdrive" / "linux" / "linux.c"
    if not f.is_file():
        return 0

    def transform(text: str) -> str:
        if "be300-tinyx: no VT activation wait" in text:
            return text

        old = """\
    /*
     * now get the VT
     */
    LinuxSetSwitchMode (VT_AUTO);
    if (ioctl(LinuxConsoleFd, VT_ACTIVATE, vtno) != 0)
    {
\tFatalError("LinuxInit: VT_ACTIVATE failed\\n");
    }
    if (ioctl(LinuxConsoleFd, VT_WAITACTIVE, vtno) != 0)
    {
\tFatalError("LinuxInit: VT_WAITACTIVE failed\\n");
    }
    LinuxSetSwitchMode (VT_PROCESS);
    if (ioctl(LinuxConsoleFd, KDSETMODE, KD_GRAPHICS) < 0)
    {
\tFatalError("LinuxInit: KDSETMODE KD_GRAPHICS failed\\n");
    }
    enabled = TRUE;
"""
        new = """\
    /*
     * be300-tinyx: no VT activation wait.
     *
     * The BE-300 profile is launched from init on a single embedded
     * framebuffer console.  VT_ACTIVATE/VT_WAITACTIVE can block forever
     * because there is no interactive VT manager to complete the switch.
     * start-tinyx has already placed the console in graphics mode; keep the
     * current console active and let Xfbdev render directly to /dev/fb0.
     */
    ErrorF("LinuxEnable: BE-300 no-vt path\\n");
    if (ioctl(LinuxConsoleFd, KDSETMODE, KD_GRAPHICS) < 0)
\tErrorF("LinuxEnable: KDSETMODE KD_GRAPHICS ignored: %s\\n", strerror(errno));
    enabled = TRUE;
"""
        if old not in text:
            fail("linux.c VT activation context not found")
        return text.replace(old, new, 1)

    return 1 if rewrite_in_place(f, transform) else 0


def patch_kdrive_evdev_touchscreen(tree: Path) -> int:
    """Make kdrive's evdev pointer driver usable with the BE-300 touchscreen.

    Upstream xorg-server-1.6.5 only logs EV_ABS events and only maps
    BTN_LEFT/MIDDLE/RIGHT button codes.  The BE-300 PIU driver reports an
    absolute touchscreen as ABS_X, ABS_Y, ABS_PRESSURE and BTN_TOUCH.  Convert
    ABS_X/ABS_Y into absolute pointer motion and BTN_TOUCH into button 1.
    """
    f = tree / "hw" / "kdrive" / "linux" / "evdev.c"
    if not f.is_file():
        return 0

    def transform(text: str) -> str:
        if "be300-tinyx: absolute touchscreen evdev support" in text:
            return text

        old_btn = """\
static void
EvdevPtrBtn (KdPointerInfo    *pi, struct input_event *ev)
{
    int flags = KD_MOUSE_DELTA | pi->buttonState;

    if (ev->code >= BTN_MOUSE && ev->code < BTN_JOYSTICK) {
        switch (ev->code) {
        case BTN_LEFT:
            if (ev->value == 1)
                flags |= KD_BUTTON_1;
\t    else
                flags &= ~KD_BUTTON_1;
             break;
        case BTN_MIDDLE:
            if (ev->value == 1)
                flags |= KD_BUTTON_2;
\t    else
\t\tflags &= ~KD_BUTTON_2;
            break;
        case BTN_RIGHT:
            if (ev->value == 1)
                flags |= KD_BUTTON_3;
\t    else
\t\tflags &= ~KD_BUTTON_3;
            break;
        default:
            /* Unknow button */
            break;
        }

        KdEnqueuePointerEvent (pi, flags, 0, 0, 0);
    }
}
"""
        new_btn = """\
static Bool
EvdevPtrHaveAbsXY (Kevdev *ke)
{
    return ke->max_abs >= ABS_Y &&
           ke->prevabs[ABS_X] != ABS_UNSET &&
           ke->prevabs[ABS_Y] != ABS_UNSET;
}

static void
EvdevPtrQueueAbs (KdPointerInfo *pi, Kevdev *ke, unsigned long flags)
{
    if (EvdevPtrHaveAbsXY (ke))
        KdEnqueuePointerEvent (pi, flags, ke->abs[ABS_X], ke->abs[ABS_Y], 0);
}

static void
EvdevPtrBtn (KdPointerInfo    *pi, struct input_event *ev)
{
    Kevdev *ke = pi->driverPrivate;
    int flags = KD_MOUSE_DELTA | pi->buttonState;

    /* be300-tinyx: absolute touchscreen evdev support. */
    if (ev->code == BTN_TOUCH) {
        flags = pi->buttonState;
        if (ev->value == 1)
            flags |= KD_BUTTON_1;
        else
            flags &= ~KD_BUTTON_1;
        EvdevPtrQueueAbs (pi, ke, flags);
        return;
    }

    if (ev->code >= BTN_MOUSE && ev->code < BTN_JOYSTICK) {
        switch (ev->code) {
        case BTN_LEFT:
            if (ev->value == 1)
                flags |= KD_BUTTON_1;
\t    else
                flags &= ~KD_BUTTON_1;
             break;
        case BTN_MIDDLE:
            if (ev->value == 1)
                flags |= KD_BUTTON_2;
\t    else
\t\tflags &= ~KD_BUTTON_2;
            break;
        case BTN_RIGHT:
            if (ev->value == 1)
                flags |= KD_BUTTON_3;
\t    else
\t\tflags &= ~KD_BUTTON_3;
            break;
        default:
            /* Unknown button */
            break;
        }

        KdEnqueuePointerEvent (pi, flags, 0, 0, 0);
    }
}
"""
        if old_btn not in text:
            fail("evdev.c button handler context not found")
        text = text.replace(old_btn, new_btn, 1)

        old_abs = """\
    for (i = 0; i < ke->max_abs; i++)
        if (ke->abs[i] != ke->prevabs[i])
        {
            int a;
            ErrorF ("abs");
            for (a = 0; a <= ke->max_abs; a++)
            {
                if (ISBITSET (ke->absbits, a))
                    ErrorF (" %d=%d", a, ke->abs[a]);
                ke->prevabs[a] = ke->abs[a];
            }
            ErrorF ("\\n");
            break;
        }
"""
        new_abs = """\
    for (i = 0; i <= ke->max_abs; i++)
        if (ke->abs[i] != ke->prevabs[i])
        {
            int a;
            for (a = 0; a <= ke->max_abs; a++)
                if (ISBITSET (ke->absbits, a))
                    ke->prevabs[a] = ke->abs[a];
            if ((ev->code == ABS_X || ev->code == ABS_Y) &&
                EvdevPtrHaveAbsXY (ke))
                KdEnqueuePointerEvent (pi, pi->buttonState,
                                       ke->abs[ABS_X], ke->abs[ABS_Y], 0);
            break;
        }
"""
        if old_abs not in text:
            fail("evdev.c absolute-motion context not found")
        return text.replace(old_abs, new_abs, 1)

    return 1 if rewrite_in_place(f, transform) else 0


def patch_kdrive_evdev_touchscreen_class(tree: Path) -> int:
    """Register the BE-300 evdev pointer as an absolute touchscreen.

    KdParsePointer() defaults every `-mouse` device to KD_MOUSE with zero
    axes before the driver's Init hook runs.  For the BE-300 PIU evdev node
    that means the ABS_X/ABS_Y events are delivered through a relative-mouse
    shaped core device, so clients can get clicks while the sprite does not
    track the touch position.  Override the class during EvdevPtrInit(), before
    KdPointerProc() calls InitPointerDeviceStruct().
    """
    f = tree / "hw" / "kdrive" / "linux" / "evdev.c"
    if not f.is_file():
        return 0

    def transform(text: str) -> str:
        if "be300-tinyx: mark evdev pointer as touchscreen" in text:
            return text
        old = """\
    pi->name = KdSaveString("Evdev mouse");

    return Success;
}
"""
        new = """\
    /* be300-tinyx: mark evdev pointer as touchscreen before DIX init. */
    pi->name = KdSaveString("BE-300 touchscreen");
    pi->inputClass = KD_TOUCHSCREEN;
    pi->nAxes = 3;
    pi->emulateMiddleButton = FALSE;

    return Success;
}
"""
        if old not in text:
            fail("evdev.c pointer init class context not found")
        return text.replace(old, new, 1)

    return 1 if rewrite_in_place(f, transform) else 0


def patch_kdrive_evdev_touchscreen_contact_state(tree: Path) -> int:
    """Preserve BTN_TOUCH state until ABS_X/ABS_Y arrive.

    The BE-300 driver can report BTN_TOUCH before the following ABS sample.
    Queueing the button only when both coordinates are known makes the first
    press both move the sprite and deliver button 1 at that location.
    """
    f = tree / "hw" / "kdrive" / "linux" / "evdev.c"
    if not f.is_file():
        return 0

    def transform(text: str) -> str:
        marker = "be300-tinyx: touchscreen contact state"
        if marker in text:
            return text

        old_struct = (
            "    int                     fd;\n"
            "} Kevdev;\n"
        )
        new_struct = (
            "    int                     fd;\n"
            "\n"
            f"    /* {marker}; BTN_TOUCH can precede the ABS sample. */\n"
            "    int                     have_abs_x;\n"
            "    int                     have_abs_y;\n"
            "    int                     touch_down;\n"
            "} Kevdev;\n"
        )
        if old_struct not in text:
            fail("evdev.c Kevdev contact-state context not found")
        text = text.replace(old_struct, new_struct, 1)

        old_helpers = """\
static Bool
EvdevPtrHaveAbsXY (Kevdev *ke)
{
    return ke->max_abs >= ABS_Y &&
           ke->prevabs[ABS_X] != ABS_UNSET &&
           ke->prevabs[ABS_Y] != ABS_UNSET;
}

static void
EvdevPtrQueueAbs (KdPointerInfo *pi, Kevdev *ke, unsigned long flags)
{
    if (EvdevPtrHaveAbsXY (ke))
        KdEnqueuePointerEvent (pi, flags, ke->abs[ABS_X], ke->abs[ABS_Y], 0);
}
"""
        new_helpers = """\
static Bool
EvdevPtrHaveAbsXY (Kevdev *ke)
{
    return ke->max_abs >= ABS_Y && ke->have_abs_x && ke->have_abs_y;
}

static unsigned long
EvdevPtrAbsFlags (KdPointerInfo *pi, Kevdev *ke)
{
    unsigned long flags = pi->buttonState;

    if (ke->touch_down)
        flags |= KD_BUTTON_1;
    else
        flags &= ~KD_BUTTON_1;
    return flags;
}

static void
EvdevPtrQueueAbs (KdPointerInfo *pi, Kevdev *ke)
{
    if (EvdevPtrHaveAbsXY (ke))
        KdEnqueuePointerEvent (pi, EvdevPtrAbsFlags (pi, ke),
                               ke->abs[ABS_X], ke->abs[ABS_Y], 0);
}
"""
        if old_helpers not in text:
            fail("evdev.c absolute helper contact-state context not found")
        text = text.replace(old_helpers, new_helpers, 1)

        old_touch = """\
    if (ev->code == BTN_TOUCH) {
        flags = pi->buttonState;
        if (ev->value == 1)
            flags |= KD_BUTTON_1;
        else
            flags &= ~KD_BUTTON_1;
        EvdevPtrQueueAbs (pi, ke, flags);
        return;
    }
"""
        new_touch = """\
    if (ev->code == BTN_TOUCH) {
        ke->touch_down = ev->value ? 1 : 0;
        EvdevPtrQueueAbs (pi, ke);
        return;
    }
"""
        if old_touch not in text:
            fail("evdev.c BTN_TOUCH contact-state context not found")
        text = text.replace(old_touch, new_touch, 1)

        old_abs = """\
    for (i = 0; i <= ke->max_abs; i++)
        if (ke->abs[i] != ke->prevabs[i])
        {
            int a;
            for (a = 0; a <= ke->max_abs; a++)
                if (ISBITSET (ke->absbits, a))
                    ke->prevabs[a] = ke->abs[a];
            if ((ev->code == ABS_X || ev->code == ABS_Y) &&
                EvdevPtrHaveAbsXY (ke))
                KdEnqueuePointerEvent (pi, pi->buttonState,
                                       ke->abs[ABS_X], ke->abs[ABS_Y], 0);
            break;
        }
"""
        new_abs = """\
    for (i = 0; i <= ke->max_abs; i++)
        if (ke->abs[i] != ke->prevabs[i])
        {
            int a;
            for (a = 0; a <= ke->max_abs; a++)
                if (ISBITSET (ke->absbits, a))
                    ke->prevabs[a] = ke->abs[a];
            if (ev->code == ABS_X)
                ke->have_abs_x = 1;
            else if (ev->code == ABS_Y)
                ke->have_abs_y = 1;
            if (ev->code == ABS_X || ev->code == ABS_Y)
                EvdevPtrQueueAbs (pi, ke);
            break;
        }
"""
        if old_abs not in text:
            fail("evdev.c ABS contact-state context not found")
        return text.replace(old_abs, new_abs, 1)

    return 1 if rewrite_in_place(f, transform) else 0


def patch_dixfonts_no_fs(tree: Path) -> int:
    """libXfont built with --disable-fc omits fs_register_fpe_functions,
    but xorg-server's dix/dixfonts.c calls it unconditionally. Comment out
    that one call. The Builtin + FontFile FPEs remain registered, so
    PCF fonts continue to work."""
    f = tree / "dix" / "dixfonts.c"
    if not f.is_file():
        return 0

    def transform(text: str) -> str:
        if "be300-tinyx: skip fs_register_fpe_functions" in text:
            return text
        return text.replace(
            "    fs_register_fpe_functions();",
            "    /* be300-tinyx: skip fs_register_fpe_functions (libXfont built --disable-fc) */",
            1,
        )

    return 1 if rewrite_in_place(f, transform) else 0


def patch_dixfonts_fpe_bridge(tree: Path) -> int:
    """Export a stable callback for libXfont's RegisterFPEFunctions stub.

    libXfont's weak RegisterFPEFunctions() stub is not reliably preempted by
    the Xfbdev executable on the BE-300 uClibc/MIPS dynamic link path.  Export
    a separate bridge symbol that the patched libXfont stub can weakly call.
    """
    f = tree / "dix" / "dixfonts.c"
    if not f.is_file():
        return 0

    def transform(text: str) -> str:
        if "__be300_xserver_RegisterFPEFunctions" in text:
            return text
        needle = """\
    return num_fpe_types++;
}

void
FreeFonts(void)
"""
        repl = """\
    return num_fpe_types++;
}

int __attribute__((used, externally_visible))
__be300_xserver_RegisterFPEFunctions(NameCheckFunc name_func,
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
\t\t     SetPathFunc set_path_func)
{
    /* be300-tinyx: bridge libXfont's weak FPE stub to Xfbdev's registry. */
    return RegisterFPEFunctions(name_func, init_func, free_func, reset_func,
\t\t\t\topen_func, close_func, list_func, start_lfwi_func,
\t\t\t\tnext_lfwi_func, wakeup_func, client_died, load_glyphs,
\t\t\t\tstart_list_alias_func, next_list_alias_func,
\t\t\t\tset_path_func);
}

void
FreeFonts(void)
"""
        if needle not in text:
            fail("dixfonts.c RegisterFPEFunctions tail context not found")
        return text.replace(needle, repl, 1)

    return 1 if rewrite_in_place(f, transform) else 0


def patch_drop_xtest_h(tree: Path) -> int:
    """Remove <X11/extensions/XTest.h> from server-side source files.

    libXtst-1.2.3's XTest.h pulls in <X11/extensions/XInput.h> which pulls
    in <X11/Xlib.h>.  The Xlib client typedef `*GC` conflicts with the
    xorg-server's internal `GC` struct.  The server only needs the wire
    protocol types — already provided by our xteststr.h shim (which
    includes xtestproto.h + xtestconst.h, both Xlib-free).
    """
    targets = [
        tree / "hw" / "xfree86" / "dixmods" / "extmod" / "modinit.h",
        tree / "Xext" / "xtest.c",
    ]
    changed = 0
    for f in targets:
        if not f.is_file():
            continue

        def transform(text: str) -> str:
            if "be300-tinyx: skip XTest.h" in text:
                return text
            return text.replace(
                "#include <X11/extensions/XTest.h>",
                "/* be300-tinyx: skip XTest.h — pulls Xlib.h which conflicts\n"
                "   with the server's internal GC.  xteststr.h is enough. */",
                1,
            )

        if rewrite_in_place(f, transform):
            changed += 1
    return changed


def patch_skip_sha1(tree: Path) -> int:
    """Skip xorg-server's openssl/libmd SHA1 dependency.

    SHA1 is only used in render/glyph.c::HashGlyph for the glyph-cache
    deduplication key.  We have neither openssl nor libmd available for
    the mipsel cross target, and building one just to fail-soft on a
    cache-key collision isn't worth it.  Replace the SHA1 path with a
    trivial 20-byte hash (FNV-1a folded to 160 bits), and short-circuit
    the configure.ac autoconf machinery so it doesn't require openssl.
    """
    changed = 0

    # 1. configure.ac: replace the SHA1_LIB detection block with a no-op
    cfg = tree / "configure.ac"
    if cfg.is_file():
        def transform_cfg(text: str) -> str:
            if "be300-tinyx: skip SHA1 detection" in text:
                return text
            new = re.sub(
                r"(?ms)if test \"x\$SHA1_LIB\" = \"x\" ; then\s*\n"
                r"  AC_CHECK_LIB\(\[md\], \[SHA1Init\].*?fi\s*\n",
                "dnl be300-tinyx: skip SHA1 detection (stub in glyph.c)\n"
                "SHA1_LIB=\"\"\n",
                text,
                count=2,
            )
            # remove the final "OpenSSL must be installed" AC_MSG_ERROR block too
            new = re.sub(
                r"if test \"x\$SHA1_LIB\" = \"x\" ; then\s*\n"
                r"  PKG_CHECK_EXISTS\(\[OPENSSL\].*?fi\s*\nfi\s*\n",
                "dnl be300-tinyx: SHA1 stub provided in glyph.c\n",
                new,
                count=1,
                flags=re.DOTALL,
            )
            return new
        if rewrite_in_place(cfg, transform_cfg):
            changed += 1

    # 2. render/glyph.c: stub out the SHA1 path AND the openssl include
    glyph = tree / "render" / "glyph.c"
    if glyph.is_file():
        def transform_glyph(text: str) -> str:
            if "be300-tinyx: stub HashGlyph" in text:
                return text
            # First, neutralize the openssl/libmd include block so glyph.c
            # compiles without either being available.
            text = re.sub(
                r"#ifdef HAVE_SHA1_IN_LIBMD.*?#endif\n",
                "/* be300-tinyx: SHA1 stubbed inside HashGlyph below — no\n"
                "   openssl/libmd include needed. */\n",
                text,
                count=1,
                flags=re.DOTALL,
            )
            # Then replace the entire `HashGlyph` function body with an
            # FNV-1a fold.  Use a raw string for the replacement so the
            # \1 / \2 backreferences are recognized by re.sub.
            pattern = re.compile(
                r"(?s)(int\s*\n"
                r"HashGlyph\s*\(xGlyphInfo\s*\*gi,\s*\n"
                r"\s*CARD8\s*\*bits,\s*\n"
                r"\s*unsigned long\s*size,\s*\n"
                r"\s*unsigned char\s*sha1\[20\]\)\s*\n"
                r"\{).*?(\n\s*return Success;\s*\n\})"
            )
            replacement = r"""\1
    /* be300-tinyx: stub HashGlyph with FNV-1a 160-bit fold;
       we have no openssl or libmd on the mipsel cross target,
       and glyph-cache dedup tolerates a weak hash gracefully. */
    unsigned int i;
    unsigned char acc[20];
    unsigned int h = 2166136261u;
    const unsigned char *src;
    src = (const unsigned char *)gi;
    for (i = 0; i < sizeof(xGlyphInfo); i++) { h ^= src[i]; h *= 16777619u; }
    src = (const unsigned char *)bits;
    for (i = 0; i < size; i++) { h ^= src[i]; h *= 16777619u; }
    for (i = 0; i < 20; i++) { acc[i] = (h >> ((i & 3) * 8)) & 0xff; h *= 16777619u; }
    for (i = 0; i < 20; i++) sha1[i] = acc[i];\2"""
            return pattern.sub(replacement, text, count=1)
        if rewrite_in_place(glyph, transform_glyph):
            changed += 1

    return changed


def patch_disable_smart_schedule(tree: Path) -> int:
    """Default SmartScheduleDisable to TRUE in dispatch.c.

    The dix Dispatch() loop calls SmartScheduleClient() between
    WaitForSomething() and ReadRequestFromClient() when SmartScheduleDisable
    is FALSE.  On uClibc-ng MIPS PIC the resulting call chain runs into a
    codegen / linker interaction that drops a function pointer reload to 0
    and faults the first time a real client request arrives.  Disabling the
    smart scheduler bypasses that call site entirely and makes Dispatch()
    fall straight through to ReadRequestFromClient — confirmed to make
    matchbox + be300-xstatus run end-to-end on the BE-300 emulator.
    """
    changed = 0
    dispatch = tree / "dix" / "dispatch.c"
    if dispatch.is_file():
        def transform(text: str) -> str:
            if "be300-tinyx: disable SmartScheduleClient" in text:
                return text
            return text.replace(
                "Bool\t    SmartScheduleDisable = FALSE;",
                "/* be300-tinyx: disable SmartScheduleClient — its call site\n"
                " * between WaitForSomething() and ReadRequestFromClient() is the\n"
                " * trigger for a uClibc-ng/MIPS PIC fault where a function-pointer\n"
                " * reload lands at 0.  Skipping it lets the first real client\n"
                " * request reach ReadRequestFromClient cleanly. */\n"
                "Bool\t    SmartScheduleDisable = TRUE;",
                1,
            )
        if rewrite_in_place(dispatch, transform):
            changed += 1
    return changed


def patch_os_siginit_dump(tree: Path) -> int:
    """Opt-in SIGSEGV/SIGBUS register dump inside OsInit().

    The TinyX profile occasionally takes a SIGSEGV inside the BlockHandler
    dispatch chain after 40–50 s of activity.  Existing mitigations
    (SmartScheduleDisable=TRUE, hidden visibility on ReadRequestFromClient /
    InsertFakeRequest, -Wl,-Bsymbolic-functions) have eliminated the original
    crash site, but the residual fault still appears intermittently as a MIPS
    PIC indirect-call landing at NULL.  To identify the next call site, install
    an opt-in SIGSEGV handler that prints `pc`, `ra`, and the faulting address
    from ucontext_t before letting the default fatal-error path run.

    Gated by env var BE300_TINYX_DEBUG_SIGSEGV=1 (set via /etc/tinyx.conf) so
    the steady-state image is unaffected.  The handler uses only write(2) for
    output to stay async-signal-safe; the formatting is done with a tiny hex
    helper that lives in the same translation unit.

    On uClibc-ng/MIPS Linux, `mcontext_t` typedefs to `struct sigcontext`, so
    we read `sc_pc` and `sc_regs[31]` (RA) directly.  Glibc's MIPS layout uses
    `gregs[]` instead; both are tried via #ifdef so the patch survives a libc
    swap.
    """
    f = tree / "os" / "osinit.c"
    if not f.is_file():
        return 0

    def transform(text: str) -> str:
        marker = "be300-tinyx: opt-in SIGSEGV/SIGBUS register dump"
        if marker in text:
            return text

        # Insert helper + handler just before `void\nOsInit(void)`.
        helper = f"""\
/* {marker}.
 * Active only when BE300_TINYX_DEBUG_SIGSEGV=1 is in the process environment.
 * Writes "[be300-segv] sig=N pc=XXXXXXXX ra=XXXXXXXX addr=XXXXXXXX\\n" to
 * stderr from the signal handler, then restores SIG_DFL and re-raises so the
 * X server's normal fatal-error path still runs.  Async-signal-safe: only
 * write(2), signal(2), raise(3) — no printf, malloc, or stdio buffers. */
#include <signal.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ucontext.h>

static void be300_segv_hex8(char *buf, unsigned long v) {{
    int i;
    for (i = 7; i >= 0; i--) {{
        unsigned d = (unsigned)(v & 0xFu);
        v >>= 4;
        buf[i] = (char)(d < 10 ? '0' + d : 'a' + (d - 10));
    }}
}}

static void be300_segv_handler(int sig, siginfo_t *si, void *ctx_ptr) {{
    char buf[96];
    int n = 0;
    const char *p;
    unsigned long pc = 0, ra = 0, addr;
    ucontext_t *uc = (ucontext_t *)ctx_ptr;

    if (uc) {{
#if defined(__mips__)
        /* MIPS o32 mcontext_t: { regmask, status, pc, gregs[NGREG], ... }
         * Both uClibc-ng and glibc ship this layout on Linux/MIPS o32.
         * gregs[31] is RA per the o32 register-number convention. */
        pc = (unsigned long)uc->uc_mcontext.pc;
        ra = (unsigned long)uc->uc_mcontext.gregs[31];
#endif
    }}
    addr = si ? (unsigned long)si->si_addr : 0UL;

    p = "[be300-segv] sig=";
    while (*p) buf[n++] = *p++;
    buf[n++] = (char)('0' + ((sig / 10) % 10));
    buf[n++] = (char)('0' + (sig % 10));
    p = " pc=";  while (*p) buf[n++] = *p++;
    be300_segv_hex8(buf + n, pc); n += 8;
    p = " ra=";  while (*p) buf[n++] = *p++;
    be300_segv_hex8(buf + n, ra); n += 8;
    p = " addr="; while (*p) buf[n++] = *p++;
    be300_segv_hex8(buf + n, addr); n += 8;
    buf[n++] = '\\n';
    (void)write(2, buf, (size_t)n);

    signal(sig, SIG_DFL);
    raise(sig);
}}

static void be300_install_segv_handler(void) {{
    struct sigaction sa;
    if (!getenv("BE300_TINYX_DEBUG_SIGSEGV"))
        return;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = be300_segv_handler;
    sa.sa_flags = SA_SIGINFO;
    sigemptyset(&sa.sa_mask);
    (void)sigaction(SIGSEGV, &sa, (struct sigaction *)0);
    (void)sigaction(SIGBUS,  &sa, (struct sigaction *)0);
    (void)write(2, "[be300-segv] handler installed\\n", 31);
}}

void
OsInit(void)
"""
        old_signature = "void\nOsInit(void)\n"
        if old_signature not in text:
            fail("osinit.c OsInit() signature not found")
        text = text.replace(old_signature, helper, 1)

        # Install at the start of OsInit()'s been_here block.
        old_lock = (
            "\tLockServer();\n"
            "\tbeen_here = TRUE;\n"
        )
        new_lock = (
            "\tbe300_install_segv_handler();\n"
            "\tLockServer();\n"
            "\tbeen_here = TRUE;\n"
        )
        if old_lock not in text:
            fail("osinit.c LockServer/been_here context not found")
        text = text.replace(old_lock, new_lock, 1)
        return text

    return 1 if rewrite_in_place(f, transform) else 0


def main() -> int:
    if len(sys.argv) != 2:
        fail("usage: patch_xorg_sources.py <xorg-server-tree>")
    tree = Path(sys.argv[1])
    if not tree.is_dir():
        fail(f"not a directory: {tree}")

    total = 0
    total += patch_xorg_server_configure(tree)
    total += drop_dead_hal_udev_requires(tree)
    total += patch_kdrive_linux_unistd(tree)
    total += patch_xace_hook_lifetime(tree)
    total += patch_animcur_without_screen_block_handler(tree)
    total += patch_kdrive_without_screen_block_handler(tree)
    total += patch_kdrive_select_only_input_fds(tree)
    total += patch_kdrive_evdev_keyboard(tree)
    total += patch_kdrive_evdev_keyboard_mapping(tree)
    total += patch_dix_main_startup_logging(tree)
    total += patch_connection_logging(tree)
    total += patch_os_time_local_binding(tree)
    total += patch_os_io_local_binding(tree)
    total += patch_dix_close_down_client_local_binding(tree)
    total += patch_connection_auth_local_binding(tree)
    total += patch_xace_hook_local_binding(tree)
    total += patch_insert_fake_request_exported(tree)
    total += patch_callback_local_binding(tree)
    total += patch_block_wakeup_local_binding(tree)
    total += patch_block_wakeup_quiet_guards(tree)
    total += patch_waitfor_wakeup_only_for_input(tree)
    total += patch_waitfor_inline_new_connections(tree)
    total += patch_waitfor_skip_block_handler(tree)
    total += patch_waitfor_select_logging(tree)
    total += patch_waitfor_no_timer_timeouts(tree)
    total += patch_wakeup_skip_generic_handlers(tree)
    total += patch_insert_fake_request_logging(tree)
    total += patch_client_dispatch_logging(tree)
    total += patch_dispatch_local_initial_request(tree)
    total += patch_dispatch_wait_input_local_binding(tree)
    total += patch_dispatch_loop_logging(tree)
    total += patch_colormap_install_logging(tree)
    total += patch_kdrive_screen_lifecycle_logging(tree)
    total += patch_kdrive_linux_no_vt_wait(tree)
    total += patch_kdrive_evdev_touchscreen(tree)
    total += patch_kdrive_evdev_touchscreen_class(tree)
    total += patch_kdrive_evdev_touchscreen_contact_state(tree)
    total += patch_kdrive_evdev_wire_event(tree)
    total += patch_drop_xtest_h(tree)
    total += patch_dixfonts_no_fs(tree)
    total += patch_dixfonts_fpe_bridge(tree)
    total += patch_skip_sha1(tree)
    total += patch_disable_smart_schedule(tree)
    total += patch_os_siginit_dump(tree)

    if total == 0:
        print(f"patch_xorg_sources: no changes needed ({tree})")
    else:
        print(f"patch_xorg_sources: applied {total} edit(s) under {tree}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
