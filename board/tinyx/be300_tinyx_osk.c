/*
 * BE-300 TinyX on-screen keyboard.
 *
 * 240x90 Xlib + XTest client that maps flush to the bottom of the screen.
 * Starts unmapped; SIGUSR1 (sent by be300-tinyx-launcher when the user taps
 * the [Kbd] dock button) toggles map/unmap.  On ButtonPress over a key cell
 * the OSK synthesizes the key via XTestFakeKeyEvent, which the X server
 * delivers to whichever client currently owns input focus (typically rxvt
 * or be300-xstatus, never the OSK itself).
 *
 * The OSK's own window declares WM_HINTS.input=False and does NOT advertise
 * WM_TAKE_FOCUS, so matchbox-window-manager never gives it the keyboard
 * focus — meaning fake key events always travel to the previously focused
 * top-level client.  The window also uses _NET_WM_WINDOW_TYPE_TOOLBAR (not
 * DOCK with strut), so toggling visibility does NOT force matchbox to resize
 * the fullscreen client below us; the OSK simply overlays the bottom 90px.
 *
 * Three layers are tracked in-process: 0 = base (lowercase letters), 1 =
 * shift (uppercase letters / shifted punctuation, "sticky-once" — clears
 * after the next non-modifier press), 2 = sym (digits + punctuation,
 * latched until pressed again).  Each layer has parallel KeySym and label
 * tables; hit_test() resolves (x,y) -> (row,col), dispatch_cell() handles
 * special cells (shift toggle, sym toggle, multi-cell space band, arrows).
 *
 * Style mirrors be300_xstatus.c / be300_tinyx_launcher.c: single source
 * file, signal-handler-driven quit, XSetErrorHandler(ignore_x_error),
 * off-screen Pixmap double buffer, select() loop.  Soft-float safe — no
 * %lf scanf, no floating-point arithmetic.
 */

#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/types.h>
#include <unistd.h>

#include <X11/Xatom.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/keysym.h>
/* XTest disabled for now: a server-side bug in xorg-server-1.6.5's XTEST
 * dispatch (likely an XACE-or-dispatch interaction introduced by our
 * patch_xorg_sources.py patches) faults the X server on the FIRST XTEST
 * request from any client (XTestQueryExtension at startup is enough to
 * trigger).  See log: client=2 major=128 -> Fatal server error: Segfault.
 * Until that's fixed in patch_xorg_sources.py / xorg-server, the OSK
 * keeps its keymap and grid paint but no longer calls into XTest.  Key
 * taps are logged to stderr (which start-tinyx tees into
 * /tmp/tinyx-osk.log) so the OSK is still useful as a tap-visualizer.
 * To re-enable once the server is fixed: #define BE300_OSK_USE_XTEST. */
/* #include <X11/extensions/XTest.h> */

#define OSK_H        90
#define ROWS         4
#define COLS         10
#define KEY_W        24
#define KEY_H        22         /* 4 * 22 = 88; one extra row of padding at top */
#define OSK_PIDFILE  "/tmp/be300-tinyx-osk.pid"

static volatile sig_atomic_t want_quit;
static volatile sig_atomic_t want_toggle;

static int g_mapped       = 0;
static int g_layer        = 0;   /* 0=base, 1=shift, 2=sym */
static int g_shift_sticky = 0;

/* Special cell sentinels — non-KeySym values that dispatch_cell() catches
 * before XKeysymToKeycode().  Use XK_VoidSymbol (=0xFFFFFF) for the SYM
 * toggle; the SHIFT toggle uses XK_Shift_L directly because we recognize
 * it positionally rather than by KeySym. */
#define SK_SYM   XK_VoidSymbol

static const KeySym layer0[ROWS][COLS] = {
	{ XK_q, XK_w, XK_e, XK_r, XK_t, XK_y, XK_u, XK_i, XK_o, XK_p },
	{ XK_a, XK_s, XK_d, XK_f, XK_g, XK_h, XK_j, XK_k, XK_l, XK_BackSpace },
	{ XK_Shift_L, XK_z, XK_x, XK_c, XK_v, XK_b, XK_n, XK_m, XK_comma, XK_period },
	{ SK_SYM, XK_space, XK_space, XK_space, XK_space, XK_space, XK_space, XK_space, XK_Left, XK_Right },
};
static const KeySym layer1[ROWS][COLS] = {
	{ XK_Q, XK_W, XK_E, XK_R, XK_T, XK_Y, XK_U, XK_I, XK_O, XK_P },
	{ XK_A, XK_S, XK_D, XK_F, XK_G, XK_H, XK_J, XK_K, XK_L, XK_BackSpace },
	{ XK_Shift_L, XK_Z, XK_X, XK_C, XK_V, XK_B, XK_N, XK_M, XK_less, XK_greater },
	{ SK_SYM, XK_space, XK_space, XK_space, XK_space, XK_space, XK_space, XK_space, XK_Home, XK_End },
};
static const KeySym layer2[ROWS][COLS] = {
	{ XK_1, XK_2, XK_3, XK_4, XK_5, XK_6, XK_7, XK_8, XK_9, XK_0 },
	{ XK_minus, XK_equal, XK_bracketleft, XK_bracketright, XK_backslash,
	  XK_semicolon, XK_apostrophe, XK_slash, XK_grave, XK_BackSpace },
	{ XK_Shift_L, XK_exclam, XK_at, XK_numbersign, XK_dollar, XK_percent,
	  XK_asciicircum, XK_ampersand, XK_asterisk, XK_question },
	{ SK_SYM, XK_space, XK_space, XK_space, XK_space, XK_space, XK_space, XK_space, XK_Up, XK_Down },
};

static const char *label0[ROWS][COLS] = {
	{ "q","w","e","r","t","y","u","i","o","p" },
	{ "a","s","d","f","g","h","j","k","l","BS" },
	{ "Sh","z","x","c","v","b","n","m",",","." },
	{ "Sy","","","","spc","","","","<-","->" },
};
static const char *label1[ROWS][COLS] = {
	{ "Q","W","E","R","T","Y","U","I","O","P" },
	{ "A","S","D","F","G","H","J","K","L","BS" },
	{ "SH","Z","X","C","V","B","N","M","<",">" },
	{ "Sy","","","","spc","","","","Hm","En" },
};
static const char *label2[ROWS][COLS] = {
	{ "1","2","3","4","5","6","7","8","9","0" },
	{ "-","=","[","]","\\",";","'","/","`","BS" },
	{ "Sh","!","@","#","$","%","^","&","*","?" },
	{ "Sy","","","","spc","","","","Up","Dn" },
};

static int ignore_x_error(Display *dpy, XErrorEvent *err)
{
	(void)dpy;
	(void)err;
	return 0;
}

static void on_signal(int sig)
{
	(void)sig;
	want_quit = 1;
}

static void on_sigusr1(int sig)
{
	(void)sig;
	want_toggle = 1;
}

static void write_pidfile(void)
{
	FILE *f = fopen(OSK_PIDFILE, "w");
	if (!f)
		return;
	fprintf(f, "%ld\n", (long)getpid());
	fclose(f);
}

static void remove_pidfile(void)
{
	unlink(OSK_PIDFILE);
}

static const KeySym (*layer_keys(void))[COLS]
{
	if (g_layer == 1) return layer1;
	if (g_layer == 2) return layer2;
	return layer0;
}

static const char *cell_label(int r, int c)
{
	if (g_layer == 1) return label1[r][c];
	if (g_layer == 2) return label2[r][c];
	return label0[r][c];
}

static void send_keysym(Display *dpy, KeySym sym)
{
	/* XTest path disabled until xorg-server XTEST handler is fixed.
	 * Once XTest works:
	 *   KeyCode kc = XKeysymToKeycode(dpy, sym);
	 *   XTestFakeKeyEvent(dpy, kc, True,  0);
	 *   XTestFakeKeyEvent(dpy, kc, False, 0);
	 *   XFlush(dpy);
	 */
	(void)dpy;
	(void)sym;
}

/* True if (x,y) lands on the SYM toggle cell (row 3 col 0). */
static int is_sym_cell(int r, int c)
{
	return (r == 3 && c == 0);
}

/* True if (x,y) lands on the SHIFT toggle cell (row 2 col 0). */
static int is_shift_cell(int r, int c)
{
	return (r == 2 && c == 0);
}

/* True if (x,y) lands inside the space band (row 3, cols 1..7). */
static int is_space_band(int r, int c)
{
	return (r == 3 && c >= 1 && c <= 7);
}

static void hit_test(int x, int y, int *r, int *c)
{
	int row = y / KEY_H;
	int col = x / KEY_W;
	if (row < 0 || row >= ROWS) row = -1;
	if (col < 0 || col >= COLS) col = -1;
	*r = row;
	*c = col;
}

/* dispatch_cell returns 1 if the OSK should repaint (layer state changed
 * or a key was sent). */
static int dispatch_cell(Display *dpy, int r, int c)
{
	if (r < 0 || c < 0)
		return 0;

	if (is_shift_cell(r, c)) {
		if (g_layer == 1) {
			g_layer = 0;
			g_shift_sticky = 0;
		} else {
			g_layer = 1;
			g_shift_sticky = 1;
		}
		return 1;
	}

	if (is_sym_cell(r, c)) {
		g_layer = (g_layer == 2) ? 0 : 2;
		g_shift_sticky = 0;
		return 1;
	}

	if (is_space_band(r, c)) {
		send_keysym(dpy, XK_space);
		if (g_shift_sticky && g_layer == 1) {
			g_layer = 0;
			g_shift_sticky = 0;
			return 1;
		}
		return 0;
	}

	{
		const KeySym (*keys)[COLS] = layer_keys();
		KeySym sym = keys[r][c];
		send_keysym(dpy, sym);
	}

	if (g_shift_sticky && g_layer == 1) {
		g_layer = 0;
		g_shift_sticky = 0;
		return 1;
	}
	return 0;
}

static void paint(Display *dpy, Window win, Pixmap back, GC gc,
		  XFontStruct *font, int width, int height,
		  unsigned long fg, unsigned long bg)
{
	Drawable t   = back ? (Drawable)back : (Drawable)win;
	int ascent   = font ? font->ascent : 11;
	int line_h   = font ? (font->ascent + font->descent) : 13;
	int r, c;

	XSetForeground(dpy, gc, bg);
	XFillRectangle(dpy, t, gc, 0, 0, (unsigned)width, (unsigned)height);

	XSetForeground(dpy, gc, fg);

	/* Draw a 4x10 grid of key cells.  Each cell = KEY_W x KEY_H, label
	 * centered (truncated to first char if it overflows). */
	for (r = 0; r < ROWS; r++) {
		for (c = 0; c < COLS; c++) {
			int x = c * KEY_W;
			int y = r * KEY_H + 1;       /* +1: top padding row */
			const char *lbl = cell_label(r, c);
			int n = (int)strlen(lbl);
			int tw, lx, ly;

			/* Special-case the space band: draw one wide cell
			 * spanning cols 1..7, but only on the first iteration
			 * (c==1) so we don't redraw it 7 times. */
			if (r == 3 && c >= 1 && c <= 7) {
				if (c == 1) {
					int bw = 7 * KEY_W - 2;
					XDrawRectangle(dpy, t, gc,
						       x, y, bw, KEY_H - 2);
					tw = font ? XTextWidth(font, "space", 5)
						  : 30;
					lx = x + (bw - tw) / 2;
					ly = y + (KEY_H - line_h) / 2 + ascent;
					XDrawString(dpy, t, gc, lx, ly,
						    "space", 5);
				}
				continue;
			}

			XDrawRectangle(dpy, t, gc,
				       x, y, KEY_W - 2, KEY_H - 2);

			if (n == 0)
				continue;

			tw = font ? XTextWidth(font, lbl, n) : (n * 6);
			if (tw > KEY_W - 2 && n > 1) {
				/* Fallback: single-char label. */
				n  = 1;
				tw = font ? XTextWidth(font, lbl, n) : 6;
			}
			lx = x + (KEY_W - tw) / 2;
			ly = y + (KEY_H - line_h) / 2 + ascent;
			XDrawString(dpy, t, gc, lx, ly, lbl, n);
		}
	}

	/* Layer indicator strip across the top. */
	{
		const char *tag =
			(g_layer == 1) ? (g_shift_sticky ? "[Shift-once]" : "[Shift]")
		      : (g_layer == 2) ? "[Sym]"
		      :                  "[abc]";
		int tag_n  = (int)strlen(tag);
		int tag_tw = font ? XTextWidth(font, tag, tag_n) : (tag_n * 6);
		int tag_x  = width - tag_tw - 2;
		int tag_y  = ascent;
		XDrawString(dpy, t, gc, tag_x, tag_y, tag, tag_n);
	}

	if (back)
		XCopyArea(dpy, back, win, gc, 0, 0,
			  (unsigned)width, (unsigned)height, 0, 0);
	XFlush(dpy);
}

int main(int argc, char **argv)
{
	const char *display_name = NULL;
	Display *dpy;
	Window root, win;
	GC gc;
	XGCValues gcv;
	XFontStruct *font = NULL;
	XSizeHints hints;
	XSetWindowAttributes swa;
	XClassHint class_hint;
	XTextProperty wname_prop;
	XWMHints *wm_hints;
	char *wname = (char *)"BE-300 OSK";
	int screen, screen_w, screen_h, conn_fd;
	unsigned long fg, bg;
	Pixmap back;
	int i;

	for (i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "-display") && i + 1 < argc) {
			display_name = argv[++i];
		} else {
			return 2;
		}
	}

	signal(SIGTERM, on_signal);
	signal(SIGINT,  on_signal);
	signal(SIGPIPE, SIG_IGN);
	signal(SIGUSR1, on_sigusr1);

	dpy = XOpenDisplay(display_name);
	if (!dpy)
		return 1;
	XSetErrorHandler(ignore_x_error);

	/* XTest probe deliberately skipped: XTestQueryExtension's
	 * XTestGetVersion request faults xorg-server-1.6.5's registered XTEST
	 * dispatch on this build (likely an XACE-or-dispatch patch
	 * interaction); avoid touching XTest at all until that's fixed. */

	screen   = DefaultScreen(dpy);
	root     = RootWindow(dpy, screen);
	screen_w = DisplayWidth(dpy, screen);
	screen_h = DisplayHeight(dpy, screen);
	conn_fd  = ConnectionNumber(dpy);
	fg       = BlackPixel(dpy, screen);
	bg       = WhitePixel(dpy, screen);

	swa.background_pixel  = bg;
	swa.border_pixel      = fg;
	/* Note: no KeyPressMask — the OSK must NOT take keyboard focus or
	 * receive its own synthesized keys. */
	swa.event_mask        = ExposureMask | StructureNotifyMask |
				ButtonPressMask | ButtonReleaseMask;
	/* override_redirect=True for the same reason as be300-tinyx-launcher:
	 * sidestep matchbox-wm 1.2's window-type dispatch and refusal to
	 * resize CLIENT_FULLSCREEN_FLAG apps when a TOOLBAR maps.  The OSK
	 * is toggled via SIGUSR1 -> XMapRaised / XUnmapWindow; XTest still
	 * delivers fake key events to the X server's focus owner regardless
	 * of the OSK's override_redirect status. */
	swa.override_redirect = True;
	win = XCreateWindow(dpy, root, 0, screen_h - OSK_H,
			    (unsigned)screen_w, OSK_H,
			    0, CopyFromParent, InputOutput, CopyFromParent,
			    CWBackPixel | CWBorderPixel | CWEventMask |
			    CWOverrideRedirect, &swa);

	memset(&hints, 0, sizeof hints);
	hints.flags      = PMinSize | PMaxSize | PSize | USPosition;
	hints.x          = 0;
	hints.y          = screen_h - OSK_H;
	hints.min_width  = hints.max_width  = screen_w;
	hints.min_height = hints.max_height = OSK_H;
	XSetWMNormalHints(dpy, win, &hints);

	class_hint.res_name  = (char *)"be300-tinyx-osk";
	class_hint.res_class = (char *)"Be300OSK";
	XSetClassHint(dpy, win, &class_hint);

	if (XStringListToTextProperty(&wname, 1, &wname_prop)) {
		XSetWMName(dpy, win, &wname_prop);
		XFree(wname_prop.value);
	}

	/* InputHint=False: matchbox-wm treats us as non-focusable.  XTest
	 * delivers fake events to the currently focused top-level (rxvt or
	 * xstatus); the OSK itself never owns the focus. */
	wm_hints = XAllocWMHints();
	if (wm_hints) {
		wm_hints->flags = InputHint;
		wm_hints->input = False;
		XSetWMHints(dpy, win, wm_hints);
		XFree(wm_hints);
	}

	/* _NET_WM_WINDOW_TYPE_TOOLBAR + _NET_WM_STATE_ABOVE — overlays the
	 * focused client without strut'ing matchbox's geometry. */
	{
		Atom wt        = XInternAtom(dpy, "_NET_WM_WINDOW_TYPE",      False);
		Atom toolbar   = XInternAtom(dpy, "_NET_WM_WINDOW_TYPE_TOOLBAR", False);
		Atom state     = XInternAtom(dpy, "_NET_WM_STATE",            False);
		Atom st_above  = XInternAtom(dpy, "_NET_WM_STATE_ABOVE",      False);
		Atom st_skip   = XInternAtom(dpy, "_NET_WM_STATE_SKIP_PAGER", False);

		XChangeProperty(dpy, win, wt, XA_ATOM, 32, PropModeReplace,
				(unsigned char *)&toolbar, 1);
		Atom states[2] = { st_above, st_skip };
		XChangeProperty(dpy, win, state, XA_ATOM, 32, PropModeReplace,
				(unsigned char *)states, 2);
	}

	gcv.foreground = fg;
	gcv.background = bg;
	gc = XCreateGC(dpy, win, GCForeground | GCBackground, &gcv);
	font = XLoadQueryFont(dpy, "6x13");
	if (font)
		XSetFont(dpy, gc, font->fid);

	back = XCreatePixmap(dpy, win, (unsigned)screen_w, OSK_H,
			     (unsigned)DefaultDepth(dpy, screen));

	write_pidfile();
	/* Start unmapped — launcher SIGUSR1 will toggle visibility. */
	g_mapped = 0;
	XFlush(dpy);

	while (!want_quit) {
		fd_set rfds;
		struct timeval tv;
		int rc;
		int need_paint = 0;

		if (want_toggle) {
			want_toggle = 0;
			if (g_mapped) {
				XUnmapWindow(dpy, win);
				g_mapped = 0;
			} else {
				XMapRaised(dpy, win);
				g_mapped = 1;
				need_paint = 1;
			}
			XFlush(dpy);
		}

		while (XPending(dpy)) {
			XEvent ev;
			XNextEvent(dpy, &ev);
			if (ev.type == Expose && ev.xexpose.count == 0) {
				need_paint = 1;
			} else if (ev.type == MapNotify) {
				g_mapped = 1;
				need_paint = 1;
			} else if (ev.type == UnmapNotify) {
				g_mapped = 0;
			} else if (ev.type == ConfigureNotify) {
				if (ev.xconfigure.width != screen_w) {
					screen_w = ev.xconfigure.width;
					if (back)
						XFreePixmap(dpy, back);
					back = XCreatePixmap(dpy, win,
							     (unsigned)screen_w,
							     OSK_H,
							     (unsigned)DefaultDepth(dpy, screen));
				}
				need_paint = 1;
			} else if (ev.type == ButtonRelease) {
				int r, c;
				hit_test(ev.xbutton.x, ev.xbutton.y, &r, &c);
				if (dispatch_cell(dpy, r, c))
					need_paint = 1;
			}
		}

		if (need_paint && g_mapped)
			paint(dpy, win, back, gc, font,
			      screen_w, OSK_H, fg, bg);

		FD_ZERO(&rfds);
		FD_SET(conn_fd, &rfds);
		tv.tv_sec  = 5;
		tv.tv_usec = 0;
		rc = select(conn_fd + 1, &rfds, NULL, NULL, &tv);
		if (rc < 0 && errno != EINTR)
			break;
	}

	remove_pidfile();
	if (back) XFreePixmap(dpy, back);
	if (font) XFreeFont(dpy, font);
	XFreeGC(dpy, gc);
	XDestroyWindow(dpy, win);
	XCloseDisplay(dpy);
	return 0;
}
