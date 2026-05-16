/*
 * test_dyn_trap.c — same as test_dyn_hello (full uClibc-ng crt, the
 * configuration that SIGTRAPs at exit), but installs SA_SIGINFO
 * handlers for SIGTRAP/SIGILL/SIGSEGV/SIGFPE so we capture the EXACT
 * faulting PC inside the uClibc-ng exit() cleanup path.
 *
 * The handler hexdumps the kernel sigcontext (3rd handler arg) so the
 * EPC is recoverable regardless of mcontext_t struct drift, prints
 * si_addr, then raw _exit(0) (NOT return — returning re-runs the
 * trapping insn -> loop). Build with /work/mipsel-uclibc-gcc.
 */

#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <signal.h>
#include <fcntl.h>

/* Dump to /dev/ttyS0 so the full multi-line ucontext is captured by the
 * host --serial1-bridge PTY (fbcon would scroll it away). */
static int tfd = 2;

static void wstr(const char *s)
{
	write(tfd, s, strlen(s));
}

static void whex(unsigned long v)
{
	char b[11];
	int i;
	b[0] = '0'; b[1] = 'x';
	for (i = 7; i >= 0; i--) {
		int n = (v >> (i * 4)) & 0xf;
		b[9 - i] = n < 10 ? '0' + n : 'a' + n - 10;
	}
	b[10] = '\n';
	write(tfd, b, 11);
}

static volatile int in_handler;

static void handler(int sig, siginfo_t *si, void *uctx)
{
	unsigned long *p = (unsigned long *)uctx;
	int i;

	if (in_handler) {            /* re-entrancy guard */
		_exit(0);
	}
	in_handler = 1;

	wstr("TRAPSIG sig=");
	whex((unsigned long)sig);
	wstr("TRAPSIG si_addr=");
	whex((unsigned long)(si ? si->si_addr : 0));
	/* Dump first 48 words of the ucontext; on MIPS the kernel
	 * sigcontext (sc_pc + 32 gregs) lives a small fixed offset in.
	 * The EPC is the word that points into the uClibc text range. */
	wstr("UCTX:\n");
	for (i = 0; i < 48; i++)
		whex(p ? p[i] : 0);
	_exit(0);                    /* clean exit so rc=0 + we get the dump */
}

static unsigned int magic = 0xBE300C0D;

int main(int argc, char **argv)
{
	struct sigaction sa;
	int fd;

	fd = open("/dev/ttyS0", O_WRONLY);
	if (fd >= 0)
		tfd = fd;

	memset(&sa, 0, sizeof(sa));
	sa.sa_sigaction = handler;
	sa.sa_flags = SA_SIGINFO;
	sigemptyset(&sa.sa_mask);
	sigaction(SIGTRAP, &sa, 0);
	sigaction(SIGILL,  &sa, 0);
	sigaction(SIGSEGV, &sa, 0);
	sigaction(SIGFPE,  &sa, 0);
	sigaction(SIGBUS,  &sa, 0);

	wstr("[trap] main; magic ");
	whex(magic);
	fprintf(stderr, "[trap] fprintf works argc=%d\n", argc);
	fflush(stderr);
	wstr("[trap] returning -> exit() cleanup (expect trap here)\n");
	return 0;   /* -> __libc_start_main -> exit() -> cleanup -> TRAP */
}
