/*
 * TinyX status applet for the BE-300 profile.
 *
 * matchbox-window-manager runs in single-fullscreen mode and only paints over
 * the root window (which it owns) when a real client is mapped.  Without a
 * mapped top-level the framebuffer collapses to whatever matchbox picked.
 * be300-xstatus is the always-on visible client: it creates a fullscreen
 * window, draws a "BE-300 TinyX" banner plus live clock / uptime / eth0 IP,
 * and repaints once a second.  When the terminal is hidden or missing this is
 * what the user sees on the LCD; when a terminal is mapped, matchbox stacks
 * the terminal above us.
 *
 * Single source file, libX11-only.  Style mirrors be300_xfillroot.c.
 */

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <net/if.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/sysinfo.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#include <X11/Xatom.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>

#define IFNAME "eth0"

static volatile sig_atomic_t want_quit;

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

static void read_uptime(char *buf, size_t buflen)
{
	/* Use sysinfo() rather than fscanf("%lf", /proc/uptime).  uClibc-ng's
	 * soft-float %lf scanf path comes back with values pegged near 2^31 on
	 * this target for reasons not yet tracked down; the kernel sysinfo
	 * syscall returns an honest integer uptime in seconds. */
	struct sysinfo si;
	unsigned long s, m, h, d;

	if (sysinfo(&si) != 0) {
		snprintf(buf, buflen, "up ?");
		return;
	}

	s = (unsigned long)si.uptime;
	d = s / 86400; s -= d * 86400;
	h = s / 3600;  s -= h * 3600;
	m = s / 60;    s -= m * 60;
	if (d > 0)
		snprintf(buf, buflen, "up %lud %lu:%02lu:%02lu", d, h, m, s);
	else
		snprintf(buf, buflen, "up %lu:%02lu:%02lu", h, m, s);
}

static void read_ifaddr(const char *ifname, char *buf, size_t buflen)
{
	int fd;
	struct ifreq ifr;

	fd = socket(AF_INET, SOCK_DGRAM, 0);
	if (fd < 0) {
		snprintf(buf, buflen, "ip ?");
		return;
	}
	memset(&ifr, 0, sizeof ifr);
	ifr.ifr_addr.sa_family = AF_INET;
	strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);
	if (ioctl(fd, SIOCGIFADDR, &ifr) < 0) {
		snprintf(buf, buflen, "ip none");
	} else {
		struct sockaddr_in *sin = (struct sockaddr_in *)&ifr.ifr_addr;
		snprintf(buf, buflen, "ip %s", inet_ntoa(sin->sin_addr));
	}
	close(fd);
}

static void announce_fullscreen(Display *dpy, Window win)
{
	/* Matchbox in single-fullscreen mode already fullscreens us, but the
	 * EWMH hint plus a hard size_hints PMinSize/PMaxSize match makes it
	 * unambiguous for any WM that respects EWMH. */
	Atom net_state = XInternAtom(dpy, "_NET_WM_STATE", False);
	Atom net_fs    = XInternAtom(dpy, "_NET_WM_STATE_FULLSCREEN", False);
	if (net_state != None && net_fs != None) {
		XChangeProperty(dpy, win, net_state, XA_ATOM, 32,
				PropModeReplace, (unsigned char *)&net_fs, 1);
	}
}

static void paint(Display *dpy, Window win, Pixmap back, GC gc,
		  XFontStruct *font, int width, int height,
		  unsigned long fg, unsigned long bg,
		  const char *key_line, const char *ptr_line)
{
	char tbuf[64], ubuf[64], ibuf[64], hbuf[40];
	time_t now;
	struct tm tm;
	int line_h = font ? (font->ascent + font->descent + 4) : 16;
	int ascent = font ? font->ascent : 11;
	int y;
	Drawable target = back ? (Drawable)back : (Drawable)win;

	now = time(NULL);
	localtime_r(&now, &tm);
	snprintf(tbuf, sizeof tbuf, "time %02d:%02d:%02d",
		 tm.tm_hour, tm.tm_min, tm.tm_sec);
	read_uptime(ubuf, sizeof ubuf);
	read_ifaddr(IFNAME, ibuf, sizeof ibuf);
	snprintf(hbuf, sizeof hbuf, "BE-300 TinyX");

	/* Double-buffered: clear + draw into the off-screen pixmap, then XCopyArea
	 * to the window once.  Eliminates the all-white flash that XFillRectangle
	 * over the window itself produced between the clear and the text draw. */
	XSetForeground(dpy, gc, bg);
	XFillRectangle(dpy, target, gc, 0, 0, width, height);

	XSetForeground(dpy, gc, fg);
	/* black border */
	XDrawRectangle(dpy, target, gc, 2, 2, width - 5, height - 5);
	XDrawRectangle(dpy, target, gc, 3, 3, width - 7, height - 7);

	y = 14 + ascent;
	XDrawString(dpy, target, gc, 10, y, hbuf, (int)strlen(hbuf)); y += line_h + 6;
	XDrawString(dpy, target, gc, 10, y, tbuf, (int)strlen(tbuf)); y += line_h;
	XDrawString(dpy, target, gc, 10, y, ubuf, (int)strlen(ubuf)); y += line_h;
	XDrawString(dpy, target, gc, 10, y, ibuf, (int)strlen(ibuf)); y += line_h;
	XDrawString(dpy, target, gc, 10, y, ptr_line, (int)strlen(ptr_line)); y += line_h;
	XDrawString(dpy, target, gc, 10, y, key_line, (int)strlen(key_line));

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
	char *wname = (char *)"BE-300 TinyX";
	char key_line[64] = "key none";
	char ptr_line[64] = "ptr none";
	int pointer_down = 0;
	int screen, width, height, conn_fd;
	unsigned long fg, bg;
	int i;

	for (i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "-display") && i + 1 < argc) {
			display_name = argv[++i];
		} else {
			fprintf(stderr, "usage: %s [-display display]\n", argv[0]);
			return 2;
		}
	}

	signal(SIGTERM, on_signal);
	signal(SIGINT,  on_signal);
	signal(SIGPIPE, SIG_IGN);

	dpy = XOpenDisplay(display_name);
	if (!dpy) {
		fprintf(stderr, "be300-xstatus: cannot open display %s\n",
			display_name ? display_name : "(default)");
		return 1;
	}
	XSetErrorHandler(ignore_x_error);
	screen   = DefaultScreen(dpy);
	root     = RootWindow(dpy, screen);
	width    = DisplayWidth(dpy, screen);
	height   = DisplayHeight(dpy, screen);
	conn_fd  = ConnectionNumber(dpy);
	fg       = BlackPixel(dpy, screen);
	bg       = WhitePixel(dpy, screen);
	fprintf(stderr, "be300-xstatus: connected fd=%d screen=%d %dx%d\n",
		conn_fd, screen, width, height);

	swa.background_pixel = bg;
	swa.border_pixel     = fg;
	swa.event_mask       = ExposureMask | StructureNotifyMask |
			       KeyPressMask | KeyReleaseMask |
			       ButtonPressMask | ButtonReleaseMask |
			       PointerMotionMask;
	swa.override_redirect = False;
	win = XCreateWindow(dpy, root, 0, 0, (unsigned)width, (unsigned)height,
			    0, CopyFromParent, InputOutput, CopyFromParent,
			    CWBackPixel | CWBorderPixel | CWEventMask |
			    CWOverrideRedirect, &swa);

	memset(&hints, 0, sizeof hints);
	hints.flags = PMinSize | PMaxSize | PSize | USPosition;
	hints.min_width = hints.max_width = width;
	hints.min_height = hints.max_height = height;
	hints.x = 0; hints.y = 0;
	XSetWMNormalHints(dpy, win, &hints);

	class_hint.res_name = (char *)"be300-xstatus";
	class_hint.res_class = (char *)"Be300Status";
	XSetClassHint(dpy, win, &class_hint);

	if (XStringListToTextProperty(&wname, 1, &wname_prop)) {
		XSetWMName(dpy, win, &wname_prop);
		XFree(wname_prop.value);
	}
	announce_fullscreen(dpy, win);

	gcv.foreground = fg;
	gcv.background = bg;
	gc = XCreateGC(dpy, win, GCForeground | GCBackground, &gcv);
	font = XLoadQueryFont(dpy, "6x13");
	if (font) {
		XSetFont(dpy, gc, font->fid);
	} else {
		fprintf(stderr, "be300-xstatus: 6x13 font not found; using server default\n");
	}

	/* Off-screen backing buffer for double-buffered paints; eliminates the
	 * full-window clear flash that the user reported as flicker. */
	Pixmap back = XCreatePixmap(dpy, win, (unsigned)width, (unsigned)height,
				    (unsigned)DefaultDepth(dpy, screen));
	if (!back)
		fprintf(stderr, "be300-xstatus: XCreatePixmap failed; falling back to direct draws\n");

	XMapWindow(dpy, win);
	/* be300-tinyx: let matchbox-wm own focus.  When the rxvt terminal also
	 * maps, matchbox raises and focuses the most recently mapped top-level
	 * (client_common.c::client_set_focus).  Calling XSetInputFocus from here
	 * would steal keys back into the always-on banner client, which is the
	 * exact failure the May 13 build hit. */
	XFlush(dpy);

	while (!want_quit) {
		fd_set rfds;
		struct timeval tv;
		int rc;

		/* Drain any queued events before sleeping. */
		while (XPending(dpy)) {
			XEvent ev;
			XNextEvent(dpy, &ev);
			if (ev.type == Expose && ev.xexpose.count == 0) {
				paint(dpy, win, back, gc, font, width, height,
				      fg, bg, key_line, ptr_line);
			} else if (ev.type == MapNotify) {
				/* be300-tinyx: no self-focus on MapNotify; matchbox-wm
				 * decides who owns focus when rxvt or anything else maps. */
				paint(dpy, win, back, gc, font, width, height,
				      fg, bg, key_line, ptr_line);
			} else if (ev.type == ConfigureNotify) {
				if (ev.xconfigure.width != width ||
				    ev.xconfigure.height != height) {
					width = ev.xconfigure.width;
					height = ev.xconfigure.height;
					if (back)
						XFreePixmap(dpy, back);
					back = XCreatePixmap(dpy, win,
							     (unsigned)width,
							     (unsigned)height,
							     (unsigned)DefaultDepth(dpy, screen));
				}
			} else if (ev.type == KeyPress || ev.type == KeyRelease) {
				char buf[16];
				KeySym sym = NoSymbol;
				int n;

				memset(buf, 0, sizeof buf);
				n = XLookupString(&ev.xkey, buf, sizeof buf - 1,
						  &sym, NULL);
				if (n > 0 && buf[0] >= 32 && buf[0] < 127)
					snprintf(key_line, sizeof key_line,
						 "key %s code=%u '%c'",
						 ev.type == KeyPress ? "down" : "up",
						 ev.xkey.keycode, buf[0]);
				else
					snprintf(key_line, sizeof key_line,
						 "key %s code=%u sym=0x%lx",
						 ev.type == KeyPress ? "down" : "up",
						 ev.xkey.keycode, (unsigned long)sym);
			} else if (ev.type == ButtonPress || ev.type == ButtonRelease) {
				pointer_down = (ev.type == ButtonPress);
				snprintf(ptr_line, sizeof ptr_line, "ptr %03d,%03d %s",
					 ev.xbutton.x, ev.xbutton.y,
					 pointer_down ? "down" : "up");
			} else if (ev.type == MotionNotify) {
				snprintf(ptr_line, sizeof ptr_line, "ptr %03d,%03d %s",
					 ev.xmotion.x, ev.xmotion.y,
					 pointer_down ? "down" : "up");
			}
		}

		paint(dpy, win, back, gc, font, width, height, fg, bg,
		      key_line, ptr_line);

		FD_ZERO(&rfds);
		FD_SET(conn_fd, &rfds);
		tv.tv_sec = 1; tv.tv_usec = 0;
		rc = select(conn_fd + 1, &rfds, NULL, NULL, &tv);
		if (rc < 0 && errno != EINTR) {
			fprintf(stderr, "be300-xstatus: select: %s\n", strerror(errno));
			break;
		}
	}

	if (back) XFreePixmap(dpy, back);
	if (font) XFreeFont(dpy, font);
	XFreeGC(dpy, gc);
	XDestroyWindow(dpy, win);
	XCloseDisplay(dpy);
	return 0;
}
