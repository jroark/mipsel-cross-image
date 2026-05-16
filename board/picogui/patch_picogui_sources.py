#!/usr/bin/env python3
"""BE-300 PicoGUI source modernization + evdev driver registration.

Run from board/picogui/build_picogui_rootfs.sh after the upstream tarball has
been extracted and `evdev.c` has been overlaid into pg1/server/input/. The
script is idempotent via a `.be300-picogui-patched-v1` stamp at the source
root.

Tasks:

  1. Rewrite autoconf 2.13-era macros so autoconf 2.69+ accepts the tree.
     `AM_CONFIG_HEADER([...])` -> `AC_CONFIG_HEADERS([...])` everywhere.

  2. Rename `configure.in` to `configure.ac` if both are present (autoconf
     emits a warning otherwise; we want a clean reconfigure).

  3. Wire `evdev.c` into the input library build:
       - pg1/server/input/Makefile.am: append evdev.c to libinput_la_SOURCES
         when CONFIG_DRIVER_EVDEV is set in the build profile.
       - pg1/server/input/input_drivers.c: add an `evdev_regfunc` extern
         declaration and register it in the static driver list.
       - pg1/server/configs/picogui.config-equivalent (profile.defaults
         is the upstream default; our profile sets CONFIG_DRIVER_EVDEV=y
         which the build's config.h generator turns into a #define).
       - pg1/server/config.in: add a CONFIG_DRIVER_EVDEV stanza so the
         menuconfig-derived header defines a macro the source can test.

  4. K&R / implicit-int fixups discovered while building. Each fix is
     keyed on a distinctive substring so re-runs are no-ops.

Usage:

    python3 board/picogui/patch_picogui_sources.py /work/picogui-jserv-be300
"""

from __future__ import annotations

import re
import sys
from pathlib import Path


STAMP_NAME = ".be300-picogui-patched-v1"


def read_text(path: Path) -> str:
    return path.read_text(encoding="latin-1")


def write_text(path: Path, text: str) -> None:
    path.write_text(text, encoding="latin-1")


def modernize_autoconf(root: Path) -> int:
    """Replace AM_CONFIG_HEADER with AC_CONFIG_HEADERS recursively."""
    n = 0
    for cfg in list(root.rglob("configure.in")) + list(root.rglob("configure.ac")):
        text = read_text(cfg)
        new = re.sub(
            r"AM_CONFIG_HEADER\(\s*\[?([^]\)]+?)\]?\s*\)",
            r"AC_CONFIG_HEADERS([\1])",
            text,
        )
        if new != text:
            write_text(cfg, new)
            n += 1
    return n


def rename_configure_in(root: Path) -> int:
    n = 0
    for cfg_in in list(root.rglob("configure.in")):
        cfg_ac = cfg_in.with_suffix(".ac")
        if cfg_ac.exists():
            continue
        cfg_in.rename(cfg_ac)
        n += 1
    return n


def patch_input_makefile_am(root: Path) -> bool:
    """Append evdev.c to libinput_la_SOURCES gated on CONFIG_DRIVER_EVDEV.

    Upstream Makefile.am uses a static SOURCES list plus
    EXTRA_libinput_la_SOURCES with optional drivers; the actual driver
    selection happens via the @DRIVER_OBJS@ substitution from configure.
    The cleanest minimal patch: add an automake conditional that
    appends evdev.c to libinput_la_SOURCES only when evdev was selected.
    The conditional is set up in pg1/server/configure.in (see
    patch_server_configure).
    """
    mk = root / "pg1" / "server" / "input" / "Makefile.am"
    if not mk.exists():
        return False
    text = read_text(mk)
    if "evdev.c" in text:
        return False

    # The original Makefile.am has libinput_la_SOURCES = ... and then
    # EXTRA_libinput_la_SOURCES = ... .  Add evdev.c to the EXTRA list
    # so it ships in the dist tarball, then conditionally append to the
    # actual SOURCES list when the conditional fires.
    text = re.sub(
        r"(EXTRA_libinput_la_SOURCES\s*=\s*\\?\n)",
        r"\1\tevdev.c \\\n",
        text,
        count=1,
    )
    addition = (
        "\n"
        "if CONFIG_DRIVER_EVDEV\n"
        "  libinput_la_SOURCES += evdev.c\n"
        "endif\n"
    )
    text = text.rstrip() + addition
    write_text(mk, text)
    return True


def patch_fbdev_close_no_clear(root: Path) -> bool:
    """Skip the clear-screen in fbdev_close() so a crash leaves the rendered UI.

    pgserver's SIGSEGV handler calls VID(close)() which calls fbdev_close(),
    which has:

        /* Clear the screen before leaving */
        VID(rect)(vid->display, 0, 0, vid->lxres, vid->lyres, 0, PG_LGOP_NONE);

    On the BE-300 this means a crashing pgserver wipes whatever was on the
    framebuffer.  Comment that out so the last-rendered frame stays visible
    when start-picogui freezes after a crash.
    """
    src = root / "pg1" / "server" / "video" / "fbdev.c"
    if not src.exists():
        return False
    text = read_text(src)
    needle = (
        "   /* Clear the screen before leaving */\n"
        "   VID(rect)(vid->display,0,0,vid->lxres,vid->lyres,0,PG_LGOP_NONE);\n"
    )
    replacement = (
        "   /* BE-300: skip clear-on-close so the last-rendered frame stays\n"
        "    * visible after a crash. */\n"
        "   /* VID(rect)(vid->display,0,0,vid->lxres,vid->lyres,0,PG_LGOP_NONE); */\n"
    )
    if needle not in text:
        return False
    text = text.replace(needle, replacement, 1)
    write_text(src, text)
    return True


def patch_html_load_be300(root: Path) -> bool:
    """Replace the abandoned html_load with a working textbox loader.

    Upstream's `pg1/server/formats/html.c` has an html_load that takes
    `(struct textbox_cursor*, const u8*, u32)` - a type that isn't even
    defined anywhere in this jserv tree.  textbox_document.c maps the
    "html" textformat to plaintext_load with a comment saying "HTML not
    working yet".  atomicnav then dumps raw HTML source as plaintext,
    which the user reasonably reads as "the browser is broken".

    Append a new `html_load_be300` function to html.c that matches the
    txtformat signature:

        g_error html_load_be300(struct textbox_document *doc,
                                struct pgstring *str);

    and rewrite the html.c row in textbox_document.c's text_formats[]
    to call it.  The new loader strips tags, decodes the common HTML
    entities, and inserts paragraph breaks for block-level tags
    (<br>, <hr>, <p>, </p>, <h1>..</h6>, </h1>..</h6>, <div>, </div>,
    <li>, <pre>, </pre>, <tr>, </ul>, ...).  Inline tags are skipped.
    Whitespace is collapsed runs of any whitespace -> single space.

    Result: atomicnav renders example.com / a typical HTML 3.2-style
    page as readable plaintext.  Bold / italic / colors / links are
    deliberately not implemented because they require the older
    textbox_cursor API the upstream html.c was written against; that's
    a multi-week refactor of the textbox subsystem.
    """
    html_c = root / "pg1" / "server" / "formats" / "html.c"
    if not html_c.exists():
        return False
    text = read_text(html_c)
    if "html_load_be300" in text:
        return False

    appended = r"""

/* ============================================================
 * BE-300: working html_load that matches the txtformat ABI.
 * The original html_load above is left as historical reference;
 * its `struct textbox_cursor *` API isn't actually defined in
 * this jserv tree, so it never compiled into a real loader.
 * ============================================================ */

#include <pgserver/textbox.h>

/* Decode one HTML entity starting at *pp (just past the '&').
 * Advance *pp past the trailing ';' (or to next char if the entity
 * ran off the end / was malformed).  Returns the decoded codepoint,
 * or 0 to indicate "emit nothing". */
static unsigned be300_html_entity(const unsigned char **pp,
                                  const unsigned char *end) {
  const unsigned char *p = *pp;
  const unsigned char *q;
  char name[12];
  size_t n;
  unsigned cp = 0;

  /* Find the terminating ';' within 10 chars. */
  for (q = p; q < end && q < p + 10; q++)
    if (*q == ';' || *q == '&' || *q == '<' || *q <= ' ')
      break;

  /* Numeric: &#NNN; or &#xHH; */
  if (p < end && *p == '#') {
    p++;
    if (p < end && (*p == 'x' || *p == 'X')) {
      p++;
      while (p < q) {
        unsigned d;
        if (*p >= '0' && *p <= '9') d = *p - '0';
        else if (*p >= 'a' && *p <= 'f') d = 10 + (*p - 'a');
        else if (*p >= 'A' && *p <= 'F') d = 10 + (*p - 'A');
        else break;
        cp = (cp << 4) | d;
        p++;
      }
    } else {
      while (p < q && *p >= '0' && *p <= '9') {
        cp = cp * 10 + (*p - '0');
        p++;
      }
    }
    if (q < end && *q == ';') q++;
    *pp = q;
    if (cp == 0xa0) return ' ';
    return cp;
  }

  /* Named entity. */
  n = (size_t)(q - p);
  if (n >= sizeof(name)) n = sizeof(name) - 1;
  memcpy(name, p, n);
  name[n] = 0;
  if (q < end && *q == ';') q++;
  *pp = q;

  if (!strcmp(name, "amp"))   return '&';
  if (!strcmp(name, "lt"))    return '<';
  if (!strcmp(name, "gt"))    return '>';
  if (!strcmp(name, "quot"))  return '"';
  if (!strcmp(name, "apos"))  return '\'';
  if (!strcmp(name, "nbsp"))  return ' ';
  if (!strcmp(name, "copy"))  return 0xa9;
  if (!strcmp(name, "reg"))   return 0xae;
  if (!strcmp(name, "trade")) return 0x2122;
  if (!strcmp(name, "hellip")) return 0x2026;
  if (!strcmp(name, "mdash")) return 0x2014;
  if (!strcmp(name, "ndash")) return 0x2013;
  if (!strcmp(name, "lsquo")) return 0x2018;
  if (!strcmp(name, "rsquo")) return 0x2019;
  if (!strcmp(name, "ldquo")) return 0x201c;
  if (!strcmp(name, "rdquo")) return 0x201d;
  if (!strcmp(name, "bull"))  return 0x2022;
  /* Unknown - skip silently. */
  return 0;
}

/* Insert one Unicode codepoint as UTF-8 into the document. */
static g_error be300_emit_codepoint(struct textbox_document *doc, unsigned cp) {
  unsigned char buf[5];
  int n;
  if (cp == 0) return success;
  if (cp < 0x80) {
    buf[0] = (unsigned char)cp;
    n = 1;
  } else if (cp < 0x800) {
    buf[0] = (unsigned char)(0xc0 | (cp >> 6));
    buf[1] = (unsigned char)(0x80 | (cp & 0x3f));
    n = 2;
  } else if (cp < 0x10000) {
    buf[0] = (unsigned char)(0xe0 | (cp >> 12));
    buf[1] = (unsigned char)(0x80 | ((cp >> 6) & 0x3f));
    buf[2] = (unsigned char)(0x80 | (cp & 0x3f));
    n = 3;
  } else {
    buf[0] = (unsigned char)(0xf0 | (cp >> 18));
    buf[1] = (unsigned char)(0x80 | ((cp >> 12) & 0x3f));
    buf[2] = (unsigned char)(0x80 | ((cp >> 6) & 0x3f));
    buf[3] = (unsigned char)(0x80 | (cp & 0x3f));
    n = 4;
  }
  buf[n] = 0;
  {
    g_error e;
    struct pgstring *tmp;
    e = pgstring_new(&tmp, PGSTR_ENCODE_UTF8, n, (const char *)buf);
    if (iserror(e)) return e;
    e = document_insert_string(doc, tmp);
    pgstring_delete(tmp);
    return e;
  }
}

/* Insert a literal ASCII char without entity decoding. */
static g_error be300_emit_ascii(struct textbox_document *doc, char ch) {
  return be300_emit_codepoint(doc, (unsigned char)ch);
}

/* Insert a paragraph break.  document_insert_paragraph is what
 * plaintext_load implicitly uses; we emit '\n' which the
 * document_insert_char path turns into a paragraph split. */
static g_error be300_emit_break(struct textbox_document *doc) {
  return document_insert_char(doc, '\n', NULL);
}

/* Compare a tag name (lowercased) against a literal.  Tag names are
 * the bytes between '<' (or '</') and the first whitespace or '>'. */
static int be300_tag_eq(const unsigned char *tag, size_t taglen,
                        const char *lit) {
  size_t i;
  size_t n = strlen(lit);
  if (taglen != n) return 0;
  for (i = 0; i < n; i++) {
    unsigned char c = tag[i];
    if (c >= 'A' && c <= 'Z') c = (unsigned char)(c + 32);
    if (c != (unsigned char)lit[i]) return 0;
  }
  return 1;
}

/* Tags that should produce a paragraph break before/after their content. */
static int be300_is_block_tag(const unsigned char *tag, size_t taglen) {
  /* Strip optional leading '/' for closing tags. */
  if (taglen > 0 && tag[0] == '/') { tag++; taglen--; }
  return be300_tag_eq(tag, taglen, "p")
      || be300_tag_eq(tag, taglen, "br")
      || be300_tag_eq(tag, taglen, "hr")
      || be300_tag_eq(tag, taglen, "div")
      || be300_tag_eq(tag, taglen, "li")
      || be300_tag_eq(tag, taglen, "tr")
      || be300_tag_eq(tag, taglen, "h1")
      || be300_tag_eq(tag, taglen, "h2")
      || be300_tag_eq(tag, taglen, "h3")
      || be300_tag_eq(tag, taglen, "h4")
      || be300_tag_eq(tag, taglen, "h5")
      || be300_tag_eq(tag, taglen, "h6")
      || be300_tag_eq(tag, taglen, "pre")
      || be300_tag_eq(tag, taglen, "ul")
      || be300_tag_eq(tag, taglen, "ol")
      || be300_tag_eq(tag, taglen, "dl")
      || be300_tag_eq(tag, taglen, "dt")
      || be300_tag_eq(tag, taglen, "dd")
      || be300_tag_eq(tag, taglen, "blockquote")
      || be300_tag_eq(tag, taglen, "table")
      || be300_tag_eq(tag, taglen, "title");  /* title closer => break */
}

/* Tags whose content we should drop entirely (no text emission). */
static int be300_is_drop_tag(const unsigned char *tag, size_t taglen) {
  if (taglen > 0 && tag[0] == '/') return 0;  /* close tag handled separately */
  return be300_tag_eq(tag, taglen, "script")
      || be300_tag_eq(tag, taglen, "style")
      || be300_tag_eq(tag, taglen, "head");
}

g_error html_load_be300(struct textbox_document *doc, struct pgstring *str) {
  const unsigned char *data;
  const unsigned char *end;
  const unsigned char *p;
  g_error e;
  int in_drop = 0;            /* dropping bytes inside <script>/<style>/<head> */
  unsigned char drop_close[16];
  size_t drop_close_n = 0;
  int last_was_space = 1;     /* avoid leading whitespace; collapse runs */
  int saw_block_break = 1;    /* avoid multiple consecutive breaks */

  if (!str || !str->buffer || str->num_bytes == 0) return success;

  data = (const unsigned char *)str->buffer;
  end  = data + str->num_bytes;
  p    = data;

  while (p < end) {
    unsigned char ch = *p;

    if (ch == '<') {
      const unsigned char *tag_start;
      const unsigned char *tag_name_start;
      size_t tag_name_len;
      const unsigned char *gt;
      int is_close;

      tag_start = p + 1;
      /* Skip <!-- ... --> comments and <!DOCTYPE ...> directives. */
      if (tag_start + 3 < end && tag_start[0] == '!' &&
          tag_start[1] == '-' && tag_start[2] == '-') {
        const unsigned char *q = tag_start + 3;
        while (q + 2 < end &&
               !(q[0] == '-' && q[1] == '-' && q[2] == '>')) q++;
        p = (q + 2 < end) ? q + 3 : end;
        continue;
      }
      if (tag_start < end && tag_start[0] == '!') {
        const unsigned char *q = tag_start;
        while (q < end && *q != '>') q++;
        p = (q < end) ? q + 1 : end;
        continue;
      }

      /* Find the matching '>'. */
      gt = tag_start;
      while (gt < end && *gt != '>') {
        /* '"' or "'" can quote a '>'.  Skip the quoted span. */
        if (*gt == '"' || *gt == '\'') {
          unsigned char q = *gt++;
          while (gt < end && *gt != q) gt++;
          if (gt < end) gt++;
          continue;
        }
        gt++;
      }
      if (gt >= end) {
        /* Unterminated tag - bail, drop the rest. */
        break;
      }

      /* Identify the tag name. */
      is_close = (tag_start < gt && tag_start[0] == '/');
      tag_name_start = is_close ? tag_start + 1 : tag_start;
      tag_name_len = 0;
      while (tag_name_start + tag_name_len < gt) {
        unsigned char c = tag_name_start[tag_name_len];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '/') break;
        tag_name_len++;
      }

      if (in_drop) {
        /* Looking for the matching close tag. */
        if (is_close && tag_name_len == drop_close_n &&
            be300_tag_eq(tag_name_start, tag_name_len, (const char *)drop_close)) {
          in_drop = 0;
          drop_close_n = 0;
        }
        p = gt + 1;
        continue;
      }

      if (!is_close && be300_is_drop_tag(tag_name_start, tag_name_len)) {
        size_t i;
        in_drop = 1;
        drop_close_n = tag_name_len;
        if (drop_close_n >= sizeof(drop_close)) drop_close_n = sizeof(drop_close) - 1;
        for (i = 0; i < drop_close_n; i++) {
          unsigned char c = tag_name_start[i];
          if (c >= 'A' && c <= 'Z') c = (unsigned char)(c + 32);
          drop_close[i] = c;
        }
        drop_close[drop_close_n] = 0;
        p = gt + 1;
        continue;
      }

      /* Block-level tag => emit a paragraph break, but not duplicates. */
      if (be300_is_block_tag(tag_name_start - (is_close ? 1 : 0),
                             tag_name_len + (is_close ? 1 : 0))) {
        if (!saw_block_break) {
          e = be300_emit_break(doc);
          if (iserror(e)) return e;
          saw_block_break = 1;
          last_was_space = 1;
        }
      }
      /* All other tags are skipped silently. */
      p = gt + 1;
      continue;
    }

    if (ch == '&') {
      unsigned cp;
      const unsigned char *q = p + 1;
      cp = be300_html_entity(&q, end);
      p = q;
      if (cp == 0) continue;
      if (cp == ' ') {
        if (last_was_space) continue;
        e = be300_emit_ascii(doc, ' ');
        if (iserror(e)) return e;
        last_was_space = 1;
        saw_block_break = 0;
        continue;
      }
      e = be300_emit_codepoint(doc, cp);
      if (iserror(e)) return e;
      last_was_space = 0;
      saw_block_break = 0;
      continue;
    }

    /* Whitespace collapse. */
    if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' || ch == '\v') {
      if (!last_was_space) {
        e = be300_emit_ascii(doc, ' ');
        if (iserror(e)) return e;
        last_was_space = 1;
      }
      p++;
      continue;
    }

    /* Plain ASCII / UTF-8 byte - emit as-is. */
    e = be300_emit_ascii(doc, (char)ch);
    if (iserror(e)) return e;
    last_was_space = 0;
    saw_block_break = 0;
    p++;
  }

  return success;
}
"""
    text = text.rstrip() + "\n" + appended
    write_text(html_c, text)

    # Forward-declare html_load_be300 in textbox.h so document_load
    # callers see it.
    th = root / "pg1" / "server" / "include" / "pgserver" / "textbox.h"
    if th.exists():
        thtext = read_text(th)
        if "html_load_be300" not in thtext:
            insertion = "\n/* BE-300: working HTML textformat loader (formats/html.c). */\n" \
                        "g_error html_load_be300(struct textbox_document *doc, struct pgstring *str);\n"
            thtext = thtext.replace(
                "extern struct txtformat text_formats[];",
                "extern struct txtformat text_formats[];" + insertion,
                1)
            write_text(th, thtext)

    # Rewire text_formats so "html" hits html_load_be300 instead of
    # plaintext_load.
    td = root / "pg1" / "server" / "widget" / "textbox_document.c"
    if td.exists():
        tdtext = read_text(td)
        old = (
            "#ifdef CONFIG_FORMAT_HTML\n"
            "  /* HTML not working yet, but plaintext is better than nothing :) */\n"
            "  // { \"html\", &html_load, &html_save },\n"
            "  { \"html\", &plaintext_load, &plaintext_save },\n"
            "#endif\n"
        )
        new = (
            "#ifdef CONFIG_FORMAT_HTML\n"
            "  /* BE-300: html_load_be300 strips tags + decodes entities into\n"
            "   * paragraphs.  The original html_load above is left for\n"
            "   * historical reference; its API never compiled in this tree. */\n"
            "  { \"html\", &html_load_be300, &plaintext_save },\n"
            "#endif\n"
        )
        if old in tdtext:
            tdtext = tdtext.replace(old, new, 1)
            write_text(td, tdtext)
    return True


def patch_appmgr_normal_recalc(root: Path) -> bool:
    """Force a divtree recalc when PG_APP_NORMAL apps register.

    pg1/server/appmgr/panel.c:appmgr_panel_reg has two branches:

      case PG_APP_TOOLBAR:                 case PG_APP_NORMAL:
        ...                                  ...
        if (popup_toolbar_passthrough()) {   /* nothing here */
          for (tree...) {                    break;
            tree->flags |= NEED_RECALC |
                           ALL_REDRAW |
                           CLIP_POPUP;
          }
        }
        break;

    Without the recalc, a freshly-registered PG_APP_NORMAL panel sits in
    the divtree at the rolled-up minimum size that panel_install set on
    construction.  appmgr_panel_reg's later widget_set(..,PG_WP_SIZE,
    default_size.h) updates the property but doesn't trigger a layout
    pass, so the panel is never drawn.

    Symptom on the BE-300: launching atomicnav from omnibar shows nothing
    on screen.  Launching pgboard afterwards makes atomicnav suddenly
    appear, because pgboard is PG_APP_TOOLBAR and IT triggers the
    recalc -- which then lays out the previously-stuck atomicnav panel.
    """
    src = root / "pg1" / "server" / "appmgr" / "panel.c"
    if not src.exists():
        return False
    text = read_text(src)
    if "BE300_NORMAL_RECALC_V3" in text:
        return False
    # If the V1 marker is present (older revision of this patch), strip
    # the stale block first so V2 (which calls update()) replaces it.
    if "BE300_NORMAL_RECALC" in text:
        old_block_start = text.find("    /* BE300_NORMAL_RECALC")
        old_block_end = text.find("    break;\n", old_block_start) + len("    break;\n")
        if old_block_start > 0 and old_block_end > old_block_start:
            text = text[:old_block_start] + "    break;\n" + text[old_block_end:]

    needle = (
        "    e = widget_set(w,PG_WP_SIZE,(i->side & (PG_S_LEFT|PG_S_RIGHT)) ? \n"
        "\t\t   i->default_size.w : i->default_size.h);\n"
        "    errorcheck;\n"
        "\n"
        "    w->isroot = 1;\n"
        "    break;\n"
        "\n"
        "  default:\n"
        "    return mkerror(PG_ERRT_BADPARAM,30);  /* Nonexistant app type */\n"
        "  }"
    )
    replacement = (
        "    e = widget_set(w,PG_WP_SIZE,(i->side & (PG_S_LEFT|PG_S_RIGHT)) ? \n"
        "\t\t   i->default_size.w : i->default_size.h);\n"
        "    errorcheck;\n"
        "\n"
        "    w->isroot = 1;\n"
        "\n"
        "    /* BE300_NORMAL_RECALC_V3: force divtree recalc + redraw + an\n"
        "     * immediate update().  Without this the freshly-registered\n"
        "     * panel stays at panel_install()'s rolled-up minimum height\n"
        "     * because nothing triggers a layout pass to honour the SIZE\n"
        "     * we just set.  Symptom: the app's window is invisible until\n"
        "     * some later toolbar registration triggers a recalc on its\n"
        "     * behalf.  The PG_APP_TOOLBAR branch above only sets flags\n"
        "     * because the appmgr_panel_init+toolbar registration path\n"
        "     * already runs through update(); for PG_APP_NORMAL there's\n"
        "     * no such path, so we have to drive update() ourselves. */\n"
        "    {\n"
        "      struct divtree *tree;\n"
        "      for (tree = dts->top; tree; tree = tree->next) {\n"
        "        tree->head->flags |= DIVNODE_NEED_RECALC;\n"
        "        tree->flags |= DIVTREE_NEED_RECALC | DIVTREE_ALL_REDRAW |\n"
        "                       DIVTREE_NEED_RESIZE;\n"
        "      }\n"
        "      update(NULL, 1);\n"
        "    }\n"
        "    break;\n"
        "\n"
        "  default:\n"
        "    return mkerror(PG_ERRT_BADPARAM,30);  /* Nonexistant app type */\n"
        "  }"
    )
    if needle not in text:
        return False
    text = text.replace(needle, replacement, 1)
    write_text(src, text)
    return True


def patch_pgserver_png_link_order(root: Path) -> bool:
    """Reorder picogui server's PNG link libs so static linking resolves.

    pg1/server/configure.ac sets `DRIVER_LIBS="$DRIVER_LIBS -lm -lz -lpng"`,
    which is the wrong order when linking against static .a archives:
    libpng references zlib's deflate(), and on the static-link path
    ld walks the archive list once left-to-right, so -lpng has to come
    BEFORE -lz.  Without the reorder pgserver fails to link with
    "undefined reference to `deflate'".
    """
    src = root / "pg1" / "server" / "configure.ac"
    if not src.exists():
        return False
    text = read_text(src)
    needle = 'DRIVER_LIBS="$DRIVER_LIBS -lm -lz -lpng"'
    if needle not in text:
        return False
    text = text.replace(needle,
                        'DRIVER_LIBS="$DRIVER_LIBS -lpng -lz -lm"', 1)
    # Also patch the generated configure script in case autoreconf was
    # already run by an earlier build phase that didn't pick up the .ac change.
    write_text(src, text)
    cfg = root / "pg1" / "server" / "configure"
    if cfg.exists():
        cfg_text = read_text(cfg)
        if needle in cfg_text:
            cfg_text = cfg_text.replace(needle,
                                        'DRIVER_LIBS="$DRIVER_LIBS -lpng -lz -lm"', 1)
            write_text(cfg, cfg_text)
    return True


def patch_atomicnav_kmsg_trace(root: Path) -> bool:
    """Add /dev/kmsg tracing to atomicnav so we can see why it shows 'error 1003'.

    atomicnav's stderr goes to /tmp/atomicnav.log via the start-picogui
    redirection, but it stays buffered until the process exits cleanly.
    Since pgserver-on-BE300 holds atomicnav alive indefinitely, the log
    is empty when we want to inspect it.

    Open /dev/kmsg O_NONBLOCK once at startup and write status / URL
    transitions / errors directly to it.  Survives the buffering issue
    and shows up in the kernel ring buffer for the boot trace to
    capture.
    """
    main = root / "pg1" / "apps" / "dev" / "atomicnav" / "main.c"
    if not main.exists():
        return False
    text = read_text(main)
    if "be300_anv_kmsg" in text:
        return False

    # Add a kmsg helper near the top of main.c, after the includes.
    helper = """
/* BE300_ANV_TRACE: write progress to /dev/kmsg unbuffered. */
#include <fcntl.h>
#include <unistd.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
void be300_anv_kmsg(const char *fmt, ...) {
  static int kmfd = -2;
  char buf[200];
  va_list ap;
  int n;
  if (kmfd == -2) kmfd = open("/dev/kmsg", O_WRONLY | O_NONBLOCK);
  if (kmfd < 0) return;
  va_start(ap, fmt);
  n = vsnprintf(buf, sizeof(buf), fmt, ap);
  va_end(ap);
  if (n > 0) write(kmfd, buf, (n < (int)sizeof(buf)) ? n : (int)sizeof(buf));
}
"""
    text = text.replace(
        "int main(int argc, char **argv) {",
        helper + "\nint main(int argc, char **argv) {\n  be300_anv_kmsg(\"[anv] main entry\\n\");",
        1,
    )
    text = text.replace(
        "  if (argv[1])",
        "  be300_anv_kmsg(\"[anv] win=%d argc=%d argv1=%s run_eventloop=%d\\n\", (int)win, argc, argv[1] ? argv[1] : \"(null)\", run_eventloop);\n  if (argv[1])",
        1,
    )
    # Force a pgUpdate after browserwin_new so the panel's allocated
    # area actually gets rendered.  pgEventLoop normally calls update
    # on its first idle, but on this build the panel sometimes stays
    # 0-height until something explicitly forces a recalc.
    text = text.replace(
        "  if (run_eventloop) {",
        "  pgUpdate();\n  be300_anv_kmsg(\"[anv] post-update; entering loop\\n\");\n"
        "  if (run_eventloop) {",
        1,
    )
    write_text(main, text)

    # Also instrument browserwin.c showstatus + errormsg.
    bw = root / "pg1" / "apps" / "dev" / "atomicnav" / "browserwin.c"
    if bw.exists():
        bwtext = read_text(bw)
        if "be300_anv_kmsg" not in bwtext:
            bwtext = bwtext.replace(
                "void browserwin_showstatus(",
                "extern void be300_anv_kmsg(const char *fmt, ...);\n"
                "void browserwin_showstatus(",
                1,
            )
            bwtext = bwtext.replace(
                "  if (u) {\n"
                "    w->status = u->status;\n",
                "  if (u) {\n"
                "    be300_anv_kmsg(\"[anv] showstatus url=%s status=%d progress=%d size=%lu\\n\",\n"
                "                   u->name ? u->name : \"(null)\",\n"
                "                   u->status, u->progress, u->size);\n"
                "    w->status = u->status;\n",
                1,
            )
            bwtext = bwtext.replace(
                "void browserwin_errormsg(struct browserwin *w, const char *msg) {",
                "void browserwin_errormsg(struct browserwin *w, const char *msg) {\n"
                "  be300_anv_kmsg(\"[anv] errormsg: %s\\n\", msg ? msg : \"(null)\");",
                1,
            )
            # Trace browserwin_new entry + key widget handles
            bwtext = bwtext.replace(
                "struct browserwin *browserwin_new(void) {",
                "struct browserwin *browserwin_new(void) {\n"
                "  be300_anv_kmsg(\"[anv] browserwin_new: building widgets\\n\");",
                1,
            )
            bwtext = bwtext.replace(
                "  /* Top-level widgets */",
                "  /* Top-level widgets */\n"
                "  be300_anv_kmsg(\"[anv] browserwin_new: about to pgRegisterApp\\n\");",
                1,
            )
            # No client-side size/side overrides needed.  The fix lives
            # in appmgr/panel.c (patch_appmgr_normal_recalc) where
            # PG_APP_NORMAL registration now triggers a divtree recalc
            # the same way PG_APP_TOOLBAR registration does.
            bwtext = bwtext.replace(
                'w->wApp = pgRegisterApp(PG_APP_NORMAL,BROWSER_TITLE,0);',
                'w->wApp = pgRegisterApp(PG_APP_NORMAL,BROWSER_TITLE,0);\n'
                '  be300_anv_kmsg("[anv] pgRegisterApp returned wApp=%d\\n", (int)w->wApp);',
                1,
            )
            write_text(bw, bwtext)

    # Instrument p_http.c too.
    ph = root / "pg1" / "apps" / "dev" / "atomicnav" / "p_http.c"
    if ph.exists():
        phtext = read_text(ph)
        if "be300_anv_kmsg" not in phtext:
            phtext = phtext.replace(
                "void p_http_connect(struct url *u) {",
                "extern void be300_anv_kmsg(const char *fmt, ...);\n"
                "void p_http_connect(struct url *u) {\n"
                "  be300_anv_kmsg(\"[anv] http_connect url=%s server=%s port=%d path=%s\\n\",\n"
                "                 u->name ? u->name : \"(null)\",\n"
                "                 u->server ? u->server : \"(null)\",\n"
                "                 u->port,\n"
                "                 u->path ? u->path : \"(null)\");",
                1,
            )
            write_text(ph, phtext)

    # Instrument url.c so we can see what u->name parses to.
    urlc = root / "pg1" / "apps" / "dev" / "atomicnav" / "url.c"
    if urlc.exists():
        utext = read_text(urlc)
        if "be300_anv_kmsg" not in utext:
            utext = utext.replace(
                'browserwin_errormsg(browser,"Unsupported protocol.");',
                'be300_anv_kmsg("[anv] unsupported protocol for url\\n");\n'
                '    browserwin_errormsg(browser,"Unsupported protocol.");',
                1,
            )
            write_text(urlc, utext)
    return True


def patch_omnibar_appmenu_dir(root: Path) -> bool:
    """Make omnibar's app menu robust on the BE-300 rootfs.

    omnibar.c:btnAppMenu() opens the relative path "demos" with no NULL
    check, then immediately calls rewinddir() / readdir() on the result.
    On the BE-300 the working directory at launch is "/" so opendir("demos")
    returns NULL and rewinddir(NULL) SEGVs the process — which is what the
    user sees when they tap the App Menu button on the omnibar.

    Two changes:
      1. Scan /usr/share/picogui/appmenu (the same dir omnibar already
         expects to find <name>.app launchers under), so the directory
         actually exists at runtime.
      2. NULL-check the opendir result so a missing directory just
         produces an empty menu instead of crashing.
    """
    src = root / "pg1" / "apps" / "test" / "omnibar" / "omnibar.c"
    if not src.exists():
        return False
    text = read_text(src)
    if "be300_appmenu_path" in text:
        return False

    needle = (
        '  d = opendir("demos");\n\n'
        '  /* FIXME : Count the items and allocate the array */\n'
        '  items = alloca(sizeof(pghandle) * 40);\n'
    )
    if needle not in text:
        return False
    replacement = (
        '  /* BE-300: relative "demos" dir does not exist at our launch CWD ("/"),\n'
        '   * which left opendir() returning NULL and rewinddir(NULL) below\n'
        '   * SEGVing the process. Use the same absolute path the .app launchers\n'
        '   * already live under, and NULL-check the directory. */\n'
        '  static const char be300_appmenu_path[] = "/usr/share/picogui/appmenu";\n'
        '  d = opendir(be300_appmenu_path);\n'
        '\n'
        '  /* FIXME : Count the items and allocate the array */\n'
        '  items = alloca(sizeof(pghandle) * 40);\n'
    )
    text = text.replace(needle, replacement, 1)

    # Wrap rewinddir/readdir in `if (d) { ... }` so a missing dir is harmless.
    rewind_needle = (
        '  /* Make handles */\n'
        '  rewinddir(d);\n'
        '  i = 0;\n'
        '  while (dent = readdir(d)) {\n'
    )
    rewind_replacement = (
        '  /* Make handles */\n'
        '  i = 0;\n'
        '  if (d) {\n'
        '  rewinddir(d);\n'
        '  while ((dent = readdir(d))) {\n'
    )
    if rewind_needle in text:
        text = text.replace(rewind_needle, rewind_replacement, 1)
        # Close the new `if (d) {` block before pgMenuFromArray.
        end_needle = (
            '  /* Run it */\n'
            '  i = pgMenuFromArray(items,i);\n'
        )
        if end_needle in text:
            text = text.replace(end_needle,
                                '  } /* end if (d) */\n\n' + end_needle, 1)

    # Also guard closedir at function end.
    text = text.replace('  closedir(d);\n',
                        '  if (d) closedir(d);\n', 1)

    write_text(src, text)
    return True


def patch_disable_sigalrm_timer(root: Path) -> bool:
    """Replace pgserver's SIGALRM-driven timer with a select-loop tick.

    On the BE-300 + uClibc-ng + soft-float MIPS build, returning from a
    SIGALRM handler reliably faults at NULL+8 (some sigreturn corner
    case we never narrowed down — see project_picogui_sigalrm_fix.md).
    cursorhide=0 in pgserverrc dodged the one common SIGALRM source,
    but the moment any widget calls install_timer() (terminal cursor
    flash, textbox cursor, scroll autoscroll, textedit cursor) the
    timer is re-armed and we crash again.

    Fix at the root: stub out os_set_timer's setitimer call so SIGALRM
    is never armed, and instead drive master_timer from net_iteration
    by clamping select()'s timeout to the next pending timer.  This is
    the same approach used by event-loop-based GUIs (Qt, Gtk) and
    avoids the entire signal-return code path.
    """
    posix = root / "pg1" / "server" / "os" / "posix.c"
    if not posix.exists():
        return False
    text = read_text(posix)
    if "BE300_NO_SIGALRM" in text:
        return False

    needle = (
        "void os_set_timer(u32 ticks) {\n"
        "  struct itimerval itv;\n"
        "  memset(&itv,0,sizeof(struct itimerval));\n"
        "  os_posix_timer = ticks;\n"
        "\n"
        "  if (ticks) {\n"
        "    ticks -= os_getticks();\n"
        "    itv.it_value.tv_sec  = (ticks/1000);\n"
        "    itv.it_value.tv_usec = (ticks%1000)*1000;\n"
        "  }\n"
        "  setitimer(ITIMER_REAL,&itv,NULL);\n"
        "}"
    )
    replacement = (
        "void os_set_timer(u32 ticks) {\n"
        "  /* BE300_NO_SIGALRM: store the deadline only.  net_iteration's\n"
        "   * select() timeout is capped at this value so master_timer is\n"
        "   * driven from the main loop instead of from a SIGALRM handler. */\n"
        "  os_posix_timer = ticks;\n"
        "  (void)0;  /* setitimer call removed - see patch_disable_sigalrm_timer */\n"
        "}"
    )
    if needle not in text:
        return False
    text = text.replace(needle, replacement, 1)
    write_text(posix, text)

    # Now have net_iteration call master_timer when the stored deadline
    # has been reached.  Inject a check at the very start of net_iteration
    # plus clamp select's timeout to the deadline.
    request = root / "pg1" / "server" / "net" / "request.c"
    if not request.exists():
        return False
    rtext = read_text(request)
    if "BE300_TIMER_POLL" in rtext:
        return False

    rneedle = (
        "  /* Default timeout */\n"
        "  tv.tv_sec = 5;\n"
        "  tv.tv_usec = 0;\n"
    )
    rreplacement = (
        "  /* Default timeout */\n"
        "  tv.tv_sec = 5;\n"
        "  tv.tv_usec = 0;\n"
        "\n"
        "  /* BE300_TIMER_POLL: drive master_timer from the select loop\n"
        "   * instead of via SIGALRM.  Fire any expired timer first, then\n"
        "   * cap select()'s timeout so it wakes when the next one is due. */\n"
        "  {\n"
        "    extern void master_timer(void);\n"
        "    extern u32 os_get_timer(void);\n"
        "    extern u32 os_getticks(void);\n"
        "    u32 deadline = os_get_timer();\n"
        "    if (deadline) {\n"
        "      u32 now = os_getticks();\n"
        "      if (deadline <= now) {\n"
        "        master_timer();\n"
        "      } else {\n"
        "        u32 wait_ms = deadline - now;\n"
        "        if (wait_ms < 5000) {\n"
        "          tv.tv_sec  = wait_ms / 1000;\n"
        "          tv.tv_usec = (wait_ms % 1000) * 1000;\n"
        "        }\n"
        "      }\n"
        "    }\n"
        "  }\n"
    )
    if rneedle not in rtext:
        return False
    rtext = rtext.replace(rneedle, rreplacement, 1)
    write_text(request, rtext)
    return True


def patch_signals_kmsg_dump(root: Path) -> bool:
    """Make pgserver's SIGSEGV handler write fault info to /dev/kmsg.

    posix_signals.c already has a DEBUG_SIGTRACE-gated stderr fprintf for
    si_addr / si_code / etc., but stderr is buffered through libc and on a
    fatal signal the bytes don't always make it to the log file before the
    handler exits.  Add an unbuffered write to /dev/kmsg so the BE-300 boot
    trace always carries 'pgserver SIGSEGV at <addr>' for the signal handler
    to land on the kernel ring buffer.
    """
    src = root / "pg1" / "server" / "os" / "posix_signals.c"
    if not src.exists():
        return False
    text = read_text(src)
    if "BE300_KMSG_FAULT" in text:
        return False

    needle = "    /* Prevent infinite recursion */\n    if (lock++) break;\n"
    if needle not in text:
        return False

    inject = (
        "    /* BE300_KMSG_FAULT: dump si_addr to /dev/kmsg unbuffered so the\n"
        "     * boot trace always carries the faulting address even when stderr\n"
        "     * is lost before the handler exits. */\n"
        "    {\n"
        "      int kmfd = open(\"/dev/kmsg\", O_WRONLY|O_NONBLOCK);\n"
        "      if (kmfd >= 0) {\n"
        "        char km[160];\n"
        "        int kn;\n"
        "        kn = snprintf(km, sizeof(km),\n"
        "                      \"[pgserver] FATAL sig=%d si_addr=%p si_code=%d pid=%d\\n\",\n"
        "                      sig,\n"
        "                      (void*)(siginfo ? siginfo->si_addr : (void*)0),\n"
        "                      siginfo ? siginfo->si_code : -1,\n"
        "                      (int)getpid());\n"
        "        if (kn > 0) write(kmfd, km, kn);\n"
        "        close(kmfd);\n"
        "      }\n"
        "    }\n"
    )
    text = text.replace(needle, needle + inject, 1)

    # Ensure unistd.h + fcntl.h + stdio.h are visible.
    if "#include <fcntl.h>" not in text:
        text = "#include <fcntl.h>\n" + text
    if "#include <unistd.h>" not in text:
        text = "#include <unistd.h>\n" + text
    write_text(src, text)
    return True


def patch_driverinfo_c(root: Path) -> bool:
    """Forward-declare evdev_regfunc in pg1/server/gcore/driverinfo.c.

    inputdrivers.inc lives inside an array initializer so it can't host
    declarations.  Add a CONFIG_DRIVER_EVDEV-gated extern just before the
    inputdrivers[] table so driverinfo.c compiles without the
    'expected expression before extern' error.
    """
    src = root / "pg1" / "server" / "gcore" / "driverinfo.c"
    if not src.exists():
        return False
    text = read_text(src)
    if "evdev_regfunc" in text:
        return False

    needle = "struct inputinfo inputdrivers[] = {"
    if needle not in text:
        return False
    insertion = (
        "/* BE-300 evdev driver forward decl - see board/picogui/evdev.c. */\n"
        "#ifdef CONFIG_DRIVER_EVDEV\n"
        "extern g_error evdev_regfunc(struct inlib *i);\n"
        "#endif\n\n"
    )
    text = text.replace(needle, insertion + needle, 1)
    write_text(src, text)
    return True


def patch_inputdrivers_inc(root: Path) -> bool:
    """Add evdev to pg1/server/gcore/inputdrivers.inc.

    inputdrivers.inc is `#include`'d inside `gcore/driverinfo.c` to
    populate the `inputdrivers[]` registry.  Each driver is registered
    via:

        #ifdef DRIVER_XYZ
          DRV("xyz", &xyz_regfunc)
        #endif

    Append the CONFIG_DRIVER_EVDEV variant at the end of the file
    (before the trailing comment marker).  Forward-declare
    evdev_regfunc so driverinfo.c compiles without -Wimplicit warnings.
    """
    inc = root / "pg1" / "server" / "gcore" / "inputdrivers.inc"
    if not inc.exists():
        return False
    text = read_text(inc)
    if "evdev_regfunc" in text:
        return False

    # NB: this file is `#include`d *inside* a `struct inputinfo
    # inputdrivers[] = { ... };` array initializer in driverinfo.c, so
    # only DRV() entries are syntactically allowed here.  The forward
    # declaration goes in patch_driverinfo_c instead.
    addition = (
        "\n"
        "/* BE-300 evdev driver - see board/picogui/evdev.c. */\n"
        "#ifdef CONFIG_DRIVER_EVDEV\n"
        "  DRV(\"evdev\", &evdev_regfunc)\n"
        "#endif\n"
    )
    # Insert before the "/* The End */" comment marker so the file's
    # canonical structure is preserved.
    if "/* The End */" in text:
        text = text.replace("/* The End */", addition + "\n/* The End */", 1)
    else:
        text = text.rstrip() + addition + "\n"
    write_text(inc, text)
    return True


def patch_makefile_am_subst_in_sources(root: Path) -> int:
    """Drop `$(VAR)` from `<lib>_la_SOURCES`; LIBADD already pulls the .lo files.

    automake 1.13+ refuses configure substitutions in any `_SOURCES`
    variant (`_SOURCES`, `dist_*_SOURCES`, `nodist_*_SOURCES`).  Picogui
    pre-1.13 Makefile.am files put AC_SUBSTed variables (WIDGET, VIDBASE,
    DRIVER, OS) directly in `_SOURCES`, which trips the strict check.

    All four affected libraries already have the correct mechanism:

        EXTRA_<lib>_la_SOURCES = a.c b.c c.c ...   # all candidates
        <lib>_la_LIBADD = $(VAR:%.c=%.lo)          # configure-selected
        <lib>_la_DEPENDENCIES = $(VAR:%.c=%.lo)

    EXTRA_*_SOURCES gives automake the compile rules for every candidate;
    LIBADD picks which .lo files to actually link based on the profile.
    Dropping `$(VAR)` from `_SOURCES` is sufficient.

    Returns count of files patched.
    """
    targets = [
        # (path, lib, var)
        (root / "pg1/server/widget/Makefile.am", "libwidget_la", "WIDGET"),
        (root / "pg1/server/video/Makefile.am", "libvideo_la", "DRIVER"),
        (root / "pg1/server/vidbase/Makefile.am", "libvidbase_la", "VIDBASE"),
        (root / "pg1/server/os/Makefile.am", "libos_la", "OS"),
        (root / "pg1/client/c/src/Makefile.am", "libpgui_la", "PLATFORM"),
    ]
    n = 0
    for path, lib, var in targets:
        if not path.exists():
            continue
        text = read_text(path)
        # If the substitution token is no longer present (re-run on patched
        # tree), skip.
        if f"$({var})" not in text:
            continue

        # Match `<lib>_SOURCES = <body> $(VAR)<eol>` capturing the body so
        # we can drop the `$(VAR)` line cleanly.
        pat = re.compile(
            r"(" + re.escape(lib) + r"_SOURCES\s*=\s*(?:\\\n[\s\S]*?)?)"
            r"\$\(" + re.escape(var) + r"\)\s*\n",
            re.MULTILINE,
        )
        m = pat.search(text)
        if not m:
            continue
        head = m.group(1)
        # Strip a trailing `\` (line continuation) from the last kept line
        # so the SOURCES variable terminates cleanly.
        head = re.sub(r"\\\s*\n([ \t]*)$", "\n", head, count=1)
        replacement = head.rstrip() + "\n"
        text = text[: m.start()] + replacement + text[m.end():]
        write_text(path, text)
        n += 1
    return n


def patch_select_in(root: Path) -> bool:
    """Add evdev.c to the INPUT section of pg1/server/select.in.

    select.in is the shell snippet sourced by configure to populate the
    `INPUT`, `WIDGET`, etc. AC_SUBST variables from the profile's
    CONFIG_* settings.  pg1/server/input/Makefile.am uses
    `libinput_la_LIBADD = $(INPUT:%.c=%.lo)` to actually link the
    selected drivers, so without an entry here our evdev.c would never
    get linked into libinput.la regardless of CONFIG_DRIVER_EVDEV=y.
    """
    sel = root / "pg1" / "server" / "select.in"
    if not sel.exists():
        return False
    text = read_text(sel)
    if "evdev.c" in text:
        return False

    needle = "add_if_true jsdev.c              $DRIVER_JSDEV\n"
    if needle not in text:
        return False
    addition = (
        needle
        + "add_if_true evdev.c              $CONFIG_DRIVER_EVDEV\n"
    )
    text = text.replace(needle, addition, 1)
    write_text(sel, text)
    return True


def patch_config_in(root: Path) -> bool:
    """Add CONFIG_DRIVER_EVDEV to pg1/server/config.in.

    config.in enumerates every recognized config token via lines like
    `bool 'description' TOKEN`. The Configure script reads this against
    the user's profile and emits config.h; entries in the profile that
    don't appear here are dropped silently.

    Inject our new bool right after DRIVER_JSDEV in the Input Drivers
    block so it sits next to the other Linux input pathways.
    """
    cfg = root / "pg1" / "server" / "config.in"
    if not cfg.exists():
        return False
    text = read_text(cfg)
    if "CONFIG_DRIVER_EVDEV" in text:
        return False

    needle = "bool 'Joystick driver'                                  DRIVER_JSDEV\n"
    addition = (
        needle
        + "bool 'BE-300 evdev (/dev/input/event*) input driver'    "
          "CONFIG_DRIVER_EVDEV\n"
    )
    if needle not in text:
        return False
    text = text.replace(needle, addition, 1)
    write_text(cfg, text)
    return True


def patch_server_configure(root: Path) -> bool:
    """Add CONFIG_DRIVER_EVDEV handling to pg1/server/configure.{in,ac}.

    The picogui server's configure reads the profile via --with-profile
    and bakes CONFIG_* keys into config.h.  For our new evdev driver
    we want:
      - AM_CONDITIONAL([CONFIG_DRIVER_EVDEV], [...])
      - AC_DEFINE([CONFIG_DRIVER_EVDEV], 1, ...) when set

    Both live alongside the existing CONFIG_DRIVER_* clauses so we add
    them as a small block at the end of configure.{in,ac}.
    """
    cfg = None
    for candidate in ("configure.ac", "configure.in"):
        p = root / "pg1" / "server" / candidate
        if p.exists():
            cfg = p
            break
    if cfg is None:
        return False
    text = read_text(cfg)
    if "CONFIG_DRIVER_EVDEV" in text:
        return False
    block = (
        "\n"
        "dnl BE-300 evdev driver - see board/picogui/evdev.c.\n"
        "AM_CONDITIONAL([CONFIG_DRIVER_EVDEV],\n"
        "  [test \"$CONFIG_DRIVER_EVDEV\" = y])\n"
        "if test \"$CONFIG_DRIVER_EVDEV\" = y; then\n"
        "  AC_DEFINE([CONFIG_DRIVER_EVDEV], [1],\n"
        "    [Define to 1 to build the BE-300 evdev input driver])\n"
        "fi\n"
    )
    text = text.rstrip() + block + "\n"
    write_text(cfg, text)
    return True


def patch_configure_script(root: Path) -> bool:
    """Make the Makefile invoke configscript/Configure via bash, not sh.

    pg1/server/include/pgserver/Makefile.am calls the script as
    `sh $(top_srcdir)/configscript/Configure ...`.  On Ubuntu /bin/sh
    is dash, which:
      - rejects `set -f -h` (line 65) with "Illegal option -h"
      - rejects `function foo() {` (Linux kernel-style menuconfig
        sugar) with "Syntax error: '(' unexpected"

    The script's shebang is `#! /bin/bash`; honor it by changing the
    Makefile's invocation from `sh` to `bash`.
    """
    mk = root / "pg1" / "server" / "include" / "pgserver" / "Makefile.am"
    if not mk.exists():
        return False
    text = read_text(mk)
    needle = "sh $(top_srcdir)/configscript/Configure"
    replacement = "bash $(top_srcdir)/configscript/Configure"
    if needle not in text:
        return False
    if replacement in text:
        return False
    text = text.replace(needle, replacement)
    write_text(mk, text)
    return True


def patch_grab_keynames_py(root: Path) -> bool:
    """Rewrite pg1/client/c/grab_keynames.py for Python 3 + use python3.

    Upstream uses Python 2 idioms throughout (`file()`, `print >> out`,
    `dict.has_key`).  Ubuntu 22.04 only ships python3 by default, and
    the Makefile.am rule explicitly runs `python` (which doesn't exist
    by default).  Replace the script with an equivalent Python 3
    version, and patch the Makefile to invoke python3.
    """
    script = root / "pg1" / "client" / "c" / "grab_keynames.py"
    mk = root / "pg1" / "client" / "c" / "src" / "Makefile.am"
    changed = False

    if script.exists():
        text = read_text(script)
        if "has_key" in text or "file (" in text or "print >>" in text:
            new_script = (
                "#!/usr/bin/env python3\n"
                "import sys, os\n"
                "\n"
                "if len(sys.argv) > 1:\n"
                "    pgkeys = open(sys.argv[1])\n"
                "else:\n"
                "    pgkeys = open('../../server/include/picogui/pgkeys.h')\n"
                "\n"
                "keynames = {}\n"
                "max_key = 0\n"
                "for line in pgkeys.readlines():\n"
                "    if not line.startswith('#define PGKEY'):\n"
                "        continue\n"
                "    parts = line.strip().split()[1:]\n"
                "    if parts[0] == 'PGKEY_MAX':\n"
                "        max_key = int(parts[1])\n"
                "        break\n"
                "    keynames[int(parts[1])] = parts[0][6:].lower()\n"
                "pgkeys.close()\n"
                "\n"
                "if not max_key:\n"
                "    max_key = max(keynames.keys())\n"
                "\n"
                "out = open('keynames.c', 'w')\n"
                "print('/*\\n"
                "* AUTO-GENERATED FILE, do not edit\\n"
                "*/\\n"
                "\\n"
                "char *_pgKeyNames[] = {', file=out)\n"
                "\n"
                "for i in range(max_key + 1):\n"
                "    if i in keynames:\n"
                "        s = '\"%s\",' % keynames[i]\n"
                "    else:\n"
                "        s = '\"\",'\n"
                "    print(s, ' ' * (50 - len(s)),\n"
                "          '/* %d */' % i, file=out)\n"
                "\n"
                "print('};', file=out)\n"
                "out.close()\n"
            )
            write_text(script, new_script)
            changed = True

    if mk.exists():
        text = read_text(mk)
        if "python grab_keynames.py" in text:
            text = text.replace(
                "python grab_keynames.py",
                "python3 grab_keynames.py",
            )
            write_text(mk, text)
            changed = True

    return changed


def patch_picogui_types_h(root: Path) -> bool:
    """Match picogui's __u32/__s32 types to Linux kernel UAPI on MIPS.

    pg1/server/include/picogui/types.h defines:
        typedef unsigned long __u32;
        typedef signed   long __s32;

    inside an `#if ... defined(_MIPS_ISA) ...` block.  But Linux kernel
    UAPI headers (used by video/fbdev.c via <linux/fb.h>) define the
    same names as `unsigned int` / `signed int`.  Even though both are
    32-bit on MIPS, GCC treats `unsigned long` and `unsigned int` as
    distinct types, so any file that includes both picogui/types.h and
    a kernel header fails with `conflicting types for '__u32'`.

    Match the kernel: rewrite `unsigned long`/`signed long` to
    `unsigned int`/`signed int` for __u32/__s32 on MIPS.
    """
    th = root / "pg1" / "server" / "include" / "picogui" / "types.h"
    if not th.exists():
        return False
    text = read_text(th)
    needle = (
        "typedef unsigned long __u32;\n"
        "typedef signed long __s32;\n"
    )
    replacement = (
        "typedef unsigned int __u32;\n"
        "typedef signed int __s32;\n"
    )
    if needle not in text:
        return False
    text = text.replace(needle, replacement, 1)
    write_text(th, text)
    return True


def patch_cast_as_lvalue(root: Path) -> int:
    """Rewrite GCC pre-C99 `(type *)ptr += N` and `*(((type *)ptr)++)`.

    Modern GCC (4.0+) removed the cast-as-lvalue extension.  Picogui's
    vidbase code relies on it heavily:

        (u8 *)dline += FB_BPL          ->  dline = (void *)((u8 *)dline + FB_BPL)
        (u8 *)dline -= FB_BPL          ->  dline = (void *)((u8 *)dline - FB_BPL)
        *(((unsigned char *)dest)++)   ->  *(unsigned char *)dest, then advance
        *(((u32 *)dest)++) = c         ->  *(u32 *)dest = c; dest = (char *)dest + sizeof(u32)
        c = *(((u16 *)src)++)          ->  c = *(u16 *)src; src = (char *)src + sizeof(u16)

    Returns count of substitutions applied across all files.
    """
    server = root / "pg1" / "server"
    if not server.is_dir():
        return 0

    pat_lvalue_assign = re.compile(
        r"\([A-Za-z_][A-Za-z0-9_ ]*?\s*\*\)\s*[A-Za-z_][A-Za-z0-9_]*\s*[+\-]="
    )
    pat_post_inc = re.compile(
        r"\(\s*\(\s*\(\s*[A-Za-z_][A-Za-z0-9_ ]*?\s*\*\s*\)\s*"
        r"[A-Za-z_][A-Za-z0-9_]*\s*\)\s*\+\+\s*\)"
    )

    n = 0
    for path in sorted(server.rglob("*.c")):
        text = read_text(path)
        if not (pat_lvalue_assign.search(text) or pat_post_inc.search(text)):
            continue
        orig = text

        # Pattern A: `(<type> *)<ident> += <expr>` and `-= <expr>`.
        # Capture a hopefully-safe `<type>` (single token, optionally const).
        text = re.sub(
            r"\(([A-Za-z_][A-Za-z0-9_ ]*?)\s*\*\)\s*([A-Za-z_][A-Za-z0-9_]*)\s*([+\-])=\s*",
            lambda m: (
                m.group(2) + "=(void*)((" + m.group(1) + " *)"
                + m.group(2) + " " + m.group(3) + " "
            ),
            text,
        )
        # Close the parenthesis we opened.  The lambda ate the
        # `+= <expr>` / `-= <expr>` separator and replaced it with
        # ` <op> ` so the original `<expr>` (and its terminator) follow.
        # The closing `))` is appended by a second pass that walks
        # forward to the next `,`, `;`, or `)` not nested inside our
        # rewrite — implement that explicitly:
        def close_pending(s: str) -> str:
            out = []
            i = 0
            while i < len(s):
                idx = s.find("(void*)((", i)
                if idx < 0:
                    out.append(s[i:])
                    break
                out.append(s[i:idx])
                # find the matching expr terminator at the same paren depth
                j = idx + len("(void*)((")
                depth = 2  # we've opened two parens already with `((`
                while j < len(s) and depth > 0:
                    c = s[j]
                    if c == "(":
                        depth += 1
                    elif c == ")":
                        depth -= 1
                        if depth == 0:
                            break  # surrounding context's `)` — stop before
                    elif c in ",;\n" and depth == 1:
                        break  # statement / for-clause terminator
                    j += 1
                # j now points at the terminator (or surrounding `)`).
                # depth is 1 (one of our `((` is still unclosed) — emit `)`.
                # The `(void*)` cast and any inner `(<type> *)` cast are
                # self-balanced.
                out.append(s[idx:j])
                out.append(")")
                i = j
            return "".join(out)

        text = close_pending(text)

        # Pattern B: `*(((<type> *)<ident>)++) = <expr>;`
        text = re.sub(
            r"\*\(\(\(\s*([A-Za-z_][A-Za-z0-9_ ]*?)\s*\*\s*\)\s*"
            r"([A-Za-z_][A-Za-z0-9_]*)\s*\)\s*\+\+\s*\)\s*=\s*([^;]+?);",
            r"*(\1 *)\2 = \3; \2 = (char *)\2 + sizeof(\1);",
            text,
        )

        # Pattern C: `<lhs> = *(((<type> *)<ident>)++);`
        text = re.sub(
            r"([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"
            r"\*\(\(\(\s*([A-Za-z_][A-Za-z0-9_ ]*?)\s*\*\s*\)\s*"
            r"([A-Za-z_][A-Za-z0-9_]*)\s*\)\s*\+\+\s*\)\s*;",
            r"\1 = *(\2 *)\3; \3 = (char *)\3 + sizeof(\2);",
            text,
        )

        if text != orig:
            write_text(path, text)
            n += 1
    return n


def fixup_kr_prototypes(root: Path) -> int:
    """Drop K&R / implicit-int patterns that GCC 12+ refuses by default.

    Each entry is keyed by a distinctive substring so re-running this is
    a no-op. Add new entries here as build failures surface.
    """
    fixes = []  # list of (relative_path, needle, replacement)
    n = 0
    for rel, needle, replacement in fixes:
        path = root / rel
        if not path.exists():
            continue
        text = read_text(path)
        if needle in text and replacement not in text:
            text = text.replace(needle, replacement, 1)
            write_text(path, text)
            n += 1
    return n


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: patch_picogui_sources.py <picogui-source-root>",
              file=sys.stderr)
        return 2

    root = Path(sys.argv[1])
    if not root.is_dir():
        print(f"error: {root} is not a directory", file=sys.stderr)
        return 1

    stamp = root / STAMP_NAME
    if stamp.exists():
        print(f"-- patches already applied (stamp {STAMP_NAME})")
        return 0

    n_renamed = rename_configure_in(root)
    n_modernized = modernize_autoconf(root)
    mk_ok = patch_input_makefile_am(root)
    fbclose_ok = patch_fbdev_close_no_clear(root)
    sigkmsg_ok = patch_signals_kmsg_dump(root)
    omnibar_ok = patch_omnibar_appmenu_dir(root)
    anvtrace_ok = patch_atomicnav_kmsg_trace(root)
    png_ok = patch_pgserver_png_link_order(root)
    normalrecalc_ok = patch_appmgr_normal_recalc(root)
    sigalrm_ok = patch_disable_sigalrm_timer(root)
    htmlload_ok = patch_html_load_be300(root)
    drvi_ok = patch_driverinfo_c(root)
    drv_ok = patch_inputdrivers_inc(root)
    cfg_ok = patch_server_configure(root)
    cfgin_ok = patch_config_in(root)
    selin_ok = patch_select_in(root)
    n_mk_subst = patch_makefile_am_subst_in_sources(root)
    cfgscript_ok = patch_configure_script(root)
    n_lvalue = patch_cast_as_lvalue(root)
    types_ok = patch_picogui_types_h(root)
    keynames_ok = patch_grab_keynames_py(root)
    n_kr = fixup_kr_prototypes(root)

    print(f"-- renamed {n_renamed} configure.in -> configure.ac")
    print(f"-- modernized {n_modernized} AM_CONFIG_HEADER -> AC_CONFIG_HEADERS")
    print(f"-- input/Makefile.am evdev wiring: "
          f"{'applied' if mk_ok else 'skipped'}")
    print(f"-- fbdev_close clear-screen disable: "
          f"{'applied' if fbclose_ok else 'skipped'}")
    print(f"-- posix_signals.c kmsg fault dump: "
          f"{'applied' if sigkmsg_ok else 'skipped'}")
    print(f"-- omnibar appmenu dir + NULL-check: "
          f"{'applied' if omnibar_ok else 'skipped'}")
    print(f"-- atomicnav /dev/kmsg trace: "
          f"{'applied' if anvtrace_ok else 'skipped'}")
    print(f"-- pgserver PNG link order (-lpng before -lz): "
          f"{'applied' if png_ok else 'skipped'}")
    print(f"-- appmgr_panel_reg PG_APP_NORMAL recalc fix: "
          f"{'applied' if normalrecalc_ok else 'skipped'}")
    print(f"-- pgserver SIGALRM->select-timeout timer: "
          f"{'applied' if sigalrm_ok else 'skipped'}")
    print(f"-- formats/html.c html_load_be300 + textformat: "
          f"{'applied' if htmlload_ok else 'skipped'}")
    print(f"-- gcore/driverinfo.c evdev forward decl: "
          f"{'applied' if drvi_ok else 'skipped'}")
    print(f"-- gcore/inputdrivers.inc evdev DRV() entry: "
          f"{'applied' if drv_ok else 'skipped'}")
    print(f"-- server configure.ac evdev block: "
          f"{'applied' if cfg_ok else 'skipped'}")
    print(f"-- server config.in evdev bool line: "
          f"{'applied' if cfgin_ok else 'skipped'}")
    print(f"-- server select.in evdev INPUT entry: "
          f"{'applied' if selin_ok else 'skipped'}")
    print(f"-- Makefile.am SUBST-in-SOURCES rewrites: {n_mk_subst}")
    print(f"-- include/pgserver/Makefile.am sh->bash for Configure: "
          f"{'applied' if cfgscript_ok else 'skipped'}")
    print(f"-- vidbase cast-as-lvalue rewrites: {n_lvalue} files")
    print(f"-- picogui/types.h __u32 unsigned long->int (MIPS): "
          f"{'applied' if types_ok else 'skipped'}")
    print(f"-- pg1/client/c/grab_keynames.py py3-ify: "
          f"{'applied' if keynames_ok else 'skipped'}")
    print(f"-- K&R/implicit-int fixups: {n_kr}")

    stamp.write_text("be300-picogui-patched\n", encoding="ascii")
    return 0


if __name__ == "__main__":
    sys.exit(main())
