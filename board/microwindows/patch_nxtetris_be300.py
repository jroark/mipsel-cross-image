#!/usr/bin/env python3
"""Patch Microwindows nxtetris/ntetris for the BE-300 front buttons.

Applies to both the modern ghaerr nxtetris.c (4.2.9 Microwindows profile) and
the 2003-era ntetris.c that matches the linux4.be donor nano-X server (2.4/2.6
mw profiles).  Everything is gated on BE300_HW_BUTTONS so the stock build is
unchanged unless the build passes -DBE300_HW_BUTTONS.

The on-screen New Game/Pause/rotate/move/drop buttons are never mapped; the
freed control-bar area shows a status line and a key legend instead.  Key
map (BE-300 buttons as delivered by the kernel input driver):

  Left / Right      move
  Up                rotate anticlockwise
  Down              drop
  OK (Enter)        start a new game, resume, or rotate clockwise
  Esc (Tab)         pause / resume
  Rocket+Esc (Backspace) or Power   quit

With -DBE300_EVDEV_BUTTONS the game also opens the "BE-300 Buttons" evdev
node itself and registers it with GrRegisterInput().  The 2.4/2.6 mw
profiles need this because their 2003 nano-X server only reads the console
keyboard on /dev/tty0; key events for the same buttons that also arrive
through nano-X are then ignored so a press is not handled twice.

Usage: patch_nxtetris_be300.py path/to/nxtetris.c
"""
import sys
from pathlib import Path

MARK = "BE300_HW_BUTTONS"


def replace_once(text, old, new, what):
    count = text.count(old)
    if count != 1:
        sys.exit(f"patch_nxtetris_be300: {what}: expected 1 match, found {count}")
    return text.replace(old, new)


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    path = Path(sys.argv[1])
    text = path.read_text()
    if MARK in text:
        print(f"patch_nxtetris_be300: {path} already patched")
        return

    text = replace_once(text, """\
void draw_pause_continue_button(nstate *state)
{
""", """\
#ifdef BE300_HW_BUTTONS
/* Status line + key legend drawn where the on-screen buttons used to be. */
static void draw_be300_help(nstate *state)
{
	static GR_GC_ID fg, bg;
	static const char *const legend[] = {
		"OK   rotate",
		"Up   rotate",
		"<>   move",
		"Dn   drop",
		"Esc  pause",
		"R+Esc quit",
	};
	const char *status;
	int i, y = NEW_GAME_BUTTON_Y_POSITION;

	if(!fg) {
		fg = GrNewGC();
		GrSetGCForeground(fg, GR_COLOR_WHITE);
		GrSetGCBackground(fg, MAIN_WINDOW_BACKGROUND_COLOUR);
		bg = GrNewGC();
		GrSetGCForeground(bg, MAIN_WINDOW_BACKGROUND_COLOUR);
	}
	GrFillRect(state->main_window, bg, BORDER_WIDTH, y, BUTTON_WIDTH,
			MAIN_WINDOW_HEIGHT - BORDER_WIDTH - y);

	if(state->state == STATE_PAUSED) status = "Paused";
	else if(state->state == STATE_STOPPED) status = "OK = start";
	else status = "";
	GrText(state->main_window, fg, BORDER_WIDTH, y + TEXT_Y_POSITION,
			(void *)status, strlen(status), 0);
	y += BUTTON_HEIGHT + BORDER_WIDTH;
	for(i = 0; i < (int)(sizeof(legend) / sizeof(legend[0])); i++) {
		GrText(state->main_window, fg, BORDER_WIDTH,
				y + TEXT_Y_POSITION, (void *)legend[i],
				strlen(legend[i]), 0);
		y += BUTTON_HEIGHT - 4;
	}
}
#endif

void draw_pause_continue_button(nstate *state)
{
#ifdef BE300_HW_BUTTONS
	draw_be300_help(state);
	return;
#endif
""", "draw_pause_continue_button")

    text = replace_once(text, """\
	GR_EVENT_EXPOSURE *event = &state->event.exposure;

""", """\
	GR_EVENT_EXPOSURE *event = &state->event.exposure;

#ifdef BE300_HW_BUTTONS
	if(event->wid == state->main_window) {
		draw_be300_help(state);
		return;
	}
#endif
""", "handle_exposure_event")

    text = replace_once(text, """\
	GR_EVENT_KEYSTROKE *event = &state->event.keystroke;

	switch(event->ch) {
""", """\
	GR_EVENT_KEYSTROKE *event = &state->event.keystroke;

#ifdef BE300_HW_BUTTONS
	switch(event->ch) {
		case MWKEY_BACKSPACE:
		case 127:
#ifdef MWKEY_QUIT
		case MWKEY_QUIT:
#endif
			state->state = STATE_EXIT;
			return;
		case MWKEY_TAB:
			if(state->state == STATE_RUNNING)
				state->state = STATE_PAUSED;
			else if(state->state == STATE_PAUSED)
				state->state = STATE_RUNNING;
			return;
		case MWKEY_ENTER:
		case '\\n':
			if(state->state == STATE_STOPPED)
				state->state = STATE_NEWGAME;
			else if(state->state == STATE_PAUSED)
				state->state = STATE_RUNNING;
			else
				rotate_block(state, 1);
			return;
		case MWKEY_DOWN:
			if(state->state == STATE_RUNNING)
				drop_block(state);
			return;
	}
#endif

	switch(event->ch) {
""", "handle_keyboard_event")

    text = replace_once(text, """\
	GrMapWindow(state->new_game_button);
""", """\
#ifndef BE300_HW_BUTTONS
	GrMapWindow(state->new_game_button);
#endif
""", "new_game_button map")

    # evdev button reader for the 2003 nano-X server (2.4/2.6 mw profiles).
    text = replace_once(text, """\
void handle_event(nstate *state)
{
""", """\
#ifdef BE300_EVDEV_BUTTONS
#include <sys/ioctl.h>
#include <stdint.h>

#define BE300_BUTTONS_NAME "BE-300 Buttons"

/* 32-bit Linux evdev record; musl's time64 struct timeval would be wider. */
struct be300_input_event {
	int32_t sec, usec;
	uint16_t type, code;
	int32_t value;
};

static int be300_btn_fd = -1;

/* EVIOCGNAME(len) = _IOC(_IOC_READ, 'E', 0x06, len) on MIPS. */
#define BE300_EVIOCGNAME(len) \\
	((2U << 29) | ((unsigned)(len) << 16) | ('E' << 8) | 0x06)

#ifdef BE300_TETRIS_DEBUG
#include <signal.h>
#include <sys/ucontext.h>

static void be300_hex(const char *tag, unsigned long v)
{
	char b[24];
	int i;

	write(2, tag, strlen(tag));
	for(i = 0; i < 8; i++)
		b[i] = "0123456789abcdef"[(v >> (28 - 4 * i)) & 15];
	b[8] = ' ';
	write(2, b, 9);
}

/* Print the faulting PC/address so crashes on the legacy kernels can be
 * located with objdump. */
static void be300_fault(int sig, siginfo_t *si, void *ctx)
{
	ucontext_t *uc = ctx;

	be300_hex("ntetris: signal ", sig);
	be300_hex("addr ", (unsigned long)si->si_addr);
	be300_hex("pc ", (unsigned long)uc->uc_mcontext.pc);
	be300_hex("ra ", (unsigned long)uc->uc_mcontext.gregs[31]);
	write(2, "\\n", 1);
	_exit(128 + sig);
}
#endif

static void be300_open_buttons(void)
{
	char path[32], name[64];
	int i, fd;
#ifdef BE300_TETRIS_DEBUG
	struct sigaction sa;

	memset(&sa, 0, sizeof(sa));
	sa.sa_sigaction = be300_fault;
	sa.sa_flags = SA_SIGINFO;
	sigaction(SIGSEGV, &sa, NULL);
	sigaction(SIGBUS, &sa, NULL);
	sigaction(SIGILL, &sa, NULL);
#endif

	for(i = 0; i < 8; i++) {
		sprintf(path, "/dev/input/event%d", i);
		if((fd = open(path, O_RDONLY | O_NONBLOCK)) < 0) continue;
		memset(name, 0, sizeof(name));
		if(ioctl(fd, BE300_EVIOCGNAME(sizeof(name) - 1), name) >= 0 &&
				!strcmp(name, BE300_BUTTONS_NAME)) {
			be300_btn_fd = fd;
			GrRegisterInput(fd);
#ifdef BE300_TETRIS_DEBUG
			fprintf(stderr, "ntetris: buttons %s fd %d\\n", path, fd);
#endif
			return;
		}
		close(fd);
	}
	fprintf(stderr, "ntetris: no \\"" BE300_BUTTONS_NAME "\\" input device\\n");
}

/* Keys the buttons generate; their nano-X copies are dropped. */
static int be300_is_button_key(int ch)
{
	switch(ch) {
		case MWKEY_ENTER: case '\\n': case MWKEY_TAB:
		case MWKEY_BACKSPACE: case 127:
		case MWKEY_UP: case MWKEY_DOWN:
		case MWKEY_LEFT: case MWKEY_RIGHT:
			return 1;
	}
	return 0;
}

static void be300_read_buttons(nstate *state)
{
	struct be300_input_event ev;
	int ch;

	while(read(be300_btn_fd, &ev, sizeof(ev)) == sizeof(ev)) {
#ifdef BE300_TETRIS_DEBUG
		fprintf(stderr, "ntetris: ev type %d code %d value %d\\n",
				ev.type, ev.code, ev.value);
#endif
		if(ev.type != 1 || ev.value != 1) continue;	/* EV_KEY press */
		switch(ev.code) {
			case 28:  ch = MWKEY_ENTER; break;	/* KEY_ENTER */
			case 15:  ch = MWKEY_TAB; break;	/* KEY_TAB */
			case 14:  ch = MWKEY_BACKSPACE; break;	/* KEY_BACKSPACE */
			case 103: ch = MWKEY_UP; break;		/* KEY_UP */
			case 108: ch = MWKEY_DOWN; break;	/* KEY_DOWN */
			case 105: ch = MWKEY_LEFT; break;	/* KEY_LEFT */
			case 106: ch = MWKEY_RIGHT; break;	/* KEY_RIGHT */
#ifdef MWKEY_QUIT
			case 116: ch = MWKEY_QUIT; break;	/* KEY_POWER */
#endif
			default: continue;
		}
		state->event.type = GR_EVENT_TYPE_KEY_DOWN;
		state->event.keystroke.ch = ch;
		handle_keyboard_event(state);
		if(state->state == STATE_EXIT) return;
	}
}
#endif

void handle_event(nstate *state)
{
#ifdef BE300_TETRIS_DEBUG
	fprintf(stderr, "ntetris: event %d state %d\\n", state->event.type,
			state->state);
#endif
#ifdef BE300_EVDEV_BUTTONS
	if(state->event.type == GR_EVENT_TYPE_FDINPUT) {
		if(state->event.fdinput.fd == be300_btn_fd)
			be300_read_buttons(state);
		return;
	}
	if(state->event.type == GR_EVENT_TYPE_KEY_DOWN && be300_btn_fd >= 0 &&
			be300_is_button_key(state->event.keystroke.ch))
		return;
#endif
""", "handle_event")

    text = replace_once(text, """\
	GrMapWindow(state->main_window);
""", """\
	GrMapWindow(state->main_window);
#ifdef BE300_EVDEV_BUTTONS
	be300_open_buttons();
#endif
""", "main_window map")

    if "#include <string.h>" not in text:
        text = replace_once(text, "#include <stdlib.h>\n",
                            "#include <stdlib.h>\n#include <string.h>\n",
                            "string.h include")

    path.write_text(text)
    print(f"patch_nxtetris_be300: patched {path}")


if __name__ == "__main__":
    main()
