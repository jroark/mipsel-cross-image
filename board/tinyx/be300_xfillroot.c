/*
 * TinyX root paint helper for the BE-300 profile.
 *
 * Xfbdev's default root background is easy to mistake for an uninitialized
 * LCD.  Paint a simple root background through Xlib so boot diagnostics can
 * distinguish a live X drawing path from a framebuffer that is still black.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <X11/Xlib.h>

static void usage(const char *argv0)
{
	fprintf(stderr, "usage: %s [-display display]\n", argv0);
}

int main(int argc, char **argv)
{
	const char *display_name = NULL;
	Display *dpy;
	Window root;
	GC gc;
	int screen;
	unsigned int width;
	unsigned int height;
	int i;

	for (i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "-display") && i + 1 < argc) {
			display_name = argv[++i];
		} else {
			usage(argv[0]);
			return 2;
		}
	}

	fprintf(stderr, "be300-xfillroot: opening display %s\n",
		display_name ? display_name : "(default)");
	fflush(stderr);

	dpy = XOpenDisplay(display_name);
	if (!dpy) {
		fprintf(stderr, "be300-xfillroot: cannot open display %s\n",
			display_name ? display_name : "(default)");
		return 1;
	}

	screen = DefaultScreen(dpy);
	root = RootWindow(dpy, screen);
	width = DisplayWidth(dpy, screen);
	height = DisplayHeight(dpy, screen);
	fprintf(stderr, "be300-xfillroot: connected fd=%d screen=%d %ux%u\n",
		ConnectionNumber(dpy), screen, width, height);
	fflush(stderr);

	gc = XCreateGC(dpy, root, 0, NULL);
	if (!gc) {
		fprintf(stderr, "be300-xfillroot: XCreateGC failed\n");
		XCloseDisplay(dpy);
		return 1;
	}

	XSetForeground(dpy, gc, WhitePixel(dpy, screen));
	XFillRectangle(dpy, root, gc, 0, 0, width, height);
	XSetForeground(dpy, gc, BlackPixel(dpy, screen));
	XDrawString(dpy, root, gc, 8, 18, "BE-300 TinyX", 12);
	XDrawRectangle(dpy, root, gc, 3, 3, width - 7, height - 7);
	XFlush(dpy);
	fprintf(stderr, "be300-xfillroot: waiting for XSync\n");
	fflush(stderr);
	XSync(dpy, False);

	fprintf(stderr, "be300-xfillroot: painted %ux%u on %s\n",
		width, height, DisplayString(dpy));

	XFreeGC(dpy, gc);
	XCloseDisplay(dpy);
	return 0;
}
