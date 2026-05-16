/*
 * test_forkexec_child.c — the execve() target for test_forkexec.c.
 *
 * If this prints "TE_CHILD ran" with its .data magic intact and exits 7,
 * then fork()+execve() works. If the parent's waitpid instead reports
 * sig=5 (SIGTRAP) / sig=11 (SIGSEGV) / sig=4 (SIGILL) and this message
 * never appears, the exec-after-fork page path is corrupting the new
 * image — the 2.4 analog of the 4.2.9 fork/exec bug.
 *
 * Build: same flags as test_forkexec.c / test_mount_proc.c.
 */

#define __NR_LINUX	4000
#define __NR_EXIT	(__NR_LINUX + 1)
#define __NR_WRITE	(__NR_LINUX + 4)
#define __NR_OPEN	(__NR_LINUX + 5)
#define __NR_CLOSE	(__NR_LINUX + 6)
#define __NR_DUP2	(__NR_LINUX + 63)

#define O_WRONLY	1

#define SYSCALL_ATTR	__attribute__((noipa))

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

static unsigned int magic = 0xCABA1107;

void _start(void)
{
	/* fd 1 is inherited (fork+execve preserve fds) = rcS's fbcon. */
	if (magic == 0xCABA1107U)
		wr("<6>FE: TE_CHILD ran, .data OK -> exec-after-fork WORKS\n");
	else
		wr("<6>FE: TE_CHILD ran but .data BAD (exec page corrupt)\n");

	(void)syscall1(__NR_EXIT, 7);
	while (1) ;
}
