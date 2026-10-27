/* Freestanding o32 /init for board smoke tests on 2.4/2.6/4.2.
 * No libc or GUI donor image is required. Build/run instructions: HARDWARE.md.
 */
static long call(long nr, long x0, long x1, long x2, long x3, long x4, long x5)
{
	register long v0 __asm__("v0") = nr;
	register long a0 __asm__("a0") = x0;
	register long a1 __asm__("a1") = x1;
	register long a2 __asm__("a2") = x2;
	register long a3 __asm__("a3") = x3;
	__asm__ volatile("addiu $sp,$sp,-32\n\tsw %6,16($sp)\n\tsw %7,20($sp)\n\tsyscall\n\taddiu $sp,$sp,32"
		: "+r"(v0), "+r"(a3)
		: "r"(a0), "r"(a1), "r"(a2), "r"(x3), "r"(x4), "r"(x5)
		: "memory", "$1", "$3", "$8", "$9", "$10", "$11", "$12",
		  "$13", "$14", "$15", "$24", "$25", "hi", "lo");
	return a3 ? -v0 : v0;
}
static unsigned len(const char *p) { unsigned n = 0; while (p[n]) n++; return n; }
static void print(const char *p) { call(4004, 1, (long)p, len(p), 0, 0, 0); }
static long open(const char *p, long flags) { return call(4005,(long)p,flags,0,0,0,0); }
static void close(long fd) { call(4006,fd,0,0,0,0,0); }
static void sleep_seconds(long seconds)
{
	long delay[2] = {seconds,0};
	call(4166,(long)delay,0,0,0,0,0);
}
static char buf[4096];
static unsigned short pixels[256 * 320];
static int display_minor(void)
{
	long fd = open("/proc/misc",0), n;
	unsigned i, j, minor;
	if (fd < 0) return -1;
	n = call(4003,fd,(long)buf,sizeof(buf)-1,0,0,0); close(fd);
	if (n < 0) return -1;
	buf[n] = 0;
	for (i = 0; i < (unsigned)n;) {
		while (buf[i] == ' ') i++;
		minor = 0;
		while (buf[i] >= '0' && buf[i] <= '9') minor = minor*10 + buf[i++]-'0';
		while (buf[i] == ' ') i++;
		for (j = 0; "be300-display"[j] && buf[i+j] == "be300-display"[j]; j++);
		if (!"be300-display"[j] && buf[i+j] == '\n') return minor;
		while (buf[i] && buf[i] != '\n') i++;
		if (buf[i]) i++;
	}
	return -1;
}
void _start(void)
{
	long fd, fb, n; int minor; unsigned x,y;
	static const unsigned short colors[] = {0xf800,0x07e0,0x001f,0xffff,0x8410};
	call(4014,(long)"/dev/console",0020600,(5 << 8)|1,0,0,0);
	fd = open("/dev/console",2);
	if (fd >= 0) {
		call(4063,fd,0,0,0,0,0);
		call(4063,fd,1,0,0,0,0);
		call(4063,fd,2,0,0,0,0);
	}
	call(4039,(long)"/proc",0755,0,0,0,0);
	call(4021,(long)"proc",(long)"/proc",(long)"proc",0,0,0);
	print("BE300_HW_SMOKE: init reached\n");
	minor = display_minor();
	if (minor < 0) { print("BE300_HW_SMOKE: FAIL display registration\n"); goto wait; }
	call(4014,(long)"/dev/be300-display",0020600,(10 << 8)|minor,0,0,0);
	fd = open("/dev/be300-display",2);
	if (fd < 0 || call(4004,fd,(long)"3 7\n",4,0,0,0) != 4) {
		print("BE300_HW_SMOKE: FAIL display write\n"); goto wait;
	}
	n = call(4003,fd,(long)buf,31,0,0,0);
	if (n != 4 || buf[0] != '3' || buf[2] != '7') {
		print("BE300_HW_SMOKE: FAIL display readback\n"); goto wait;
	}
	if (call(4004,fd,(long)"99 7\n",5,0,0,0) != -22) {
		print("BE300_HW_SMOKE: FAIL invalid level accepted\n"); goto wait;
	}
	close(fd);
	print("BE300_HW_SMOKE: display controls PASS\n");
	call(4014,(long)"/dev/fb0",0020600,(29 << 8),0,0,0);
	fb = open("/dev/fb0",2);
	if (fb < 0) { print("BE300_HW_SMOKE: FAIL framebuffer open\n"); goto wait; }
	for (y = 0; y < 320; y++) for (x = 0; x < 256; x++)
		pixels[y*256+x] = x < 240 ? colors[y/64] : 0xdead;
	n = call(4004,fb,(long)pixels,sizeof(pixels),0,0,0);
	if (n != sizeof(pixels)) { print("BE300_HW_SMOKE: FAIL framebuffer write\n"); goto wait; }
	if (call(4054,fb,0x4611,4,0,0,0) < 0 || call(4054,fb,0x4611,0,0,0,0) < 0) {
		print("BE300_HW_SMOKE: FAIL framebuffer blank/unblank\n"); goto wait;
	}
	/* A visual completion marker also works when the dock owns the UART. */
	pixels[0] = 0xffe0; pixels[1] = 0x07ff; pixels[2] = 0xf81f;
	call(4019,fb,319*512,0,0,0,0);
	call(4004,fb,(long)pixels,6,0,0,0);
	print("BE300_HW_SMOKE: framebuffer, blank/unblank PASS\n");
	sleep_seconds(160);
	pixels[0] = pixels[1] = pixels[2] = 0xffff;
	call(4019,fb,319*512,0,0,0,0);
	call(4004,fb,(long)pixels,6,0,0,0);
	close(fb);
	print("BE300_HW_SMOKE: watchdog survival PASS\n");
wait:
	for (;;) sleep_seconds(10);
}
