/* Bare TCP loopback self-test — minimal.
 * Tests socket()/bind()/listen()/connect() on 127.0.0.1.
 * Exit codes encode the failure stage. */

#define NULL ((void *)0)

#define __NR_Linux 4000
#define __NR_socketcall (__NR_Linux + 102)
#define __NR_exit       (__NR_Linux + 1)
#define __NR_write      (__NR_Linux + 4)
#define __NR_fork       (__NR_Linux + 2)
#define __NR_nanosleep  (__NR_Linux + 166)
#define __NR_wait4      (__NR_Linux + 114)
struct timespec_ { long tv_sec; long tv_nsec; };
static long syscall2(long nr, long a0, long a1);
static long syscall3(long nr, long a0, long a1, long a2);
static void do_sleep(long sec) {
    struct timespec_ ts = { sec, 0 };
    syscall2(__NR_nanosleep, (long)&ts, 0);
}
static long do_waitpid(long pid) {
    long status = 0;
    return syscall3(__NR_wait4, pid, (long)&status, 0);
}

#define SYS_SOCKET    1
#define SYS_BIND      2
#define SYS_CONNECT   3
#define SYS_LISTEN    4
#define SYS_ACCEPT    5

#define AF_INET       2
/* MIPS Linux: SOCK_DGRAM=1, SOCK_STREAM=2 (reversed from x86/generic). */
#define SOCK_STREAM   2
#define SOCK_DGRAM    1

struct sockaddr_in {
    unsigned short sin_family;
    unsigned short sin_port;
    unsigned int   sin_addr;
    unsigned char  sin_zero[8];
};

/* o32 MIPS syscall: nr in $v0, args in $a0..$a3, returns ($v0, $a3).
 * $a3 != 0 means error; $v0 is -errno when $a3 set, otherwise result. */
static long syscall2(long nr, long a0, long a1) {
    register long _nr __asm__("$2") = nr;
    register long _a0 __asm__("$4") = a0;
    register long _a1 __asm__("$5") = a1;
    register long _err __asm__("$7");
    register long _ret __asm__("$2");
    __asm__ __volatile__("syscall"
        : "=r"(_ret), "=r"(_err)
        : "r"(_nr), "r"(_a0), "r"(_a1)
        : "$1","$3","$8","$9","$10","$11","$12","$13","$14","$15","$24","$25","memory");
    return _err ? -_ret : _ret;
}

static long syscall3(long nr, long a0, long a1, long a2) {
    register long _nr __asm__("$2") = nr;
    register long _a0 __asm__("$4") = a0;
    register long _a1 __asm__("$5") = a1;
    register long _a2 __asm__("$6") = a2;
    register long _err __asm__("$7");
    register long _ret __asm__("$2");
    __asm__ __volatile__("syscall"
        : "=r"(_ret), "=r"(_err)
        : "r"(_nr), "r"(_a0), "r"(_a1), "r"(_a2)
        : "$1","$3","$8","$9","$10","$11","$12","$13","$14","$15","$24","$25","memory");
    return _err ? -_ret : _ret;
}

static long syscall0(long nr) {
    register long _nr __asm__("$2") = nr;
    register long _err __asm__("$7");
    register long _ret __asm__("$2");
    __asm__ __volatile__("syscall"
        : "=r"(_ret), "=r"(_err)
        : "r"(_nr)
        : "$1","$3","$4","$5","$6","$8","$9","$10","$11","$12","$13","$14","$15","$24","$25","memory");
    return _err ? -_ret : _ret;
}

static void do_write(long fd, const char *s, long n) {
    syscall3(__NR_write, fd, (long)s, n);
}
static void do_exit(long n) {
    syscall2(__NR_exit, n, 0);
    while (1) {}
}

static long sock_call(long op, long a, long b, long c) {
    long args[3] = { a, b, c };
    return syscall2(__NR_socketcall, op, (long)args);
}

#define MSG(s) do_write(1, s, sizeof(s)-1)

/* Render a small signed integer as up to 6 ASCII chars. */
static void msg_long(long n) {
    char buf[12];
    int i = 11;
    int neg = 0;
    unsigned long u;
    if (n < 0) { neg = 1; u = -n; } else { u = n; }
    buf[i] = 0;
    if (u == 0) { i--; buf[i] = '0'; }
    while (u) { i--; buf[i] = '0' + (u % 10); u /= 10; }
    if (neg) { i--; buf[i] = '-'; }
    do_write(1, buf + i, 11 - i);
}

int _start(void) {
    MSG("[tcp] start\n");

    long s = sock_call(SYS_SOCKET, AF_INET, SOCK_STREAM, 0);
    MSG("[tcp] socket returned\n");
    if (s < 0) { MSG("[tcp] socket FAIL\n"); do_exit(10); }
    MSG("[tcp] socket OK\n");

    struct sockaddr_in sa;
    sa.sin_family = AF_INET;
    sa.sin_port = (12345 & 0xff) << 8 | (12345 >> 8);
    sa.sin_addr = 0x0100007f;  /* 127.0.0.1 in network byte order */
    sa.sin_zero[0]=sa.sin_zero[1]=sa.sin_zero[2]=sa.sin_zero[3]=0;
    sa.sin_zero[4]=sa.sin_zero[5]=sa.sin_zero[6]=sa.sin_zero[7]=0;

    long r = sock_call(SYS_BIND, s, (long)&sa, sizeof(sa));
    if (r < 0) { MSG("[tcp] bind FAIL errno="); msg_long(-r); MSG("\n"); do_exit(20); }
    MSG("[tcp] bind OK\n");

    r = sock_call(SYS_LISTEN, s, 5, 0);
    if (r < 0) { MSG("[tcp] listen FAIL errno="); msg_long(-r); MSG("\n"); do_exit(30); }
    if (r > 0) { MSG("[tcp] listen NONZERO r="); msg_long(r); MSG("\n"); do_exit(31); }
    MSG("[tcp] listen OK\n");

    long pid = syscall0(__NR_fork);
    if (pid < 0) { MSG("[tcp] fork FAIL\n"); do_exit(40); }

    if (pid == 0) {
        do_sleep(1);  /* give parent a moment to settle */
        MSG("[tcp child] connecting\n");
        long cs = sock_call(SYS_SOCKET, AF_INET, SOCK_STREAM, 0);
        if (cs < 0) { MSG("[tcp child] socket FAIL\n"); do_exit(50); }
        long cr = sock_call(SYS_CONNECT, cs, (long)&sa, sizeof(sa));
        if (cr < 0) { MSG("[tcp child] connect FAIL errno="); msg_long(-cr); MSG("\n"); do_exit(60); }
        MSG("[tcp child] connect OK\n");
        do_exit(0);
    } else {
        /* parent: do NOT block in accept().  Kernel completes the 3-way
         * handshake from listen queue without us; child will see ESTABLISHED.
         * Just wait for child and exit so rcS gets control back for
         * /proc dumps. */
        MSG("[tcp parent] waiting for child\n");
        do_waitpid(pid);
        MSG("[tcp parent] child done\n");
        do_exit(0);
    }
    return 0;
}
