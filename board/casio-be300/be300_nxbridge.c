/*
 * be300_nxbridge — forward kernel evdev touch events into the 2003
 * Microwindows nano-X server using the GrInjectPointerEvent protocol.
 *
 * The 2003 nano-X binary (from vmlinux-mw's ramdisk) opens only
 * /dev/fb0 + /dev/tty0 — its compiled-in mouse driver has no
 * /dev/input/eventN path, so it can't read the BE-300 touchscreen on
 * its own.  This bridge:
 *   1. opens /dev/input/event1 (touch — patch 0010 evdev),
 *   2. connects to the nano-X UNIX socket /tmp/.nano-X,
 *   3. sends a GrOpen (nxOpenReq, reqType 0, 8 bytes),
 *   4. on each evdev SYN_REPORT, sends GrInjectPointerEvent
 *      (nxInjectEventReq, reqType 60, 20 bytes) carrying the latest
 *      x/y plus a button mask derived from BTN_TOUCH press state.
 *
 * Protocol cribbed from microwindows/src/nanox/nxproto.h and
 * src/nanox/client.c — verified against libnano-X.so disassembly
 * (function code 60, size 20; offsets x=4, y=6, button=8, visible=10,
 * event_type=16).
 *
 * Built freestanding with -march=mips2 -nostdlib like the picogui
 * be300_inputbridge — so the binary boots fine on Linux 2.4.18 +
 * uClibc 0.9.19 dynamic donor rootfs without dragging in any libc.
 */

/* --------------------------- o32 MIPS syscalls --------------------------- */
#define NULL ((void *)0)
typedef int             ssize_t;
typedef unsigned int    size_t;
typedef unsigned int    uint32_t;
typedef int             int32_t;
typedef unsigned short  uint16_t;
typedef short           int16_t;
typedef unsigned char   uint8_t;
typedef int             pid_t;

#define __NR_Linux       4000
#define __NR_exit       (__NR_Linux + 1)
#define __NR_read       (__NR_Linux + 3)
#define __NR_write      (__NR_Linux + 4)
#define __NR_open       (__NR_Linux + 5)
#define __NR_close      (__NR_Linux + 6)
#define __NR_getpid     (__NR_Linux + 20)
#define __NR_ioctl      (__NR_Linux + 54)
#define __NR_fcntl      (__NR_Linux + 55)
#define __NR_select     (__NR_Linux + 142)
#define __NR_nanosleep  (__NR_Linux + 166)
#define __NR_socketcall (__NR_Linux + 102)

#define SYS_SOCKET      1
#define SYS_CONNECT     3
#define SYS_SEND        9

#define O_RDONLY        0
#define O_RDWR          2
#define O_NONBLOCK      0x80
#define AF_UNIX         1
#define SOCK_STREAM     2   /* MIPS: SOCK_STREAM=2, SOCK_DGRAM=1 */

#define EV_SYN          0x00
#define EV_KEY          0x01
#define EV_ABS          0x03
#define SYN_REPORT      0x00
#define ABS_X           0x00
#define ABS_Y           0x01
#define ABS_PRESSURE    0x18
#define BTN_TOUCH       0x14a

/* nano-X request codes — from microwindows/src/nanox/nxproto.h. */
#define GR_NUM_OPEN           0
#define GR_NUM_INJECT_EVENT  60
#define GR_INJECT_EVENT_POINTER  0

static inline long syscall0(long n) {
    register long _n asm("v0") = n;
    register long _v0 asm("v0");
    asm volatile("syscall" : "=r"(_v0) : "r"(_n) : "memory", "$1", "$3",
                 "$8", "$9", "$10", "$11", "$12", "$13", "$14", "$15",
                 "$24", "$25", "hi", "lo");
    return _v0;
}
static inline long syscall1(long n, long a0) {
    register long _n  asm("v0") = n;
    register long _a0 asm("a0") = a0;
    register long _v0 asm("v0");
    asm volatile("syscall" : "=r"(_v0) : "r"(_n), "r"(_a0)
                 : "memory", "$1", "$3", "$8", "$9", "$10", "$11", "$12",
                   "$13", "$14", "$15", "$24", "$25", "hi", "lo");
    return _v0;
}
static inline long syscall2(long n, long a0, long a1) {
    register long _n  asm("v0") = n;
    register long _a0 asm("a0") = a0;
    register long _a1 asm("a1") = a1;
    register long _v0 asm("v0");
    asm volatile("syscall" : "=r"(_v0) : "r"(_n), "r"(_a0), "r"(_a1)
                 : "memory", "$1", "$3", "$8", "$9", "$10", "$11", "$12",
                   "$13", "$14", "$15", "$24", "$25", "hi", "lo");
    return _v0;
}
static inline long syscall3(long n, long a0, long a1, long a2) {
    register long _n  asm("v0") = n;
    register long _a0 asm("a0") = a0;
    register long _a1 asm("a1") = a1;
    register long _a2 asm("a2") = a2;
    register long _v0 asm("v0");
    asm volatile("syscall" : "=r"(_v0) : "r"(_n), "r"(_a0), "r"(_a1), "r"(_a2)
                 : "memory", "$1", "$3", "$8", "$9", "$10", "$11", "$12",
                   "$13", "$14", "$15", "$24", "$25", "hi", "lo");
    return _v0;
}

static long sys_exit(int code)             { return syscall1(__NR_exit, code); }
static long sys_read(int fd, void *b, size_t n) {
    return syscall3(__NR_read, fd, (long)b, n);
}
static long sys_write(int fd, const void *b, size_t n) {
    return syscall3(__NR_write, fd, (long)b, n);
}
static long sys_open(const char *path, int flags) {
    return syscall2(__NR_open, (long)path, flags);
}
static long sys_close(int fd)              { return syscall1(__NR_close, fd); }
static long sys_getpid(void)               { return syscall0(__NR_getpid); }
static long sys_nanosleep(const void *req, void *rem) {
    return syscall2(__NR_nanosleep, (long)req, (long)rem);
}
static long sys_socketcall(int call, unsigned long *args) {
    return syscall2(__NR_socketcall, call, (long)args);
}

/* ----------------------------- helpers ----------------------------- */
static size_t strlen_(const char *s) {
    const char *p = s; while (*p) ++p; return (size_t)(p - s);
}
static void *memset_(void *p, int v, size_t n) {
    unsigned char *q = p; while (n--) *q++ = (unsigned char)v; return p;
}

static void pr(const char *s) { sys_write(2, s, strlen_(s)); }
static void prn(int n) {
    char buf[12]; int i = 0, neg = 0;
    if (n < 0) { neg = 1; n = -n; }
    if (n == 0) buf[i++] = '0';
    else { while (n) { buf[i++] = '0' + (n % 10); n /= 10; } }
    if (neg) buf[i++] = '-';
    char rev[12]; for (int j = 0; j < i; j++) rev[j] = buf[i - 1 - j];
    sys_write(2, rev, (size_t)i);
}

static void sleep_ms(unsigned ms) {
    struct { long tv_sec; long tv_nsec; } ts = { ms / 1000, (long)(ms % 1000) * 1000000L };
    sys_nanosleep(&ts, NULL);
}

/* sockaddr_un layout (Linux generic): sun_family u16, sun_path 108 bytes */
struct sockaddr_un {
    uint16_t sun_family;
    char     sun_path[108];
};

/* Linux input_event on 32-bit MIPS o32: timeval (8) + u16 + u16 + u32 = 16 */
struct input_event {
    long     tv_sec;
    long     tv_usec;
    uint16_t type;
    uint16_t code;
    int32_t  value;
};

/* nxOpenReq layout (8 bytes) — from nxproto.h.  Packed so any
 * surprise alignment requirement (HI/LO load alignment on MIPS, etc.)
 * doesn't expand sizeof() past 8 and break the server's parse. */
struct __attribute__((packed)) nx_open_req {
    uint8_t  reqType;     /* 0  GR_NUM_OPEN */
    uint8_t  hilength;    /* 0 */
    uint16_t length;      /* 8 = sizeof */
    uint32_t pid;
};

/* nxInjectEventReq layout (20 bytes) — pointer variant.
 * Header 4 bytes, then union (12 bytes), then event_type at offset 16.
 * Confirmed by disassembly of libnano-X.so::GrInjectPointerEvent:
 *   sh s1, 8(v0)   button (UINT16)
 *   sb s0,10(v0)   visible (BYTE8)
 *   sh s2, 4(v0)   x (INT16)
 *   sh s3, 6(v0)   y (INT16)
 *   sh 0,16(v0)    event_type=0 (GR_INJECT_EVENT_POINTER)
 */
struct __attribute__((packed)) nx_inject_pointer_req {
    uint8_t  reqType;     /* 60  GR_NUM_INJECT_EVENT */
    uint8_t  hilength;    /* 0 */
    uint16_t length;      /* 20 */
    int16_t  x;
    int16_t  y;
    uint16_t button;
    uint8_t  visible;
    uint8_t  pad0;
    uint8_t  pad1[4];     /* keep union footprint at 12 bytes */
    uint16_t event_type;  /* 0 GR_INJECT_EVENT_POINTER */
    uint16_t pad2;
};

/* ------------------------- nano-X connection ------------------------- */
static int nx_connect(void) {
    unsigned long args[3];
    args[0] = AF_UNIX;
    args[1] = SOCK_STREAM;
    args[2] = 0;
    int sock = (int)sys_socketcall(SYS_SOCKET, args);
    if (sock < 0) { pr("nxbridge: socket failed: "); prn(sock); pr("\n"); return -1; }

    struct sockaddr_un addr;
    memset_(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    /* "/tmp/.nano-X" is 12 chars; +1 for NUL */
    const char *path = "/tmp/.nano-X";
    for (int i = 0; path[i]; i++) addr.sun_path[i] = path[i];
    size_t path_len = strlen_(path);
    /* connect addrlen = offsetof(sun_path) + strlen(sun_path) + 1 */
    size_t addrlen = 2 + path_len + 1;

    args[0] = (unsigned long)sock;
    args[1] = (unsigned long)&addr;
    args[2] = (unsigned long)addrlen;

    /* nano-X server may not be ready; retry up to 30 times at 200 ms. */
    int rc = -1;
    for (int t = 0; t < 30; t++) {
        rc = (int)sys_socketcall(SYS_CONNECT, args);
        if (rc >= 0) break;
        sleep_ms(200);
    }
    if (rc < 0) {
        pr("nxbridge: connect failed: "); prn(rc); pr("\n");
        sys_close(sock);
        return -1;
    }

    /* Send nxOpenReq */
    struct nx_open_req req;
    memset_(&req, 0, sizeof(req));
    req.reqType  = GR_NUM_OPEN;
    req.hilength = 0;
    req.length   = sizeof(req);
    req.pid      = (uint32_t)sys_getpid();

    int reqsz = (int)sizeof(req);
    long w = sys_write(sock, &req, sizeof(req));
    pr("nxbridge: open write w="); prn((int)w);
    pr(" sizeof(req)="); prn(reqsz); pr("\n");
    if (w != (long)sizeof(req)) {
        /* Don't bail — proceed anyway.  Earlier paranoia closed the
         * socket here, but the server accepts the first byte stream
         * and just wants enough header to dispatch; partial writes are
         * unusual on a fresh stream but not strictly fatal. */
        pr("nxbridge: warning: short open write, continuing\n");
    }
    pr("nxbridge: nano-X connected\n");
    return sock;
}

/* Inject pointer event using GrInjectPointerEvent semantics. */
static int nx_inject_pointer(int sock, int16_t x, int16_t y, uint16_t button) {
    struct nx_inject_pointer_req req;
    memset_(&req, 0, sizeof(req));
    req.reqType    = GR_NUM_INJECT_EVENT;
    req.hilength   = 0;
    req.length     = sizeof(req);
    req.x          = x;
    req.y          = y;
    req.button     = button;
    req.visible    = 1;
    req.event_type = GR_INJECT_EVENT_POINTER;

    long w = sys_write(sock, &req, sizeof(req));
    return (w == (long)sizeof(req)) ? 0 : -1;
}

/* ------------------------- evdev open ------------------------- */
static int open_touch_evdev(void) {
    /* Patch 0010 deterministically registers event1 = BE-300 PIU touch
     * (stowaway_be300 links first → event0 = keyboard).  Open by path. */
    int fd = (int)sys_open("/dev/input/event1", O_RDONLY);
    if (fd < 0) {
        pr("nxbridge: opening /dev/input/event1 failed: ");
        prn(fd); pr("\n");
    }
    return fd;
}

/* ---------------------------- main loop ---------------------------- */
void _start(void) {
    pr("nxbridge: starting\n");

    int sock = nx_connect();
    if (sock < 0) { sys_exit(2); }

    int evfd = open_touch_evdev();
    if (evfd < 0) { sys_exit(3); }

    /* Touch state — accumulate ABS_X / ABS_Y / BTN_TOUCH between
     * SYN_REPORTs and send a single GrInjectPointerEvent per frame.
     * BE-300 evdev coords already match the 240x320 LCD geometry (see
     * touch_be300.c absmin/absmax in patch 0010).  Initial position
     * (-1,-1) keeps us from sending bogus events before the first frame.
     */
    int16_t x = -1, y = -1;
    uint16_t btn = 0;
    int dirty = 0;

    pr("nxbridge: forwarding /dev/input/event1 -> nano-X\n");
    for (;;) {
        struct input_event ev;
        long r = sys_read(evfd, &ev, sizeof(ev));
        if (r != (long)sizeof(ev)) {
            pr("nxbridge: short read: "); prn((int)r); pr("\n");
            sleep_ms(50);
            continue;
        }

        switch (ev.type) {
        case EV_SYN:
            if (ev.code == SYN_REPORT && dirty && x >= 0 && y >= 0) {
                if (nx_inject_pointer(sock, x, y, btn) < 0) {
                    pr("nxbridge: inject write failed; continuing\n");
                }
                dirty = 0;
            }
            break;
        case EV_ABS:
            if (ev.code == ABS_X) { x = (int16_t)ev.value; dirty = 1; }
            else if (ev.code == ABS_Y) { y = (int16_t)ev.value; dirty = 1; }
            break;
        case EV_KEY:
            if (ev.code == BTN_TOUCH) {
                btn = ev.value ? 1 : 0;
                dirty = 1;
            }
            break;
        default:
            break;
        }
    }

    /* unreachable */
    sys_close(evfd);
    sys_close(sock);
    sys_exit(0);
}
