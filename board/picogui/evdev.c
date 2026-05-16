/* PicoGUI evdev input driver — BE-300 port.
 *
 * Picogui upstream has no generic /dev/input/event* driver; the closest
 * existing entries (h3600ts.c, vr3ts.c, r3912ts.c) parse iPAQ / Agenda /
 * R3912 raw streams. This shim drives the standard Linux evdev interface
 * the BE-300 board exposes:
 *
 *   - touchscreen: "BE-300 PIU touchscreen" (event{0..7})
 *   - hardware buttons: "BE-300 Buttons"
 *   - optional Stowaway external keyboard: "Stowaway Keyboard"
 *
 * Wire format on Linux 4.2 / 32-bit MIPS / musl is the original 16-byte
 * record; modern userspace headers report a larger struct input_event
 * because of 64-bit time_t. Read into a fixed-size struct to dodge that.
 *
 * Translation:
 *   touch: ABS_X / ABS_Y / ABS_PRESSURE + BTN_TOUCH -> pointer +
 *          PG_TRIGGER_DOWN/UP via dispatch_pointing()
 *   keys:  EV_KEY -> PGKEY_* via evdev_to_pgkey() and dispatch_key()
 *
 * Registration: pgserver loads input drivers as modules; the upstream
 * macros require an `inputdrv` struct named "evdev_regfunc" and an
 * AC_CONFIG / Makefile.am hook gated on CONFIG_DRIVER_EVDEV. The
 * board/picogui/patch_picogui_sources.py script wires the latter; the
 * registrations below match what the (slightly variable) jserv tree
 * expects — adjust the symbol names if the fork renamed them.
 *
 * Copyright (C) 2026 John Roark
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */

#include <pgserver/common.h>
#include <pgserver/input.h>

#include <fcntl.h>
#include <stdarg.h>

/* Diagnostic: write a line to /dev/kmsg so it appears on the kernel
 * ring buffer / serial console.  Cheap, non-buffered, survives crashes. */
static void evdev_kmsg(const char *fmt, ...)
{
  static int kmsg_fd = -2;
  char buf[160];
  va_list ap;
  int n;

  if (kmsg_fd == -2)
    kmsg_fd = open("/dev/kmsg", O_WRONLY | O_NONBLOCK);
  if (kmsg_fd < 0)
    return;
  va_start(ap, fmt);
  n = vsnprintf(buf, sizeof(buf), fmt, ap);
  va_end(ap);
  if (n > 0 && n < (int)sizeof(buf))
    write(kmsg_fd, buf, n);
}
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <linux/input.h>

#define EVDEV_EVENT_FMT     "/dev/input/event%d"
#define EVDEV_MAX_EVENTS    8
#define EVDEV_NAME_MAX      80

#define EVDEV_NAME_TOUCH    "BE-300 PIU touchscreen"
#define EVDEV_NAME_BUTTONS  "BE-300 Buttons"
#define EVDEV_NAME_STOWAWAY "Stowaway Keyboard"

/* Linux 4.2 on 32-bit MIPS reports the original 16-byte evdev record. */
struct evdev_wire_event {
  int32_t  tv_sec;
  int32_t  tv_usec;
  uint16_t type;
  uint16_t code;
  int32_t  value;
};

/* Per-fd descriptor — one entry per matched input device. */
struct evdev_fd {
  int  fd;
  int  is_touch;    /* dispatch as pointer events */
  char name[EVDEV_NAME_MAX];
  char path[32];
};

static struct evdev_fd  g_fds[EVDEV_MAX_EVENTS];
static int              g_nfds;

/* Touch tracking state — picogui dispatches whole pointer packets, not
 * per-axis updates, so accumulate a packet then flush on EV_SYN. */
static int g_touch_x;
static int g_touch_y;
static int g_touch_pressed;     /* 1 between BTN_TOUCH 1 and 0 */
static int g_touch_have_xy;     /* 1 once we've seen ABS_X+ABS_Y at least once */
static int g_touch_packet_dirty;/* 1 if we've seen any ABS or BTN this packet */

/* Modifier bookkeeping for keys. */
static u32 g_mods;              /* current PGMOD_* mask */
static int g_caps_lock;

/* ------------------------------------------------------------------- */
/* Helpers                                                             */
/* ------------------------------------------------------------------- */

static int
add_fd(int fd, int is_touch, const char *path, const char *name)
{
  if (g_nfds >= EVDEV_MAX_EVENTS) {
    close(fd);
    return -1;
  }
  g_fds[g_nfds].fd = fd;
  g_fds[g_nfds].is_touch = is_touch;
  snprintf(g_fds[g_nfds].path, sizeof(g_fds[g_nfds].path), "%s", path);
  snprintf(g_fds[g_nfds].name, sizeof(g_fds[g_nfds].name), "%s", name);
  ioctl(fd, EVIOCGRAB, 1);
  g_nfds++;
  return 0;
}

/* Walk /dev/input/event[0..N], match by EVIOCGNAME. Same approach as
 * board/microwindows/{mou,kbd}_evdev.c so behavior is identical between
 * the two GUI profiles. */
static void
scan_input_devices(void)
{
  char path[sizeof(EVDEV_EVENT_FMT) + 4];
  char name[EVDEV_NAME_MAX];
  int  i, fd;
  int  is_touch;

  evdev_kmsg("[evdev] scan: looking for input devices\n");
  for (i = 0; i < EVDEV_MAX_EVENTS; i++) {
    snprintf(path, sizeof(path), EVDEV_EVENT_FMT, i);
    fd = open(path, O_RDONLY | O_NONBLOCK);
    if (fd < 0) {
      evdev_kmsg("[evdev] scan: %s: not present\n", path);
      continue;
    }

    memset(name, 0, sizeof(name));
    if (ioctl(fd, EVIOCGNAME(sizeof(name) - 1), name) < 0) {
      evdev_kmsg("[evdev] scan: %s: EVIOCGNAME failed\n", path);
      close(fd);
      continue;
    }
    evdev_kmsg("[evdev] scan: %s = '%s'\n", path, name);

    is_touch = (strcmp(name, EVDEV_NAME_TOUCH) == 0);
    if (is_touch ||
        strcmp(name, EVDEV_NAME_BUTTONS) == 0 ||
        strcmp(name, EVDEV_NAME_STOWAWAY) == 0) {
      add_fd(fd, is_touch, path, name);
      evdev_kmsg("[evdev] scan: matched %s -> fd=%d touch=%d\n",
                 name, fd, is_touch);
    } else {
      close(fd);
    }
  }
  evdev_kmsg("[evdev] scan done: %d devices matched\n", g_nfds);
}

/* PGKEY translation. Matches kbd_evdev.c so user-visible behavior is the
 * same on both GUI profiles. PGKEY_* constants live in pgserver/pgkeys.h
 * (included transitively via pgserver/input.h); the unprefixed PGKEY
 * codes are ASCII-compatible for printable characters. */
static u16
evdev_to_pgkey(u16 code)
{
  switch (code) {
  case KEY_ENTER:      return PGKEY_RETURN;
  case KEY_ESC:        return PGKEY_ESCAPE;
  case KEY_BACKSPACE:  return PGKEY_BACKSPACE;
  case KEY_TAB:        return PGKEY_TAB;
  case KEY_SPACE:      return PGKEY_SPACE;
  case KEY_UP:         return PGKEY_UP;
  case KEY_DOWN:       return PGKEY_DOWN;
  case KEY_LEFT:       return PGKEY_LEFT;
  case KEY_RIGHT:      return PGKEY_RIGHT;
  case KEY_HOME:       return PGKEY_HOME;
  case KEY_END:        return PGKEY_END;
  case KEY_PAGEUP:     return PGKEY_PAGEUP;
  case KEY_PAGEDOWN:   return PGKEY_PAGEDOWN;
  case KEY_INSERT:     return PGKEY_INSERT;
  case KEY_DELETE:     return PGKEY_DELETE;
  case KEY_F1:         return PGKEY_F1;
  case KEY_F2:         return PGKEY_F2;
  case KEY_F3:         return PGKEY_F3;
  case KEY_F4:         return PGKEY_F4;
  case KEY_F5:         return PGKEY_F5;
  case KEY_F6:         return PGKEY_F6;
  case KEY_F7:         return PGKEY_F7;
  case KEY_F8:         return PGKEY_F8;
  case KEY_F9:         return PGKEY_F9;
  case KEY_F10:        return PGKEY_F10;
  case KEY_F11:        return PGKEY_F11;
  case KEY_F12:        return PGKEY_F12;
  case KEY_LEFTSHIFT:  return PGKEY_LSHIFT;
  case KEY_RIGHTSHIFT: return PGKEY_RSHIFT;
  case KEY_LEFTCTRL:   return PGKEY_LCTRL;
  case KEY_RIGHTCTRL:  return PGKEY_RCTRL;
  case KEY_LEFTALT:    return PGKEY_LALT;
  case KEY_RIGHTALT:   return PGKEY_RALT;
  case KEY_CAPSLOCK:   return PGKEY_CAPSLOCK;
  /* No PGKEY_QUIT in upstream; suppress KEY_POWER for now. */
  case KEY_POWER:      return 0;
  case KEY_A: return 'a'; case KEY_B: return 'b'; case KEY_C: return 'c';
  case KEY_D: return 'd'; case KEY_E: return 'e'; case KEY_F: return 'f';
  case KEY_G: return 'g'; case KEY_H: return 'h'; case KEY_I: return 'i';
  case KEY_J: return 'j'; case KEY_K: return 'k'; case KEY_L: return 'l';
  case KEY_M: return 'm'; case KEY_N: return 'n'; case KEY_O: return 'o';
  case KEY_P: return 'p'; case KEY_Q: return 'q'; case KEY_R: return 'r';
  case KEY_S: return 's'; case KEY_T: return 't'; case KEY_U: return 'u';
  case KEY_V: return 'v'; case KEY_W: return 'w'; case KEY_X: return 'x';
  case KEY_Y: return 'y'; case KEY_Z: return 'z';
  case KEY_0: return '0'; case KEY_1: return '1'; case KEY_2: return '2';
  case KEY_3: return '3'; case KEY_4: return '4'; case KEY_5: return '5';
  case KEY_6: return '6'; case KEY_7: return '7'; case KEY_8: return '8';
  case KEY_9: return '9';
  case KEY_MINUS:      return '-';
  case KEY_EQUAL:      return '=';
  case KEY_LEFTBRACE:  return '[';
  case KEY_RIGHTBRACE: return ']';
  case KEY_SEMICOLON:  return ';';
  case KEY_APOSTROPHE: return '\'';
  case KEY_GRAVE:      return '`';
  case KEY_BACKSLASH:  return '\\';
  case KEY_COMMA:      return ',';
  case KEY_DOT:        return '.';
  case KEY_SLASH:      return '/';
  default:             return 0;
  }
}

static u32
mod_bit_for(u16 pgkey)
{
  switch (pgkey) {
  case PGKEY_LSHIFT: return PGMOD_LSHIFT;
  case PGKEY_RSHIFT: return PGMOD_RSHIFT;
  case PGKEY_LCTRL:  return PGMOD_LCTRL;
  case PGKEY_RCTRL:  return PGMOD_RCTRL;
  case PGKEY_LALT:   return PGMOD_LALT;
  case PGKEY_RALT:   return PGMOD_RALT;
  default:           return 0;
  }
}

static u16
apply_printable_modifiers(u16 code, u16 pgkey)
{
  int shift = (g_mods & (PGMOD_LSHIFT | PGMOD_RSHIFT)) != 0;
  int ctrl  = (g_mods & (PGMOD_LCTRL  | PGMOD_RCTRL )) != 0;

  if (pgkey >= 'a' && pgkey <= 'z') {
    if (ctrl)
      return (u16)(pgkey - 'a' + 1);
    if (shift ^ g_caps_lock)
      return (u16)(pgkey - 'a' + 'A');
    return pgkey;
  }
  if (!shift)
    return pgkey;

  switch (code) {
  case KEY_1: return '!';
  case KEY_2: return '@';
  case KEY_3: return '#';
  case KEY_4: return '$';
  case KEY_5: return '%';
  case KEY_6: return '^';
  case KEY_7: return '&';
  case KEY_8: return '*';
  case KEY_9: return '(';
  case KEY_0: return ')';
  case KEY_MINUS:      return '_';
  case KEY_EQUAL:      return '+';
  case KEY_LEFTBRACE:  return '{';
  case KEY_RIGHTBRACE: return '}';
  case KEY_SEMICOLON:  return ':';
  case KEY_APOSTROPHE: return '"';
  case KEY_GRAVE:      return '~';
  case KEY_BACKSLASH:  return '|';
  case KEY_COMMA:      return '<';
  case KEY_DOT:        return '>';
  case KEY_SLASH:      return '?';
  default: return pgkey;
  }
}

/* ------------------------------------------------------------------- */
/* Per-fd packet handling                                              */
/* ------------------------------------------------------------------- */

static void
flush_touch_packet(void)
{
  if (!g_touch_packet_dirty || !g_touch_have_xy)
    return;

  /* infilter_send_pointing() is the canonical pgserver entry point for
   * pointer events from input drivers. PG_TRIGGER_PNTR_STATUS reports an
   * absolute pointer state (matching h3600ts.c / adc7843.c); pgserver
   * synthesizes PG_TRIGGER_DOWN/UP from button-state level edges. The
   * button mask is bit 0 == LEFT. */
  evdev_kmsg("[evdev] touch %d,%d btn=%d\n",
             g_touch_x, g_touch_y, g_touch_pressed);
  infilter_send_pointing(PG_TRIGGER_PNTR_STATUS,
                         g_touch_x, g_touch_y,
                         g_touch_pressed ? 1 : 0,
                         NULL);

  g_touch_packet_dirty = 0;
}

static void
handle_touch_event(struct evdev_wire_event *ev)
{
  if (ev->type == EV_ABS) {
    if (ev->code == ABS_X) {
      g_touch_x = ev->value;
      g_touch_have_xy |= 1;
      g_touch_packet_dirty = 1;
    } else if (ev->code == ABS_Y) {
      g_touch_y = ev->value;
      g_touch_have_xy |= 1;
      g_touch_packet_dirty = 1;
    } else if (ev->code == ABS_PRESSURE) {
      g_touch_pressed = (ev->value != 0);
      g_touch_packet_dirty = 1;
    }
  } else if (ev->type == EV_KEY && ev->code == BTN_TOUCH) {
    g_touch_pressed = (ev->value != 0);
    g_touch_packet_dirty = 1;
  } else if (ev->type == EV_SYN) {
    if (ev->code == SYN_DROPPED) {
      g_touch_packet_dirty = 0;
      return;
    }
    flush_touch_packet();
  }
}

static void
handle_key_event(struct evdev_wire_event *ev)
{
  u16 pgkey;
  u32 bit;
  int is_modifier = 0;
  int is_printable = 0;

  if (ev->type != EV_KEY)
    return;
  /* ev->value: 0 = release, 1 = press, 2 = autorepeat */

  pgkey = evdev_to_pgkey(ev->code);
  if (!pgkey)
    return;

  bit = mod_bit_for(pgkey);
  if (bit) {
    if (ev->value)
      g_mods |= bit;
    else
      g_mods &= ~bit;
    is_modifier = 1;
  } else if (pgkey == PGKEY_CAPSLOCK && ev->value == 1) {
    g_caps_lock = !g_caps_lock;
  } else {
    /* Apply shift / capslock / ctrl-letter to printable keys. */
    u16 pre = pgkey;
    pgkey = apply_printable_modifiers(ev->code, pgkey);
    /* Anything < 256 that isn't a function/cursor/modifier key is
     * a CHAR-emitting key in PicoGUI's PGKEY space (the constants
     * PGKEY_BACKSPACE=8, PGKEY_TAB=9, PGKEY_RETURN=13, PGKEY_ESCAPE=27,
     * PGKEY_SPACE=32, PGKEY_DELETE=127 ARE ASCII control codes, so
     * they fit naturally as CHAR values too). */
    if (pgkey < 256)
      is_printable = 1;
    (void)pre;
  }

  /* On press, emit a PG_TRIGGER_CHAR for printable keys BEFORE the
   * PG_TRIGGER_KEYDOWN.  This is what every other picogui keyboard
   * driver in the tree does (rawttykb / sdlinput / btkey / jsdev),
   * and it's required for FIELD widgets (atomicnav's URL bar) and
   * textbox text entry to actually accept characters.  Without CHAR,
   * arrow / function keys still drive widget navigation through the
   * KEYDOWN handler but text just isn't typed.  See
   * pg1/server/input/if_key_preprocess.c for the chain that auto-
   * generates CHAR from PG_TRIGGER_KEY; we send the discrete trio
   * directly instead because we know our key state more precisely. */
  if (ev->value && is_printable && !is_modifier) {
    infilter_send_key(PG_TRIGGER_CHAR, pgkey, g_mods);
  }

  if (ev->value)
    infilter_send_key(PG_TRIGGER_KEYDOWN, pgkey, g_mods);
  else
    infilter_send_key(PG_TRIGGER_KEYUP,   pgkey, g_mods);
}

static void
drain_fd(struct evdev_fd *e)
{
  struct evdev_wire_event ev;
  ssize_t n;
  int events_read = 0;

  for (;;) {
    n = read(e->fd, &ev, sizeof(ev));
    if (n != sizeof(ev))
      break;
    events_read++;
    evdev_kmsg("[evdev] %s ev type=%u code=%u value=%d\n",
               e->name, ev.type, ev.code, ev.value);
    if (e->is_touch)
      handle_touch_event(&ev);
    else
      handle_key_event(&ev);
  }
  if (events_read > 0)
    evdev_kmsg("[evdev] drain_fd %s read %d events\n",
               e->name, events_read);
}

/* ------------------------------------------------------------------- */
/* pgserver driver vtable                                              */
/* ------------------------------------------------------------------- */

static g_error
evdev_init(void)
{
  g_nfds = 0;
  g_touch_x = g_touch_y = 0;
  g_touch_pressed = 0;
  g_touch_have_xy = 0;
  g_touch_packet_dirty = 0;
  g_mods = 0;
  g_caps_lock = 0;

  evdev_kmsg("[evdev] init entry\n");
  scan_input_devices();
  if (g_nfds == 0) {
    evdev_kmsg("[evdev] init FAILED — no matching evdev nodes\n");
    return mkerror(PG_ERRT_IO, 1);  /* no matching evdev nodes */
  }
  evdev_kmsg("[evdev] init OK with %d fds\n", g_nfds);
  return success;
}

static void
evdev_close(void)
{
  int i;
  for (i = 0; i < g_nfds; i++) {
    if (g_fds[i].fd >= 0) {
      ioctl(g_fds[i].fd, EVIOCGRAB, 0);
      close(g_fds[i].fd);
      g_fds[i].fd = -1;
    }
  }
  g_nfds = 0;
}

static void
evdev_fd_init(int *n, fd_set *readfds, struct timeval *timeout)
{
  static int trace_count = 0;
  int i, n_in = *n;
  for (i = 0; i < g_nfds; i++) {
    /* select() wants nfds = max_fd + 1.  jsdev.c has the same idiom
     * (`*n = jsdev_fd + 1`). Without the `+1`, our evdev fds are below
     * select's nfds threshold and the kernel never reports activity on
     * them — touch / Stowaway events are silently dropped. */
    if (g_fds[i].fd + 1 > *n)
      *n = g_fds[i].fd + 1;
    FD_SET(g_fds[i].fd, readfds);
  }
  /* Log only the first few + every 100th call so we don't flood */
  if (trace_count < 5 || (trace_count % 100) == 0) {
    evdev_kmsg("[evdev] fd_init #%d: n_in=%d nfds_out=%d g_nfds=%d fd0=%d fd1=%d fd2=%d\n",
               trace_count, n_in, *n, g_nfds,
               g_nfds > 0 ? g_fds[0].fd : -1,
               g_nfds > 1 ? g_fds[1].fd : -1,
               g_nfds > 2 ? g_fds[2].fd : -1);
  }
  trace_count++;
}

static int
evdev_fd_activate(int fd)
{
  int i;
  for (i = 0; i < g_nfds; i++) {
    if (g_fds[i].fd == fd) {
      evdev_kmsg("[evdev] fd_activate fd=%d (%s)\n", fd, g_fds[i].name);
      drain_fd(&g_fds[i]);
      return 1;
    }
  }
  return 0;
}

g_error
evdev_regfunc(struct inlib *i)
{
  i->init        = &evdev_init;
  i->close       = &evdev_close;
  i->fd_init     = &evdev_fd_init;
  i->fd_activate = &evdev_fd_activate;
  return success;
}
