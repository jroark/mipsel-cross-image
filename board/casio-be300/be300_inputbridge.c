/*
 * be300_inputbridge — forward kernel evdev events into pgserver via the
 * client-side input-filter protocol.
 *
 * The 2002 picogui-demo pgserver has no server-side input drivers
 * compiled in (`pgserver -l` shows "Input drivers:" empty), so it can't
 * read /dev/input/event* itself.  pgboard already proves the protocol
 * works in the other direction: clients can register an input filter
 * (PGREQ_MKINFILTER) and inject events (PGREQ_INFILTERSEND).  This
 * bridge does exactly that for touch + Stowaway keyboard.
 *
 * Implemented with raw o32 MIPS syscalls (no libc) because:
 *   - static-glibc binaries crash on Linux 2.4.18 (clock_gettime /
 *     set_tid_address absent in startup).
 *   - we don't have a uClibc 0.9.15 toolchain matching the 2002 rootfs.
 *   - the picogui wire protocol is small enough to inline.
 *
 * Built freestanding with -march=mips2 -nostdlib so the binary loads
 * on the BE-300's VR4131 the same way the existing tcp_loopback_test
 * binary does.
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
#define __NR_ioctl      (__NR_Linux + 54)
#define __NR_fcntl      (__NR_Linux + 55)
#define __NR_select     (__NR_Linux + 142)
#define __NR_nanosleep  (__NR_Linux + 166)
#define __NR_socketcall (__NR_Linux + 102)
#define __NR_getdents   (__NR_Linux + 141)

#define SYS_SOCKET    1
#define SYS_BIND      2
#define SYS_CONNECT   3
#define SYS_LISTEN    4
#define SYS_ACCEPT    5
#define SYS_GETSOCKNAME 6
#define SYS_SEND      9
#define SYS_RECV      10
#define SYS_SHUTDOWN  13

#define O_RDONLY        0
#define O_NONBLOCK      0x80
#define AF_INET         2
#define SOCK_STREAM     2   /* MIPS: SOCK_STREAM=2, SOCK_DGRAM=1 */

#define EV_SYN          0x00
#define EV_KEY          0x01
#define EV_ABS          0x03
#define ABS_X           0x00
#define ABS_Y           0x01
#define ABS_PRESSURE    0x18
#define BTN_TOUCH       0x14a

/* Subset of Linux KEY_* codes we care about (asm/input.h values). */
#define KEY_RESERVED    0
#define KEY_ESC         1
#define KEY_1           2
#define KEY_2           3
#define KEY_3           4
#define KEY_4           5
#define KEY_5           6
#define KEY_6           7
#define KEY_7           8
#define KEY_8           9
#define KEY_9           10
#define KEY_0           11
#define KEY_MINUS       12
#define KEY_EQUAL       13
#define KEY_BACKSPACE   14
#define KEY_TAB         15
#define KEY_Q           16
#define KEY_W           17
#define KEY_E           18
#define KEY_R           19
#define KEY_T           20
#define KEY_Y           21
#define KEY_U           22
#define KEY_I           23
#define KEY_O           24
#define KEY_P           25
#define KEY_LEFTBRACE   26
#define KEY_RIGHTBRACE  27
#define KEY_ENTER       28
#define KEY_LEFTCTRL    29
#define KEY_A           30
#define KEY_S           31
#define KEY_D           32
#define KEY_F           33
#define KEY_G           34
#define KEY_H           35
#define KEY_J           36
#define KEY_K           37
#define KEY_L           38
#define KEY_SEMICOLON   39
#define KEY_APOSTROPHE  40
#define KEY_GRAVE       41
#define KEY_LEFTSHIFT   42
#define KEY_BACKSLASH   43
#define KEY_Z           44
#define KEY_X           45
#define KEY_C           46
#define KEY_V           47
#define KEY_B           48
#define KEY_N           49
#define KEY_M           50
#define KEY_COMMA       51
#define KEY_DOT         52
#define KEY_SLASH       53
#define KEY_RIGHTSHIFT  54
#define KEY_LEFTALT     56
#define KEY_SPACE       57
#define KEY_F1          59
#define KEY_F2          60
#define KEY_F3          61
#define KEY_F4          62
#define KEY_F5          63
#define KEY_F6          64
#define KEY_F7          65
#define KEY_F8          66
#define KEY_F9          67
#define KEY_F10         68
#define KEY_HOME        102
#define KEY_UP          103
#define KEY_PAGEUP      104
#define KEY_LEFT        105
#define KEY_RIGHT       106
#define KEY_END         107
#define KEY_DOWN        108
#define KEY_PAGEDOWN    109
#define KEY_INSERT      110
#define KEY_DELETE      111
#define KEY_RIGHTCTRL   97
#define KEY_RIGHTALT    100
#define KEY_F11         87
#define KEY_F12         88

#define EVIOCGNAME_LEN  64
/* MIPS _IOC layout differs from generic Linux:
 *   MIPS:   _IOC_DIRBITS=3,   _IOC_DIRSHIFT=29,  _IOC_READ=2 (same)
 *   generic: _IOC_DIRBITS=2,  _IOC_DIRSHIFT=30,  _IOC_READ=2
 * (See linux-2.4.18/include/asm-mips/ioctl.h vs asm-generic/ioctl.h.)
 * EVIOCGNAME(64) on MIPS = (2<<29) | (64<<16) | ('E'<<8) | 0x06 = 0x40404506.
 */
#define _IOC_READ       2u
#define EVIOCGNAME(len) ((_IOC_READ << 29) | ((unsigned)(len) << 16) | ('E' << 8) | 0x06)

/* o32 MIPS syscall ABI: nr -> $v0, args -> $a0..$a3, $sp+16/+20 for arg5/6.
 * Returns ($v0, $a3): $a3 nonzero == error, $v0 = errno. */
static long syscall0(long nr) {
    register long _nr __asm__("$2") = nr;
    register long _err __asm__("$7");
    register long _ret __asm__("$2");
    __asm__ __volatile__("syscall" : "=r"(_ret), "=r"(_err) : "r"(_nr)
        : "$1","$3","$4","$5","$6","$8","$9","$10","$11","$12","$13","$14","$15","$24","$25","memory");
    return _err ? -_ret : _ret;
}
static long syscall1(long nr, long a) {
    register long _nr __asm__("$2") = nr;
    register long _a0 __asm__("$4") = a;
    register long _err __asm__("$7");
    register long _ret __asm__("$2");
    __asm__ __volatile__("syscall" : "=r"(_ret), "=r"(_err) : "r"(_nr), "r"(_a0)
        : "$1","$3","$5","$6","$8","$9","$10","$11","$12","$13","$14","$15","$24","$25","memory");
    return _err ? -_ret : _ret;
}
static long syscall2(long nr, long a, long b) {
    register long _nr __asm__("$2") = nr;
    register long _a0 __asm__("$4") = a;
    register long _a1 __asm__("$5") = b;
    register long _err __asm__("$7");
    register long _ret __asm__("$2");
    __asm__ __volatile__("syscall" : "=r"(_ret), "=r"(_err) : "r"(_nr), "r"(_a0), "r"(_a1)
        : "$1","$3","$6","$8","$9","$10","$11","$12","$13","$14","$15","$24","$25","memory");
    return _err ? -_ret : _ret;
}
static long syscall3(long nr, long a, long b, long c) {
    register long _nr __asm__("$2") = nr;
    register long _a0 __asm__("$4") = a;
    register long _a1 __asm__("$5") = b;
    register long _a2 __asm__("$6") = c;
    register long _err __asm__("$7");
    register long _ret __asm__("$2");
    __asm__ __volatile__("syscall" : "=r"(_ret), "=r"(_err) : "r"(_nr), "r"(_a0), "r"(_a1), "r"(_a2)
        : "$1","$3","$8","$9","$10","$11","$12","$13","$14","$15","$24","$25","memory");
    return _err ? -_ret : _ret;
}

static ssize_t sys_write(int fd, const void *buf, size_t n) {
    return syscall3(__NR_write, fd, (long)buf, n);
}
static ssize_t sys_read(int fd, void *buf, size_t n) {
    return syscall3(__NR_read, fd, (long)buf, n);
}
static int sys_open(const char *path, int flags) {
    return syscall2(__NR_open, (long)path, flags);
}
static int sys_close(int fd) { return syscall1(__NR_close, fd); }
static int sys_ioctl(int fd, unsigned long req, void *arg) {
    return syscall3(__NR_ioctl, fd, req, (long)arg);
}
static int sys_getdents(int fd, void *buf, unsigned int n) {
    return syscall3(__NR_getdents, fd, (long)buf, n);
}
static void sys_exit(int n) { syscall1(__NR_exit, n); while(1) {} }

struct timespec_ { long tv_sec; long tv_nsec; };
static int sys_nanosleep(long sec, long nsec) {
    struct timespec_ ts = { sec, nsec };
    return syscall2(__NR_nanosleep, (long)&ts, 0);
}

struct sockaddr_in {
    uint16_t sin_family;
    uint16_t sin_port;
    uint32_t sin_addr;
    uint8_t  sin_zero[8];
};

static long sock_call(long op, long a, long b, long c) {
    long args[3] = { a, b, c };
    return syscall2(__NR_socketcall, op, (long)args);
}
static long sock_call4(long op, long a, long b, long c, long d) {
    long args[4] = { a, b, c, d };
    return syscall2(__NR_socketcall, op, (long)args);
}

/* select via syscall5 stub.  o32: arg5 is on stack at sp+16. */
struct fd_set_ { unsigned long fds_bits[32]; };
static void fd_zero(struct fd_set_ *s) {
    for (int i = 0; i < 32; i++) s->fds_bits[i] = 0;
}
static void fd_set_(int fd, struct fd_set_ *s) {
    s->fds_bits[fd >> 5] |= 1u << (fd & 31);
}
static int fd_isset_(int fd, struct fd_set_ *s) {
    return (s->fds_bits[fd >> 5] >> (fd & 31)) & 1;
}

/* o32 5-arg syscall: nr in $v0, args in $a0..$a3 and one on stack at sp+16.
 * gcc generates the stack push automatically when we declare a 5-arg
 * function with proper inline asm.  Use the legacy 5-arg select syscall
 * (Linux 2.4 has it as __NR_select = 4142). */
static int sys_select5(int n, void *rfds, void *wfds, void *efds, void *tv) {
    register long _nr __asm__("$2") = __NR_select;
    register long _a0 __asm__("$4") = n;
    register long _a1 __asm__("$5") = (long)rfds;
    register long _a2 __asm__("$6") = (long)wfds;
    register long _a3 __asm__("$7") = (long)efds;
    register long _err __asm__("$7");
    register long _ret __asm__("$2");
    /* Push tv on stack at $sp+16 (the o32 reserved argument save area). */
    __asm__ __volatile__(
        "addiu $sp, $sp, -32\n\t"
        "sw    %6, 16($sp)\n\t"
        "syscall\n\t"
        "addiu $sp, $sp, 32"
        : "=r"(_ret), "=r"(_err)
        : "r"(_nr), "r"(_a0), "r"(_a1), "r"(_a2), "r"((long)tv), "r"(_a3)
        : "$1","$3","$8","$9","$10","$11","$12","$13","$14","$15","$24","$25","memory");
    return _err ? -_ret : _ret;
}

/* --------------------------- minimal string utils --------------------------- */
static size_t strlen_(const char *s) { size_t n = 0; while (s[n]) n++; return n; }
static int strncmp_(const char *a, const char *b, size_t n) {
    for (size_t i = 0; i < n; i++) {
        unsigned char ca = a[i], cb = b[i];
        if (ca != cb) return ca - cb;
        if (!ca) return 0;
    }
    return 0;
}
static int strcmp_(const char *a, const char *b) {
    while (*a == *b && *a) { a++; b++; }
    return (unsigned char)*a - (unsigned char)*b;
}
static const char *strstr_(const char *h, const char *n) {
    size_t nl = strlen_(n);
    if (!nl) return h;
    for (; *h; h++) if (!strncmp_(h, n, nl)) return h;
    return NULL;
}
static void *memset_(void *p, int c, size_t n) {
    unsigned char *q = p;
    for (size_t i = 0; i < n; i++) q[i] = (unsigned char)c;
    return p;
}
/* gcc emits implicit calls to memset/memcpy for struct = {0} and similar.
 * Provide them so -nostdlib still links. */
void *memset(void *p, int c, size_t n) { return memset_(p, c, n); }
void *memcpy(void *d, const void *s, size_t n) {
    unsigned char *dd = d; const unsigned char *ss = s;
    for (size_t i = 0; i < n; i++) dd[i] = ss[i];
    return d;
}

static int log_fd = -1;
static void logs(const char *s) { sys_write(log_fd >= 0 ? log_fd : 2, s, strlen_(s)); }
static void logn(long v) {
    char buf[12]; int i = 11; buf[i--] = 0;
    int neg = v < 0; unsigned long u = neg ? -v : v;
    if (u == 0) buf[i--] = '0';
    while (u) { buf[i--] = '0' + (u % 10); u /= 10; }
    if (neg) buf[i--] = '-';
    sys_write(log_fd >= 0 ? log_fd : 2, buf + i + 1, 11 - i - 1);
}

/* --------------------------- byte order helpers --------------------------- */
static uint32_t htonl_(uint32_t v) {
    return ((v & 0xff) << 24) | ((v & 0xff00) << 8) |
           ((v & 0xff0000) >> 8) | ((v >> 24) & 0xff);
}
static uint16_t htons_(uint16_t v) {
    return (uint16_t)(((v & 0xff) << 8) | ((v >> 8) & 0xff));
}
#define ntohl_ htonl_
#define ntohs_ htons_

/* --------------------------- picogui wire protocol --------------------------- */
#define PG_REQUEST_PORT     30450
#define PG_REQUEST_MAGIC    0x31415926

#define PGREQ_PING          0
#define PGREQ_UPDATE        1
#define PGREQ_MKINFILTER    11
#define PGREQ_INFILTERSEND  53

#define PG_RESPONSE_ERR     1
#define PG_RESPONSE_RET     2
#define PG_RESPONSE_EVENT   3
#define PG_RESPONSE_DATA    4

#define PG_TRIGGER_KEYUP        (1u<<5)
#define PG_TRIGGER_KEYDOWN      (1u<<6)
#define PG_TRIGGER_CHAR         (1u<<14)
#define PG_TRIGGER_PNTR_STATUS  (1u<<18)
#define PG_TRIGGER_TOUCHSCREEN  (1u<<21)

#define PG_TRIGGERS_MOUSE  ((1u<<1)|(1u<<7)|(1u<<8)|(1u<<9)|(1u<<10)|(1u<<13)|(1u<<18)|(1u<<20)|(1u<<21)|(1u<<22))
#define PG_TRIGGERS_KEY    ((1u<<5)|(1u<<6)|(1u<<14)|(1u<<16)|(1u<<19))

#define PGMOD_LSHIFT  0x0001
#define PGMOD_RSHIFT  0x0002
#define PGMOD_LCTRL   0x0040
#define PGMOD_RCTRL   0x0080
#define PGMOD_LALT    0x0100
#define PGMOD_RALT    0x0200

#define PGKEY_BACKSPACE  8
#define PGKEY_TAB        9
#define PGKEY_RETURN     13
#define PGKEY_ESCAPE     27
#define PGKEY_SPACE      32
#define PGKEY_DELETE     127
#define PGKEY_UP         273
#define PGKEY_DOWN       274
#define PGKEY_RIGHT      275
#define PGKEY_LEFT       276
#define PGKEY_INSERT     277
#define PGKEY_HOME       278
#define PGKEY_END        279
#define PGKEY_PAGEUP     280
#define PGKEY_PAGEDOWN   281
#define PGKEY_F1         282
#define PGKEY_RSHIFT     303
#define PGKEY_LSHIFT     304
#define PGKEY_RCTRL      305
#define PGKEY_LCTRL      306
#define PGKEY_RALT       307
#define PGKEY_LALT       308

/* struct pghello (8 bytes). */
struct pghello {
    uint32_t magic;
    uint16_t protover;
    uint16_t serverversion;
};

/* struct pgrequest (12 bytes). */
struct pgrequest {
    uint32_t id;
    uint32_t size;
    uint16_t type;
    uint16_t dummy;
};

static int pgfd = -1;
static uint32_t req_id = 0;

static int read_all(int fd, void *buf, size_t n) {
    size_t off = 0;
    while (off < n) {
        ssize_t r = sys_read(fd, (char *)buf + off, n - off);
        if (r < 0) { if (r == -4 /*EINTR*/) continue; return -1; }
        if (r == 0) return -1;
        off += r;
    }
    return 0;
}
static int write_all(int fd, const void *buf, size_t n) {
    size_t off = 0;
    while (off < n) {
        ssize_t r = sys_write(fd, (const char *)buf + off, n - off);
        if (r < 0) { if (r == -4) continue; return -1; }
        off += r;
    }
    return 0;
}

static int pg_send_req(uint16_t type, const void *arg, uint32_t argsize) {
    struct pgrequest hdr;
    hdr.id    = htonl_(++req_id);
    hdr.size  = htonl_(argsize);
    hdr.type  = htons_(type);
    hdr.dummy = 0;
    if (write_all(pgfd, &hdr, sizeof(hdr)) < 0) return -1;
    if (argsize && write_all(pgfd, arg, argsize) < 0) return -1;
    return 0;
}

static int pg_read_response(uint32_t *handle_out) {
    while (1) {
        uint16_t type;
        if (read_all(pgfd, &type, 2) < 0) return -1;
        type = ntohs_(type);
        if (type == PG_RESPONSE_RET) {
            uint16_t dummy;
            uint32_t id, data;
            if (read_all(pgfd, &dummy, 2) < 0) return -1;
            if (read_all(pgfd, &id, 4) < 0) return -1;
            if (read_all(pgfd, &data, 4) < 0) return -1;
            if (handle_out) *handle_out = ntohl_(data);
            return 0;
        } else if (type == PG_RESPONSE_ERR) {
            uint16_t errt, msglen, dummy;
            uint32_t id;
            if (read_all(pgfd, &errt, 2) < 0) return -1;
            if (read_all(pgfd, &msglen, 2) < 0) return -1;
            if (read_all(pgfd, &dummy, 2) < 0) return -1;
            if (read_all(pgfd, &id, 4) < 0) return -1;
            msglen = ntohs_(msglen);
            char waste[64];
            while (msglen) {
                size_t take = msglen < sizeof(waste) ? msglen : sizeof(waste);
                if (read_all(pgfd, waste, take) < 0) return -1;
                msglen -= take;
            }
            logs("[inputbridge] server ERR\n");
            return -1;
        } else if (type == PG_RESPONSE_EVENT) {
            char waste[10];
            if (read_all(pgfd, waste, 10) < 0) return -1;
        } else if (type == PG_RESPONSE_DATA) {
            uint16_t dummy;
            uint32_t id, size;
            if (read_all(pgfd, &dummy, 2) < 0) return -1;
            if (read_all(pgfd, &id, 4) < 0) return -1;
            if (read_all(pgfd, &size, 4) < 0) return -1;
            size = ntohl_(size);
            char waste[64];
            while (size) {
                size_t take = size < sizeof(waste) ? size : sizeof(waste);
                if (read_all(pgfd, waste, take) < 0) return -1;
                size -= take;
            }
        } else {
            logs("[inputbridge] unknown response type "); logn(type); logs("\n");
            return -1;
        }
    }
}

static int pg_connect(void) {
    pgfd = (int)sock_call(SYS_SOCKET, AF_INET, SOCK_STREAM, 0);
    if (pgfd < 0) { logs("[inputbridge] socket failed: "); logn(pgfd); logs("\n"); return -1; }
    struct sockaddr_in sa;
    memset_(&sa, 0, sizeof(sa));
    sa.sin_family = AF_INET;
    sa.sin_port = htons_(PG_REQUEST_PORT);
    sa.sin_addr = htonl_(0x7f000001);  /* 127.0.0.1 */
    long r = sock_call(SYS_CONNECT, pgfd, (long)&sa, sizeof(sa));
    if (r < 0) {
        sys_close(pgfd); pgfd = -1;
        return -1;
    }
    struct pghello hello;
    if (read_all(pgfd, &hello, sizeof(hello)) < 0) {
        logs("[inputbridge] pghello read failed\n");
        return -1;
    }
    if (ntohl_(hello.magic) != PG_REQUEST_MAGIC) {
        logs("[inputbridge] bad pghello magic 0x");
        logn(ntohl_(hello.magic)); logs("\n");
        return -1;
    }
    logs("[inputbridge] connected to pgserver protover=");
    logn(ntohs_(hello.protover)); logs("\n");
    return 0;
}

static uint32_t pg_mkinfilter(uint32_t accept_trigs, uint32_t absorb_trigs) {
    struct {
        uint32_t insert_after;
        uint32_t accept_trigs;
        uint32_t absorb_trigs;
    } arg;
    arg.insert_after = htonl_(0);
    arg.accept_trigs = htonl_(accept_trigs);
    arg.absorb_trigs = htonl_(absorb_trigs);
    if (pg_send_req(PGREQ_MKINFILTER, &arg, sizeof(arg)) < 0) return 0;
    uint32_t handle = 0;
    if (pg_read_response(&handle) < 0) return 0;
    logs("[inputbridge] infilter handle="); logn(handle); logs("\n");
    return handle;
}

#define TRIG_NWORDS 16
static int pg_filter_send(uint32_t trig[TRIG_NWORDS]) {
    uint32_t buf[TRIG_NWORDS];
    for (int i = 0; i < TRIG_NWORDS; i++) buf[i] = htonl_(trig[i]);
    return pg_send_req(PGREQ_INFILTERSEND, buf, sizeof(buf));
}

static void send_pointer(uint32_t filter, uint32_t x, uint32_t y,
                         uint32_t btn, uint32_t pressure, uint32_t chbtn) {
    uint32_t t[TRIG_NWORDS];
    memset_(t, 0, sizeof(t));
    t[0] = filter;
    t[1] = PG_TRIGGER_PNTR_STATUS;
    t[2] = x; t[3] = y; t[4] = btn; t[5] = pressure; t[6] = chbtn;
    pg_filter_send(t);
}
static void send_key(uint32_t filter, int down, uint16_t pgkey, uint16_t mods) {
    uint32_t t[TRIG_NWORDS];
    memset_(t, 0, sizeof(t));
    t[0] = filter;
    t[1] = down ? PG_TRIGGER_KEYDOWN : PG_TRIGGER_KEYUP;
    t[2] = pgkey; t[3] = mods;
    pg_filter_send(t);
}

/* picogui drivers send PG_TRIGGER_CHAR alongside KEYDOWN for printable
 * keys; that's what actually inserts text into widgets.  Without this,
 * KEYDOWN updates focus state but no characters appear. */
static void send_char(uint32_t filter, uint16_t ch, uint16_t mods) {
    uint32_t t[TRIG_NWORDS];
    memset_(t, 0, sizeof(t));
    t[0] = filter;
    t[1] = PG_TRIGGER_CHAR;
    t[2] = ch; t[3] = mods;
    pg_filter_send(t);
}

/* US-keyboard shift table for ASCII keys.  Returns the shifted glyph,
 * or 0 if not a printable that has a shifted form. */
static uint16_t shift_us(uint16_t c) {
    if (c >= 'a' && c <= 'z') return c - 'a' + 'A';
    switch (c) {
    case '1': return '!'; case '2': return '@'; case '3': return '#';
    case '4': return '$'; case '5': return '%'; case '6': return '^';
    case '7': return '&'; case '8': return '*'; case '9': return '(';
    case '0': return ')';
    case '-': return '_'; case '=': return '+';
    case '[': return '{'; case ']': return '}';
    case '\\': return '|';
    case ';': return ':'; case '\'': return '"';
    case '`': return '~';
    case ',': return '<'; case '.': return '>'; case '/': return '?';
    }
    return c;  /* non-shiftable printable */
}

/* --------------------------- evdev device discovery --------------------------- */
/* Read /dev/input via getdents (no opendir/readdir).  Open each event*
 * node, EVIOCGNAME, strstr() for the target needle. */
struct linux_dirent_ {
    long           d_ino;
    long           d_off;
    unsigned short d_reclen;
    char           d_name[];
};

static int open_evdev_by_name(const char *needle) {
    int dfd = sys_open("/dev/input", O_RDONLY | O_NONBLOCK);
    if (dfd < 0) return -1;
    char buf[2048];
    int found_fd = -1;
    while (1) {
        int n = sys_getdents(dfd, buf, sizeof(buf));
        if (n <= 0) break;
        int off = 0;
        while (off < n) {
            struct linux_dirent_ *de = (struct linux_dirent_ *)(buf + off);
            off += de->d_reclen;
            if (strncmp_(de->d_name, "event", 5) != 0) continue;
            char path[64];
            int p = 0;
            const char *prefix = "/dev/input/";
            while (prefix[p]) { path[p] = prefix[p]; p++; }
            int k = 0;
            while (de->d_name[k] && p < (int)sizeof(path)-1) { path[p++] = de->d_name[k++]; }
            path[p] = 0;
            int fd = sys_open(path, O_RDONLY | O_NONBLOCK);
            if (fd < 0) continue;
            char devname[EVIOCGNAME_LEN];
            memset_(devname, 0, sizeof(devname));
            long r = sys_ioctl(fd, EVIOCGNAME(EVIOCGNAME_LEN), devname);
            if (r > 0 && strstr_(devname, needle)) {
                logs("[inputbridge] "); logs(needle); logs(" = ");
                logs(path); logs(" ("); logs(devname); logs(")\n");
                found_fd = fd;
                goto done;
            }
            sys_close(fd);
        }
    }
done:
    sys_close(dfd);
    return found_fd;
}

/* Linux 2.4 / MIPS-32 evdev record: 16 bytes. */
struct evdev_wire {
    int32_t  tv_sec;
    int32_t  tv_usec;
    uint16_t type;
    uint16_t code;
    int32_t  value;
};

/* Linux KEY_* -> PGKEY_*.  Returns 0 for unmapped. */
static uint16_t evdev_to_pgkey(uint16_t code) {
    /* ASCII zone — most printables map 1:1 to lowercase ASCII. */
    static const struct { uint16_t kc; uint16_t pg; } tbl[] = {
        { KEY_ENTER, PGKEY_RETURN }, { KEY_ESC, PGKEY_ESCAPE },
        { KEY_BACKSPACE, PGKEY_BACKSPACE }, { KEY_TAB, PGKEY_TAB },
        { KEY_SPACE, PGKEY_SPACE },
        { KEY_UP, PGKEY_UP }, { KEY_DOWN, PGKEY_DOWN },
        { KEY_LEFT, PGKEY_LEFT }, { KEY_RIGHT, PGKEY_RIGHT },
        { KEY_HOME, PGKEY_HOME }, { KEY_END, PGKEY_END },
        { KEY_PAGEUP, PGKEY_PAGEUP }, { KEY_PAGEDOWN, PGKEY_PAGEDOWN },
        { KEY_INSERT, PGKEY_INSERT }, { KEY_DELETE, PGKEY_DELETE },
        { KEY_LEFTSHIFT, PGKEY_LSHIFT }, { KEY_RIGHTSHIFT, PGKEY_RSHIFT },
        { KEY_LEFTCTRL, PGKEY_LCTRL }, { KEY_RIGHTCTRL, PGKEY_RCTRL },
        { KEY_LEFTALT, PGKEY_LALT }, { KEY_RIGHTALT, PGKEY_RALT },
        { KEY_F1, PGKEY_F1 }, { KEY_F2, PGKEY_F1+1 }, { KEY_F3, PGKEY_F1+2 },
        { KEY_F4, PGKEY_F1+3 }, { KEY_F5, PGKEY_F1+4 }, { KEY_F6, PGKEY_F1+5 },
        { KEY_F7, PGKEY_F1+6 }, { KEY_F8, PGKEY_F1+7 }, { KEY_F9, PGKEY_F1+8 },
        { KEY_F10, PGKEY_F1+9 }, { KEY_F11, PGKEY_F1+10 }, { KEY_F12, PGKEY_F1+11 },
        { KEY_A,'a' },{ KEY_B,'b' },{ KEY_C,'c' },{ KEY_D,'d' },{ KEY_E,'e' },
        { KEY_F,'f' },{ KEY_G,'g' },{ KEY_H,'h' },{ KEY_I,'i' },{ KEY_J,'j' },
        { KEY_K,'k' },{ KEY_L,'l' },{ KEY_M,'m' },{ KEY_N,'n' },{ KEY_O,'o' },
        { KEY_P,'p' },{ KEY_Q,'q' },{ KEY_R,'r' },{ KEY_S,'s' },{ KEY_T,'t' },
        { KEY_U,'u' },{ KEY_V,'v' },{ KEY_W,'w' },{ KEY_X,'x' },{ KEY_Y,'y' },
        { KEY_Z,'z' },
        { KEY_0,'0' },{ KEY_1,'1' },{ KEY_2,'2' },{ KEY_3,'3' },{ KEY_4,'4' },
        { KEY_5,'5' },{ KEY_6,'6' },{ KEY_7,'7' },{ KEY_8,'8' },{ KEY_9,'9' },
        { KEY_MINUS,'-' },{ KEY_EQUAL,'=' },{ KEY_LEFTBRACE,'[' },{ KEY_RIGHTBRACE,']' },
        { KEY_SEMICOLON,';' },{ KEY_APOSTROPHE,'\'' },{ KEY_GRAVE,'`' },
        { KEY_BACKSLASH,'\\' },{ KEY_COMMA,',' },{ KEY_DOT,'.' },{ KEY_SLASH,'/' },
    };
    for (size_t i = 0; i < sizeof(tbl)/sizeof(tbl[0]); i++)
        if (tbl[i].kc == code) return tbl[i].pg;
    return 0;
}

/* --------------------------- _start (entry point) --------------------------- */
void _start(void) {
    /* fd 2 = stderr inherits from parent shell (rcS redirects to ttyS0). */
    log_fd = 2;
    logs("[inputbridge] starting\n");

    /* Retry pgserver connect up to 60 times, 500 ms apart. */
    int attempt;
    for (attempt = 0; attempt < 60; attempt++) {
        if (pg_connect() == 0) break;
        if (pgfd >= 0) { sys_close(pgfd); pgfd = -1; }
        sys_nanosleep(0, 500 * 1000 * 1000);
    }
    if (pgfd < 0) {
        logs("[inputbridge] giving up — pgserver unreachable\n");
        sys_exit(1);
    }

    int kbd_fd = open_evdev_by_name("Stowaway");
    if (kbd_fd < 0) kbd_fd = open_evdev_by_name("BE-300 Buttons");
    int touch_fd = open_evdev_by_name("BE-300 PIU touch");
    if (kbd_fd < 0 && touch_fd < 0) {
        logs("[inputbridge] no input devices found\n");
        sys_exit(2);
    }

    uint32_t filter = pg_mkinfilter(PG_TRIGGERS_MOUSE | PG_TRIGGERS_KEY, 0);
    if (filter == 0) { logs("[inputbridge] pg_mkinfilter failed\n"); sys_exit(3); }

    logs("[inputbridge] entering event loop\n");

    /* Touch state — accumulated until EV_SYN. */
    uint32_t tx = 0, ty = 0, tp = 0;
    uint32_t tbtn = 0, prev_tbtn = 0;
    uint16_t kbd_mods = 0;

    while (1) {
        struct fd_set_ rfds;
        fd_zero(&rfds);
        int maxfd = pgfd;
        fd_set_(pgfd, &rfds);
        if (kbd_fd  >= 0) { fd_set_(kbd_fd,  &rfds); if (kbd_fd  > maxfd) maxfd = kbd_fd; }
        if (touch_fd>= 0) { fd_set_(touch_fd,&rfds); if (touch_fd> maxfd) maxfd = touch_fd; }
        int r = sys_select5(maxfd + 1, &rfds, NULL, NULL, NULL);
        if (r < 0) { if (r == -4) continue; logs("[inputbridge] select failed: "); logn(r); logs("\n"); break; }

        if (fd_isset_(pgfd, &rfds)) {
            char waste[256];
            ssize_t n = sys_read(pgfd, waste, sizeof(waste));
            if (n <= 0) { logs("[inputbridge] pgserver disconnect\n"); break; }
        }
        if (touch_fd >= 0 && fd_isset_(touch_fd, &rfds)) {
            struct evdev_wire ev;
            while (sys_read(touch_fd, &ev, sizeof(ev)) == (ssize_t)sizeof(ev)) {
                if (ev.type == EV_ABS) {
                    if (ev.code == ABS_X) tx = ev.value;
                    else if (ev.code == ABS_Y) ty = ev.value;
                    else if (ev.code == ABS_PRESSURE) tp = ev.value;
                } else if (ev.type == EV_KEY && ev.code == BTN_TOUCH) {
                    tbtn = ev.value ? 1 : 0;
                } else if (ev.type == EV_SYN) {
                    uint32_t chbtn = tbtn ^ prev_tbtn;
                    send_pointer(filter, tx, ty, tbtn, tp, chbtn);
                    /* On touch-up, kick pgserver to redraw — popup menus
                     * and dialog dismissals otherwise leave the previous
                     * area stale because picogui's damage tracking on
                     * synthetic input is lighter than for native drivers. */
                    if (prev_tbtn && !tbtn) {
                        pg_send_req(PGREQ_UPDATE, NULL, 0);
                    }
                    prev_tbtn = tbtn;
                }
            }
        }
        if (kbd_fd >= 0 && fd_isset_(kbd_fd, &rfds)) {
            struct evdev_wire ev;
            while (sys_read(kbd_fd, &ev, sizeof(ev)) == (ssize_t)sizeof(ev)) {
                if (ev.type != EV_KEY) continue;
                int down = ev.value ? 1 : 0;
                uint16_t bit = 0;
                switch (ev.code) {
                case KEY_LEFTSHIFT:  bit = PGMOD_LSHIFT; break;
                case KEY_RIGHTSHIFT: bit = PGMOD_RSHIFT; break;
                case KEY_LEFTCTRL:   bit = PGMOD_LCTRL;  break;
                case KEY_RIGHTCTRL:  bit = PGMOD_RCTRL;  break;
                case KEY_LEFTALT:    bit = PGMOD_LALT;   break;
                case KEY_RIGHTALT:   bit = PGMOD_RALT;   break;
                }
                if (bit) {
                    if (down) kbd_mods |= bit;
                    else      kbd_mods &= ~bit;
                }
                uint16_t pgkey = evdev_to_pgkey(ev.code);
                if (pgkey == 0) continue;
                if (ev.value == 2) continue;  /* skip autorepeat */
                send_key(filter, down, pgkey, kbd_mods);
                /* For printable keys on key-DOWN (or repeat), also send a
                 * CHAR trigger with the shifted glyph.  picogui widgets
                 * react to CHAR for text input; KEYDOWN alone only moves
                 * focus / triggers shortcuts. */
                if (down && pgkey >= 0x20 && pgkey < 0x7f) {
                    uint16_t ch = pgkey;
                    if (kbd_mods & (PGMOD_LSHIFT | PGMOD_RSHIFT))
                        ch = shift_us(ch);
                    send_char(filter, ch, kbd_mods);
                }
                /* Special characters that picogui treats as CHAR rather
                 * than KEYDOWN for text widgets: backspace, return, tab,
                 * delete.  Send both so newline + backspace work in
                 * textedit and pterm. */
                if (down) {
                    switch (pgkey) {
                    case PGKEY_BACKSPACE:
                    case PGKEY_RETURN:
                    case PGKEY_TAB:
                    case PGKEY_DELETE:
                    case PGKEY_ESCAPE:
                        send_char(filter, pgkey, kbd_mods);
                        break;
                    }
                }
            }
        }
    }
    sys_exit(0);
}
