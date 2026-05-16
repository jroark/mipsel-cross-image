/*
 * test_forkexec.c — bare-syscall fork/exec diagnostic for the 2.4.18
 * BE-300 "every exec'd command SIGTRAPs" bug.
 *
 * Isolates which stage of process creation corrupts:
 *   1. First exec + .data integrity   — this binary's own magic word.
 *   2. fork() COW (no exec)           — child writes a marker, _exit(42).
 *   3. fork()+execve() (the failing path) — child execs /sbin/te_child.
 *
 * Pure o32 syscalls, -nostdlib, no libc, no dynamic loader (modeled on
 * board/casio-be300/test_mount_proc.c). 2.4.18 has no /dev/kmsg, so
 * output goes to /dev/ttyS0 (VRC4173 dock UART) — capture it on the
 * host with `--serial1-bridge pty:auto`. The parent loops forever after
 * the report so rcS never returns (Opie won't start — irrelevant for
 * the diagnostic) and we never exercise a tty close path.
 *
 * Build (same flags as test_mount_proc so the e_flags rewriter fixes the
 * mips32r2 metadata to mips2):
 *   mipsel-linux-gnu-gcc -march=mips2 -static -nostdlib -nostdinc \
 *       -fno-pic -mno-abicalls -fomit-frame-pointer -Os -Wall \
 *       -Wl,--entry=_start -o test_forkexec test_forkexec.c
 */

#define __NR_LINUX	4000
#define __NR_EXIT	(__NR_LINUX + 1)
#define __NR_FORK	(__NR_LINUX + 2)
#define __NR_WRITE	(__NR_LINUX + 4)
#define __NR_OPEN	(__NR_LINUX + 5)
#define __NR_CLOSE	(__NR_LINUX + 6)
#define __NR_WAITPID	(__NR_LINUX + 7)
#define __NR_EXECVE	(__NR_LINUX + 11)
#define __NR_GETPID	(__NR_LINUX + 20)
#define __NR_DUP2	(__NR_LINUX + 63)

#define O_WRONLY	1

#define SYSCALL_ATTR	__attribute__((noipa))

static long SYSCALL_ATTR syscall0(long nr)
{
	register long v0 asm("$2") = nr;
	register long a3 asm("$7");

	asm volatile("syscall" : "+r"(v0), "=r"(a3) : : "memory",
		     "$1", "$3", "$8", "$9", "$10", "$11", "$12", "$13",
		     "$14", "$15", "$24", "$25");
	return a3 ? -v0 : v0;
}

static long SYSCALL_ATTR syscall1(long nr, long a)
{
	register long v0 asm("$2") = nr;
	register long a0 asm("$4") = a;
	register long a3 asm("$7");

	asm volatile("syscall" : "+r"(v0), "+r"(a0), "=r"(a3) : : "memory");
	return a3 ? -v0 : v0;
}

static long SYSCALL_ATTR syscall3(long nr, long a, long b, long c)
{
	register long v0 asm("$2") = nr;
	register long a0 asm("$4") = a;
	register long a1 asm("$5") = b;
	register long a2 asm("$6") = c;
	register long a3 asm("$7");

	asm volatile("syscall"
		     : "+r"(v0), "+r"(a0), "+r"(a1), "+r"(a2), "=r"(a3)
		     : : "memory");
	return a3 ? -v0 : v0;
}

static unsigned int slen(const char *s)
{
	unsigned int n = 0;
	while (s[n]) n++;
	return n;
}

static void wr(const char *s)
{
	unsigned int len = slen(s);
	const char *p = s;
	while (len) {
		long n = syscall3(__NR_WRITE, 1, (long)p, len);
		if (n <= 0) return;
		p += n; len -= (unsigned int)n;
	}
}

static void wrhex(unsigned int v)
{
	char b[11];
	int i;
	b[0] = '0'; b[1] = 'x';
	for (i = 7; i >= 0; i--) {
		int nib = (v >> (i * 4)) & 0xf;
		b[9 - i] = (char)(nib < 10 ? '0' + nib : 'a' + nib - 10);
	}
	b[10] = '\n';
	(void)syscall3(__NR_WRITE, 1, (long)b, 11);
}

static void wrdec(long v)
{
	char b[24];
	unsigned int pos = sizeof(b);
	unsigned long u;
	if (v < 0) { wr("-"); u = (unsigned long)(-(v + 1)) + 1UL; }
	else u = (unsigned long)v;
	if (u == 0) b[--pos] = '0';
	else while (u) { b[--pos] = (char)('0' + (u % 10)); u /= 10; }
	(void)syscall3(__NR_WRITE, 1, (long)(b + pos), sizeof(b) - pos);
}

/* .data magic — tests data-page integrity after exec/COW. */
static unsigned int magic = 0xBE300C0D;

/* execve target + a minimal argv/envp (NULL-terminated). */
static char ch_path[] = "/sbin/te_child";
static char *ch_argv[] = { ch_path, 0 };
static char *ch_envp[] = { 0 };

void _start(void)
{
	long pid, st, rc;

	/* Write to inherited fd 1 (= /dev/console = tty0/fbcon when run
	 * from rcS — the only userspace output proven to work on 2.4). Do
	 * NOT reopen anything. */
	wr("FE: test_forkexec start\n");

	/* Stage 1: first-exec .data integrity (this binary). */
	if (magic == 0xBE300C0DU) {
		wr("<6>FE: stage1 DATA OK (own .data intact)\n");
	} else {
		wr("<6>FE: stage1 DATA BAD magic=");
		wrhex(magic);
	}

	/* Stage 2: fork() COW, no exec. */
	wr("<6>FE: stage2 fork()...\n");
	pid = syscall0(__NR_FORK);
	if (pid == 0) {
		/* child: prove COW data page is intact, then exit 42 */
		if (magic == 0xBE300C0DU)
			wr("<6>FE: stage2 CHILD data OK\n");
		else {
			wr("<6>FE: stage2 CHILD data BAD magic=");
			wrhex(magic);
		}
		(void)syscall1(__NR_EXIT, 42);
		while (1) ;
	}
	if (pid < 0) {
		wr("<6>FE: stage2 fork FAILED rc="); wrdec(pid); wr("\n");
	} else {
		st = 0;
		rc = syscall3(__NR_WAITPID, pid, (long)&st, 0);
		wr("<6>FE: stage2 waitpid rc="); wrdec(rc);
		wr(" status="); wrhex((unsigned int)st);
		wr("    (sig="); wrdec(st & 0x7f);
		wr(" exit="); wrdec((st >> 8) & 0xff); wr(")\n");
	}

	/* Stage 3: fork()+execve() — the path that SIGTRAPs in busybox. */
	wr("<6>FE: stage3 fork()+execve(/sbin/te_child)...\n");
	pid = syscall0(__NR_FORK);
	if (pid == 0) {
		rc = syscall3(__NR_EXECVE, (long)ch_path,
			      (long)ch_argv, (long)ch_envp);
		/* only reached if execve fails */
		wr("<6>FE: stage3 CHILD execve FAILED rc="); wrdec(rc); wr("\n");
		(void)syscall1(__NR_EXIT, 99);
		while (1) ;
	}
	if (pid < 0) {
		wr("<6>FE: stage3 fork FAILED rc="); wrdec(pid); wr("\n");
	} else {
		st = 0;
		rc = syscall3(__NR_WAITPID, pid, (long)&st, 0);
		wr("<6>FE: stage3 waitpid rc="); wrdec(rc);
		wr(" status="); wrhex((unsigned int)st);
		wr("    (sig="); wrdec(st & 0x7f);
		wr(" exit="); wrdec((st >> 8) & 0xff); wr(")\n");
	}

	wr("FE: test_forkexec DONE rc0\n");
	(void)syscall1(__NR_EXIT, 0);
	while (1) ;
}
