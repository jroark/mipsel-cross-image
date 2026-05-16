/*
 * BE-300 TinyX launcher dock.
 *
 * Top-of-screen 240x18 Xlib client that matchbox-window-manager 1.2 treats as
 * a docked panel via _NET_WM_WINDOW_TYPE_DOCK + _NET_WM_STRUT_PARTIAL.  Three
 * right-justified buttons (Term, Stat, Kbd) dispatch on ButtonPress:
 *
 *   [Term]: fork+exec /usr/bin/rxvt (or /usr/bin/xterm fallback) running
 *           /bin/tinyx-shell.  Skip if a previously-spawned terminal is still
 *           alive — matchbox stacks the existing window above on next focus.
 *   [Stat]: fork+exec /usr/bin/be300-xstatus.  Same alive-skip.
 *   [Kbd] : read /tmp/be300-tinyx-osk.pid and SIGUSR1 the on-screen keyboard
 *           daemon so it toggles map/unmap.
 *
 * Style mirrors be300_xstatus.c: single source file, libX11-only, SIGTERM ->
 * want_quit, XSetErrorHandler(ignore_x_error), off-screen Pixmap for
 * flicker-free paint.  Deliberately does NOT call XSetInputFocus on itself —
 * the dock should never steal keyboard focus from the fullscreen client.
 */

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include <X11/Xatom.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>

/* Dock geometry tuned for touchscreen ergonomics on the 240x320 LCD.
 * Earlier 18px-tall dock with 36x14 buttons was too thin for resistive-
 * touchscreen taps; users reported "buttons don't launch."  Bumping the
 * dock to 32px (~10% of screen height) gives the buttons enough vertical
 * real estate to land a finger reliably. */
#define DOCK_H        32
#define BTN_W         44
#define BTN_H         26
#define BTN_PAD       4
#define N_BUTTONS     3
#define OSK_PIDFILE   "/tmp/be300-tinyx-osk.pid"

#define BTN_TERM      0
#define BTN_STAT      1
#define BTN_KBD       2

static const char *BTN_LABEL[N_BUTTONS] = { " Term", " Stat", " Kbd" };

static volatile sig_atomic_t want_quit;

static pid_t term_pid    = -1;
static pid_t xstatus_pid = -1;

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

/* No SIGCHLD handler — see signal(SIGCHLD, SIG_IGN) in main().  On Linux
 * that flag means the kernel auto-reaps zombies and never delivers
 * SIGCHLD to us.  We deliberately avoid the signal because uClibc-ng's
 * sigreturn trampoline lands at pc=0 on this MIPS PIC + hidden-symbol
 * mix, which would kill the launcher every time the user taps [Term]
 * and the rxvt child exits (sh inside rxvt has its own pc=0 SEGV bug).
 * Same workaround used by board/picogui/picogui.config::cursorhide=0
 * (see project_picogui_sigalrm_fix memory). */

static int alive(pid_t p)
{
	return (p > 0 && kill(p, 0) == 0);
}

static pid_t spawn(const char *path, char *const argv[])
{
	pid_t p = fork();
	if (p == 0) {
		/* Child: detach stdin; keep stdout/stderr inherited so the
		 * start-tinyx script's redirections still capture us. */
		int devnull = open("/dev/null", O_RDONLY);
		if (devnull >= 0) {
			dup2(devnull, 0);
			if (devnull > 2)
				close(devnull);
		}
		execv(path, argv);
		_exit(127);
	}
	return p;
}

static void launch_term(void)
{
	char *av_rxvt[] = {
		(char *)"/usr/bin/rxvt", (char *)"-display", (char *)":0",
		(char *)"-geometry", (char *)"40x22", (char *)"-fn", (char *)"6x13",
		(char *)"-bg", (char *)"#d8d8d8", (char *)"-fg", (char *)"#000000",
		(char *)"-cr", (char *)"#0044ff",
		(char *)"-e", (char *)"/bin/tinyx-shell", NULL
	};
	char *av_xterm[] = {
		(char *)"/usr/bin/xterm", (char *)"-display", (char *)":0",
		(char *)"-geometry", (char *)"40x22", (char *)"-fn", (char *)"6x13",
		(char *)"-bg", (char *)"#d8d8d8", (char *)"-fg", (char *)"#000000",
		(char *)"-cr", (char *)"#0044ff",
		(char *)"-e", (char *)"/bin/tinyx-shell", NULL
	};

	if (alive(term_pid))
		return;
	if (access("/usr/bin/rxvt", X_OK) == 0)
		term_pid = spawn("/usr/bin/rxvt", av_rxvt);
	else if (access("/usr/bin/xterm", X_OK) == 0)
		term_pid = spawn("/usr/bin/xterm", av_xterm);
}

static void launch_xstatus(void)
{
	char *av[] = {
		(char *)"/usr/bin/be300-xstatus",
		(char *)"-display", (char *)":0", NULL
	};
	if (alive(xstatus_pid))
		return;
	if (access("/usr/bin/be300-xstatus", X_OK) != 0)
		return;
	xstatus_pid = spawn("/usr/bin/be300-xstatus", av);
}

static void toggle_osk(void)
{
	char buf[32];
	int fd, n;
	long v;
	fd = open(OSK_PIDFILE, O_RDONLY);
	if (fd < 0) {
		/* OSK not yet spawned (lazy-launch path on the 16 MiB profile).
		 * Spawn it now; it'll map itself when SIGUSR1 arrives on the
		 * user's NEXT [Kbd] tap. */
		char *av[] = {
			(char *)"/usr/bin/be300-tinyx-osk",
			(char *)"-display", (char *)":0", NULL
		};
		if (access("/usr/bin/be300-tinyx-osk", X_OK) == 0)
			spawn("/usr/bin/be300-tinyx-osk", av);
		return;
	}
	n = read(fd, buf, sizeof buf - 1);
	close(fd);
	if (n <= 0)
		return;
	buf[n] = '\0';
	v = strtol(buf, NULL, 10);
	if (v <= 0)
		return;
	kill((pid_t)v, SIGUSR1);
}

static void declare_dock(Display *dpy, Window w, int screen_w)
{
	Atom wt        = XInternAtom(dpy, "_NET_WM_WINDOW_TYPE",         False);
	Atom dock      = XInternAtom(dpy, "_NET_WM_WINDOW_TYPE_DOCK",    False);
	Atom strut     = XInternAtom(dpy, "_NET_WM_STRUT",               False);
	Atom strut_p   = XInternAtom(dpy, "_NET_WM_STRUT_PARTIAL",       False);
	Atom state     = XInternAtom(dpy, "_NET_WM_STATE",               False);
	Atom st_above  = XInternAtom(dpy, "_NET_WM_STATE_ABOVE",         False);
	Atom st_skip   = XInternAtom(dpy, "_NET_WM_STATE_SKIP_PAGER",    False);

	XChangeProperty(dpy, w, wt, XA_ATOM, 32, PropModeReplace,
			(unsigned char *)&dock, 1);

	/* _NET_WM_STRUT (legacy 4-element: left,right,top,bottom). */
	unsigned long strut4[4] = { 0, 0, DOCK_H, 0 };
	XChangeProperty(dpy, w, strut, XA_CARDINAL, 32, PropModeReplace,
			(unsigned char *)strut4, 4);

	/* _NET_WM_STRUT_PARTIAL: l,r,t,b, l_y1,l_y2, r_y1,r_y2,
	 *                        t_x1,t_x2, b_x1,b_x2. */
	unsigned long strut12[12] = {
		0, 0, DOCK_H, 0,
		0, 0, 0, 0,
		0, (unsigned long)(screen_w - 1),
		0, 0
	};
	XChangeProperty(dpy, w, strut_p, XA_CARDINAL, 32, PropModeReplace,
			(unsigned char *)strut12, 12);

	Atom states[2] = { st_above, st_skip };
	XChangeProperty(dpy, w, state, XA_ATOM, 32, PropModeReplace,
			(unsigned char *)states, 2);
}

static int button_x0(int idx, int screen_w)
{
	int total = N_BUTTONS * BTN_W + (N_BUTTONS - 1) * BTN_PAD;
	int x0    = screen_w - total - 2;
	return x0 + idx * (BTN_W + BTN_PAD);
}

static int hit_test(int x, int screen_w)
{
	int i;
	for (i = 0; i < N_BUTTONS; i++) {
		int bx = button_x0(i, screen_w);
		if (x >= bx && x < bx + BTN_W)
			return i;
	}
	return -1;
}

static void paint(Display *dpy, Window win, Pixmap back, GC gc,
		  XFontStruct *font, int width,
		  unsigned long fg, unsigned long bg, int pressed_idx)
{
	Drawable t = back ? (Drawable)back : (Drawable)win;
	int ascent = font ? font->ascent : 11;
	int line_h = font ? (font->ascent + font->descent) : 13;
	int by     = (DOCK_H - line_h) / 2 + ascent;
	int i;

	XSetForeground(dpy, gc, bg);
	XFillRectangle(dpy, t, gc, 0, 0, (unsigned)width, DOCK_H);

	XSetForeground(dpy, gc, fg);
	/* Bottom rule separating the dock from the client area. */
	XDrawLine(dpy, t, gc, 0, DOCK_H - 1, width, DOCK_H - 1);

	/* "BE-300" label on the left. */
	XDrawString(dpy, t, gc, 3, by, "BE-300", 6);

	for (i = 0; i < N_BUTTONS; i++) {
		int bx = button_x0(i, width);
		int by0 = (DOCK_H - BTN_H) / 2;
		int label_len = (int)strlen(BTN_LABEL[i]);

		if (i == pressed_idx) {
			XSetForeground(dpy, gc, fg);
			XFillRectangle(dpy, t, gc, bx, by0,
				       BTN_W, BTN_H);
			XSetForeground(dpy, gc, bg);
			XDrawString(dpy, t, gc, bx + 3, by,
				    BTN_LABEL[i], label_len);
			XSetForeground(dpy, gc, fg);
		} else {
			XDrawRectangle(dpy, t, gc, bx, by0,
				       BTN_W - 1, BTN_H - 1);
			XDrawString(dpy, t, gc, bx + 3, by,
				    BTN_LABEL[i], label_len);
		}
	}

	if (back)
		XCopyArea(dpy, back, win, gc, 0, 0,
			  (unsigned)width, DOCK_H, 0, 0);
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
	char *wname = (char *)"BE-300 Launcher";
	int screen, screen_w, conn_fd;
	unsigned long fg, bg;
	int pressed_idx = -1;
	struct timespec pressed_ts = { 0, 0 };
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
	/* SIG_IGN on SIGCHLD: Linux auto-reaps zombies, no handler is ever
	 * invoked.  Avoids the uClibc-ng MIPS sigreturn pc=0 SEGV that would
	 * otherwise kill the launcher whenever a forked rxvt exits. */
	signal(SIGCHLD, SIG_IGN);

	dpy = XOpenDisplay(display_name);
	if (!dpy)
		return 1;
	XSetErrorHandler(ignore_x_error);
	screen   = DefaultScreen(dpy);
	root     = RootWindow(dpy, screen);
	screen_w = DisplayWidth(dpy, screen);
	conn_fd  = ConnectionNumber(dpy);
	/* Inverted palette: black background, white text, visually distinct
	 * from xstatus's white background when both are mapped. */
	fg       = WhitePixel(dpy, screen);
	bg       = BlackPixel(dpy, screen);

	swa.background_pixel  = bg;
	swa.border_pixel      = fg;
	swa.event_mask        = ExposureMask | StructureNotifyMask |
				ButtonPressMask | ButtonReleaseMask;
	/* override_redirect=True: bypass matchbox WM management entirely.
	 * The X server maps the dock directly above all normal client
	 * windows (override_redirect windows are stacked above
	 * managed windows by default).  This sidesteps matchbox-wm 1.2's
	 * wm_update_layout, which refuses to resize CLIENT_FULLSCREEN_FLAG
	 * apps (e.g. be300-xstatus declaring _NET_WM_STATE_FULLSCREEN) when
	 * a NORTH dock maps — without that resize, fullscreen xstatus paints
	 * over the dock area on every 1Hz repaint and the dock never appears.
	 * Trade-off: matchbox does not reserve the 18px strip via
	 * wm_update_layout, so the app area below us is still 240x320 with
	 * the dock overlaying the top 18px.  Same trade-off the OSK takes
	 * at the bottom of the screen. */
	swa.override_redirect = True;
	win = XCreateWindow(dpy, root, 0, 0,
			    (unsigned)screen_w, DOCK_H,
			    0, CopyFromParent, InputOutput, CopyFromParent,
			    CWBackPixel | CWBorderPixel | CWEventMask |
			    CWOverrideRedirect, &swa);

	memset(&hints, 0, sizeof hints);
	hints.flags     = PMinSize | PMaxSize | PSize | USPosition;
	hints.x = 0; hints.y = 0;
	hints.min_width  = hints.max_width  = screen_w;
	hints.min_height = hints.max_height = DOCK_H;
	XSetWMNormalHints(dpy, win, &hints);

	class_hint.res_name  = (char *)"be300-tinyx-launcher";
	class_hint.res_class = (char *)"Be300Launcher";
	XSetClassHint(dpy, win, &class_hint);

	if (XStringListToTextProperty(&wname, 1, &wname_prop)) {
		XSetWMName(dpy, win, &wname_prop);
		XFree(wname_prop.value);
	}

	/* InputHint=False so the WM never tries to give the dock keyboard
	 * focus.  Matchbox's focus model raises last-mapped non-dock client. */
	wm_hints = XAllocWMHints();
	if (wm_hints) {
		wm_hints->flags = InputHint;
		wm_hints->input = False;
		XSetWMHints(dpy, win, wm_hints);
		XFree(wm_hints);
	}

	declare_dock(dpy, win, screen_w);

	gcv.foreground = fg;
	gcv.background = bg;
	gc = XCreateGC(dpy, win, GCForeground | GCBackground, &gcv);
	font = XLoadQueryFont(dpy, "6x13");
	if (font)
		XSetFont(dpy, gc, font->fid);

	back = XCreatePixmap(dpy, win, (unsigned)screen_w, DOCK_H,
			     (unsigned)DefaultDepth(dpy, screen));

	/* Subscribe to root SubstructureNotify so we see MapNotify for every
	 * other top-level that maps after us.  In override_redirect mode the
	 * X server stacks new managed windows above us by default; we counter
	 * that by calling XRaiseWindow on every foreign map event below. */
	XSelectInput(dpy, root, SubstructureNotifyMask);

	XMapRaised(dpy, win);
	XFlush(dpy);

	/* Explicit first paint so the strip is visible before the first
	 * Expose round-trip. */
	paint(dpy, win, back, gc, font, screen_w, fg, bg, -1);

	while (!want_quit) {
		fd_set rfds;
		struct timeval tv;
		int rc;
		int need_paint = 0;

		while (XPending(dpy)) {
			XEvent ev;
			XNextEvent(dpy, &ev);
			if (ev.type == Expose && ev.xexpose.count == 0) {
				need_paint = 1;
			} else if (ev.type == MapNotify) {
				if (ev.xmap.window == win) {
					/* Our own map: paint. */
					need_paint = 1;
				} else {
					/* Foreign top-level just mapped (e.g.
					 * rxvt, xstatus, or OSK).  Raise the
					 * dock back to the top — override_redirect
					 * doesn't give us automatic always-on-top. */
					XRaiseWindow(dpy, win);
					XFlush(dpy);
				}
			} else if (ev.type == ConfigureNotify) {
				if (ev.xconfigure.window == win) {
					/* Track resize on our own window
					 * (shouldn't happen with PMinSize=PMaxSize,
					 * but be defensive). */
					if (ev.xconfigure.width != screen_w) {
						screen_w = ev.xconfigure.width;
						if (back)
							XFreePixmap(dpy, back);
						back = XCreatePixmap(dpy, win,
								     (unsigned)screen_w,
								     DOCK_H,
								     (unsigned)DefaultDepth(dpy, screen));
					}
					need_paint = 1;
				} else {
					/* Foreign Configure (e.g. a managed
					 * client was just raised by matchbox).
					 * Bounce ourselves back to the top. */
					XRaiseWindow(dpy, win);
					XFlush(dpy);
				}
			} else if (ev.type == ButtonPress) {
				int idx = hit_test(ev.xbutton.x, screen_w);
				if (idx >= 0) {
					/* Dispatch on PRESS, not release.
					 * Touchscreen users slip a few pixels
					 * between press and release; waiting
					 * for release silently drops the tap. */
					pressed_idx = idx;
					clock_gettime(CLOCK_MONOTONIC, &pressed_ts);
					switch (idx) {
					case BTN_TERM: launch_term();    break;
					case BTN_STAT: launch_xstatus(); break;
					case BTN_KBD:  toggle_osk();     break;
					}
					need_paint = 1;
				}
			} else if (ev.type == ButtonRelease) {
				/* Action already fired on press; clear the
				 * pressed-flash highlight. */
				pressed_idx = -1;
				need_paint = 1;
			}
		}

		if (need_paint)
			paint(dpy, win, back, gc, font, screen_w,
			      fg, bg, pressed_idx);

		FD_ZERO(&rfds);
		FD_SET(conn_fd, &rfds);
		/* No periodic refresh — the dock is static.  Wake on X event
		 * or a 5s heartbeat (so a deferred press-flash clear can run
		 * if no other event arrives). */
		tv.tv_sec  = 5;
		tv.tv_usec = 0;
		rc = select(conn_fd + 1, &rfds, NULL, NULL, &tv);
		if (rc < 0 && errno != EINTR)
			break;

		/* Clear a stuck "pressed" highlight if ButtonRelease never
		 * arrived (e.g. pointer left the dock). */
		if (pressed_idx >= 0) {
			struct timespec now;
			long ms;
			clock_gettime(CLOCK_MONOTONIC, &now);
			ms = (now.tv_sec  - pressed_ts.tv_sec)  * 1000L
			   + (now.tv_nsec - pressed_ts.tv_nsec) / 1000000L;
			if (ms > 400) {
				pressed_idx = -1;
				paint(dpy, win, back, gc, font, screen_w,
				      fg, bg, pressed_idx);
			}
		}
	}

	if (back) XFreePixmap(dpy, back);
	if (font) XFreeFont(dpy, font);
	XFreeGC(dpy, gc);
	XDestroyWindow(dpy, win);
	XCloseDisplay(dpy);
	return 0;
}
