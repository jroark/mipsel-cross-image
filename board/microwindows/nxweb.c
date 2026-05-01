/*
 * nxweb - small HTTP text browser for Nano-X on the Casio BE-300.
 *
 * This is intentionally minimal: HTTP only, one window, text rendering, and
 * URL entry through hardware keys or nxkbd. It is meant as a lightweight
 * smoke-test browser, not a general HTML engine.
 */
#include <ctype.h>
#include <errno.h>
#include <netdb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/types.h>
#include <unistd.h>

#define MWINCLUDECOLORS
#include "nano-X.h"

#define WIN_W		228
#define WIN_H		260
#define TOP_H		44
#define BOTTOM_H	20
#define MARGIN		4
#define GO_X		190
#define GO_W		34
#define MAX_URL		160
#define MAX_LINE	96
#define MAX_LINES	260
#define NETBUF_SIZE	24576

static GR_WINDOW_ID win;
static GR_GC_ID gc_text;
static GR_GC_ID gc_inv;
static GR_GC_ID gc_frame;
static GR_GC_ID gc_bg;
static GR_GC_ID gc_link;
static GR_FONT_ID font;
static GR_FONT_INFO fi;

static char url[MAX_URL] = "http://example.com/";
static char status[96] = "Ready";
static char lines[MAX_LINES][MAX_LINE];
static int line_count;
static int top_line;
static int editing_url = 1;
static int have_focus;

static int chars_per_line(void)
{
	int fw = fi.maxwidth ? fi.maxwidth : 6;
	int cols = (WIN_W - (MARGIN * 2)) / fw;

	if (cols < 12)
		cols = 12;
	if (cols >= MAX_LINE)
		cols = MAX_LINE - 1;
	return cols;
}

static int visible_lines(void)
{
	int fh = fi.height ? fi.height : 12;
	int rows = (WIN_H - TOP_H - BOTTOM_H - MARGIN) / fh;

	if (rows < 1)
		rows = 1;
	return rows;
}

static void clear_lines(void)
{
	line_count = 0;
	top_line = 0;
	memset(lines, 0, sizeof(lines));
}

static void add_line(const char *s, int len)
{
	if (line_count >= MAX_LINES)
		return;
	if (len < 0)
		len = 0;
	if (len >= MAX_LINE)
		len = MAX_LINE - 1;
	memcpy(lines[line_count], s, len);
	lines[line_count][len] = '\0';
	line_count++;
}

static void wrap_text(const char *text)
{
	char out[MAX_LINE];
	int col = 0;
	int maxcol = chars_per_line();
	int pending_space = 0;
	const unsigned char *p = (const unsigned char *)text;

	clear_lines();

	while (*p && line_count < MAX_LINES) {
		unsigned char ch = *p++;

		if (ch == '\r')
			continue;
		if (ch == '\n') {
			add_line(out, col);
			col = 0;
			pending_space = 0;
			continue;
		}
		if (isspace(ch)) {
			pending_space = col > 0;
			continue;
		}
		if (pending_space) {
			if (col >= maxcol) {
				add_line(out, col);
				col = 0;
			}
			if (col > 0)
				out[col++] = ' ';
			pending_space = 0;
		}
		if (col >= maxcol) {
			add_line(out, col);
			col = 0;
		}
		if (isprint(ch))
			out[col++] = ch;
	}

	if (col || line_count == 0)
		add_line(out, col);
}

static int entity_char(const char *s, int *used)
{
	if (!strncmp(s, "amp;", 4)) {
		*used = 4;
		return '&';
	}
	if (!strncmp(s, "lt;", 3)) {
		*used = 3;
		return '<';
	}
	if (!strncmp(s, "gt;", 3)) {
		*used = 3;
		return '>';
	}
	if (!strncmp(s, "quot;", 5)) {
		*used = 5;
		return '"';
	}
	if (!strncmp(s, "nbsp;", 5)) {
		*used = 5;
		return ' ';
	}
	*used = 0;
	return '&';
}

static void html_to_text(char *s)
{
	char *r = s;
	char *w = s;
	int in_tag = 0;

	while (*r) {
		if (*r == '<') {
			in_tag = 1;
			if (!strncasecmp(r, "<br", 3) ||
			    !strncasecmp(r, "<p", 2) ||
			    !strncasecmp(r, "</p", 3) ||
			    !strncasecmp(r, "<div", 4) ||
			    !strncasecmp(r, "</div", 5) ||
			    !strncasecmp(r, "<li", 3) ||
			    !strncasecmp(r, "</h", 3))
				*w++ = '\n';
			r++;
			continue;
		}
		if (in_tag) {
			if (*r == '>')
				in_tag = 0;
			r++;
			continue;
		}
		if (*r == '&') {
			int used;
			int ch = entity_char(r + 1, &used);
			*w++ = (char)ch;
			r += used ? used + 1 : 1;
			continue;
		}
		*w++ = *r++;
	}
	*w = '\0';
}

static int parse_url(const char *src, char *host, size_t host_len,
		     char *port, size_t port_len, char *path, size_t path_len)
{
	const char *p = src;
	const char *slash;
	const char *colon;
	size_t n;

	if (!strncmp(p, "https://", 8)) {
		snprintf(status, sizeof(status), "HTTPS is not supported");
		return -1;
	}
	if (!strncmp(p, "http://", 7))
		p += 7;

	slash = strchr(p, '/');
	if (!slash)
		slash = p + strlen(p);

	colon = memchr(p, ':', (size_t)(slash - p));
	if (colon) {
		n = (size_t)(colon - p);
		if (n >= host_len)
			n = host_len - 1;
		memcpy(host, p, n);
		host[n] = '\0';

		n = (size_t)(slash - colon - 1);
		if (n >= port_len)
			n = port_len - 1;
		memcpy(port, colon + 1, n);
		port[n] = '\0';
	} else {
		n = (size_t)(slash - p);
		if (n >= host_len)
			n = host_len - 1;
		memcpy(host, p, n);
		host[n] = '\0';
		snprintf(port, port_len, "80");
	}

	if (!host[0]) {
		snprintf(status, sizeof(status), "Missing host");
		return -1;
	}

	if (*slash)
		snprintf(path, path_len, "%s", slash);
	else
		snprintf(path, path_len, "/");

	return 0;
}

static int fetch_http(char *buf, size_t cap)
{
	char host[96];
	char port[12];
	char path[160];
	char request[384];
	struct addrinfo hints;
	struct addrinfo *res = NULL;
	struct addrinfo *ai;
	int fd = -1;
	int rc;
	size_t used = 0;
	struct timeval tv;

	if (parse_url(url, host, sizeof(host), port, sizeof(port),
		      path, sizeof(path)) < 0)
		return -1;

	snprintf(status, sizeof(status), "Resolving %s", host);

	memset(&hints, 0, sizeof(hints));
	hints.ai_family = AF_UNSPEC;
	hints.ai_socktype = SOCK_STREAM;
	rc = getaddrinfo(host, port, &hints, &res);
	if (rc) {
		snprintf(status, sizeof(status), "DNS failed");
		return -1;
	}

	for (ai = res; ai; ai = ai->ai_next) {
		fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
		if (fd < 0)
			continue;
		tv.tv_sec = 12;
		tv.tv_usec = 0;
		setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
		setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
		if (connect(fd, ai->ai_addr, ai->ai_addrlen) == 0)
			break;
		close(fd);
		fd = -1;
	}
	freeaddrinfo(res);

	if (fd < 0) {
		snprintf(status, sizeof(status), "Connect failed");
		return -1;
	}

	snprintf(request, sizeof(request),
		 "GET %s HTTP/1.0\r\nHost: %s\r\nUser-Agent: nxweb-be300\r\n"
		 "Connection: close\r\n\r\n",
		 path, host);
	if (write(fd, request, strlen(request)) < 0) {
		close(fd);
		snprintf(status, sizeof(status), "Send failed");
		return -1;
	}

	for (;;) {
		ssize_t n;

		if (used >= cap - 1)
			break;
		n = read(fd, buf + used, cap - used - 1);
		if (n == 0)
			break;
		if (n < 0) {
			if (errno == EINTR)
				continue;
			break;
		}
		used += (size_t)n;
	}
	close(fd);
	buf[used] = '\0';

	if (!used) {
		snprintf(status, sizeof(status), "No response");
		return -1;
	}

	snprintf(status, sizeof(status), "%lu bytes from %s",
		 (unsigned long)used, host);
	return 0;
}

static void load_url(void)
{
	static char netbuf[NETBUF_SIZE];
	char *body;

	clear_lines();
	add_line("Loading...", 10);
	if (fetch_http(netbuf, sizeof(netbuf)) < 0) {
		clear_lines();
		add_line(status, (int)strlen(status));
		return;
	}

	body = strstr(netbuf, "\r\n\r\n");
	if (body)
		body += 4;
	else {
		body = strstr(netbuf, "\n\n");
		if (body)
			body += 2;
		else
			body = netbuf;
	}

	html_to_text(body);
	wrap_text(body);
}

static void draw_button(int x, int y, int w, int h, const char *label)
{
	GrFillRect(win, gc_bg, x, y, w, h);
	GrRect(win, gc_frame, x, y, w, h);
	GrText(win, gc_text, x + 5, y + 14, label, -1, GR_TFASCII);
}

static void redraw(void)
{
	int y;
	int i;
	int rows;
	int fh = fi.height ? fi.height : 12;

	GrClearWindow(win, GR_FALSE);

	GrFillRect(win, editing_url ? gc_inv : gc_bg, MARGIN, MARGIN,
		   GO_X - (MARGIN * 2), 18);
	GrRect(win, gc_frame, MARGIN, MARGIN, GO_X - (MARGIN * 2), 18);
	GrText(win, editing_url ? gc_bg : gc_text, MARGIN + 3, MARGIN + 13,
	       url, -1, GR_TFASCII);
	draw_button(GO_X, MARGIN, GO_W, 18, "Go");

	GrText(win, gc_link, MARGIN, 36, status, -1, GR_TFASCII);
	GrLine(win, gc_frame, 0, TOP_H - 1, WIN_W, TOP_H - 1);

	y = TOP_H + fh;
	rows = visible_lines();
	for (i = 0; i < rows && top_line + i < line_count; i++) {
		GrText(win, gc_text, MARGIN, y, lines[top_line + i],
		       -1, GR_TFASCII);
		y += fh;
	}

	GrLine(win, gc_frame, 0, WIN_H - BOTTOM_H, WIN_W, WIN_H - BOTTOM_H);
	draw_button(MARGIN, WIN_H - BOTTOM_H + 2, 46, 16, "Up");
	draw_button(58, WIN_H - BOTTOM_H + 2, 54, 16, "Down");
	GrText(win, gc_link, 122, WIN_H - 6, have_focus ? "keys ok" : "tap url",
	       -1, GR_TFASCII);
}

static void scroll_by(int delta)
{
	int max_top = line_count - visible_lines();

	if (max_top < 0)
		max_top = 0;
	top_line += delta;
	if (top_line < 0)
		top_line = 0;
	if (top_line > max_top)
		top_line = max_top;
}

static void handle_key(GR_EVENT_KEYSTROKE *kp)
{
	int len;

	switch (kp->ch) {
	case '\r':
	case '\n':
		load_url();
		break;
	case '\b':
	case 0x7f:
		len = (int)strlen(url);
		if (editing_url && len > 0)
			url[len - 1] = '\0';
		break;
	default:
		if (kp->ch == MWKEY_UP) {
			scroll_by(-1);
			break;
		}
		if (kp->ch == MWKEY_DOWN) {
			scroll_by(1);
			break;
		}
		if (editing_url && kp->ch >= 32 && kp->ch < 127) {
			len = (int)strlen(url);
			if (len < MAX_URL - 1) {
				url[len] = (char)kp->ch;
				url[len + 1] = '\0';
			}
		}
		break;
	}
}

static void handle_button(GR_EVENT_BUTTON *bp)
{
	if (bp->y < TOP_H) {
		if (bp->x >= GO_X) {
			editing_url = 0;
			load_url();
		} else {
			editing_url = 1;
			GrSetFocus(win);
		}
		return;
	}

	if (bp->y >= WIN_H - BOTTOM_H) {
		if (bp->x < 56)
			scroll_by(-3);
		else if (bp->x < 118)
			scroll_by(3);
		return;
	}

	editing_url = 0;
	GrSetFocus(win);
}

int main(int argc, char **argv)
{
	GR_EVENT event;

	if (argc > 1) {
		snprintf(url, sizeof(url), "%s", argv[1]);
		if (strstr(url, "://") == NULL) {
			char tmp[MAX_URL];
			snprintf(tmp, sizeof(tmp), "http://%s", url);
			snprintf(url, sizeof(url), "%s", tmp);
		}
	}

	if (GrOpen() < 0) {
		fprintf(stderr, "nxweb: cannot open Nano-X\n");
		return 1;
	}

	font = GrCreateFont(GR_FONT_SYSTEM_FIXED, 0, NULL);
	GrGetFontInfo(font, &fi);

	win = GrNewWindowEx(GR_WM_PROPS_APPWINDOW, "nxweb",
			    GR_ROOT_WINDOW_ID, 0, 0, WIN_W, WIN_H, WHITE);
	GrSelectEvents(win, GR_EVENT_MASK_EXPOSURE |
		       GR_EVENT_MASK_BUTTON_DOWN |
		       GR_EVENT_MASK_KEY_DOWN |
		       GR_EVENT_MASK_FOCUS_IN |
		       GR_EVENT_MASK_FOCUS_OUT |
		       GR_EVENT_MASK_CLOSE_REQ);

	gc_text = GrNewGC();
	gc_inv = GrNewGC();
	gc_frame = GrNewGC();
	gc_bg = GrNewGC();
	gc_link = GrNewGC();

	GrSetGCFont(gc_text, font);
	GrSetGCFont(gc_inv, font);
	GrSetGCFont(gc_frame, font);
	GrSetGCFont(gc_bg, font);
	GrSetGCFont(gc_link, font);
	GrSetGCForeground(gc_text, BLACK);
	GrSetGCBackground(gc_text, WHITE);
	GrSetGCForeground(gc_inv, WHITE);
	GrSetGCBackground(gc_inv, BLACK);
	GrSetGCForeground(gc_frame, BLACK);
	GrSetGCForeground(gc_bg, LTGRAY);
	GrSetGCForeground(gc_link, BLUE);
	GrSetGCBackground(gc_link, WHITE);

	clear_lines();
	add_line("Enter an http:// URL, then tap Go.", 34);
	add_line("Use nxkbd or hardware keys for input.", 38);

	GrMapWindow(win);
	GrSetFocus(win);

	for (;;) {
		GrGetNextEvent(&event);
		switch (event.type) {
		case GR_EVENT_TYPE_EXPOSURE:
			redraw();
			break;
		case GR_EVENT_TYPE_BUTTON_DOWN:
			handle_button(&event.button);
			redraw();
			break;
		case GR_EVENT_TYPE_KEY_DOWN:
			handle_key(&event.keystroke);
			redraw();
			break;
		case GR_EVENT_TYPE_FOCUS_IN:
			have_focus = 1;
			redraw();
			break;
		case GR_EVENT_TYPE_FOCUS_OUT:
			have_focus = 0;
			redraw();
			break;
		case GR_EVENT_TYPE_CLOSE_REQ:
			GrClose();
			return 0;
		}
	}
}
