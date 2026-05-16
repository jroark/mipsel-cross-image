/*
 * test_exitgroup.c — bare-syscall probe: does the 2.4.18 kernel handle
 * syscall 4246 (exit_group) after the syscalls.h/unistd.h backport?
 *
 * Writes to /dev/ttyS0 (captured by host --serial1-bridge), then issues
 * raw syscall(4246, 7). If the kernel terminates the process the
 * "RETURNED" line never appears (fix works). If exit_group still
 * ENOSYS-returns, we print rc and then clean-exit via __NR_exit (4001,
 * which definitely works) so the process still ends.
 */
#define __NR_LINUX 4000
#define __NR_EXIT  (__NR_LINUX + 1)
#define __NR_WRITE (__NR_LINUX + 4)
#define __NR_OPEN  (__NR_LINUX + 5)
#define __NR_EXITG (__NR_LINUX + 246)
#define O_WRONLY 1
#define SC __attribute__((noipa))

static long SC sc1(long n, long a)
{
	register long v0 asm("$2") = n, a0 asm("$4") = a, a3 asm("$7");
	asm volatile("syscall" : "+r"(v0), "+r"(a0), "=r"(a3) : : "memory");
	return a3 ? -v0 : v0;
}
static long SC sc3(long n, long a, long b, long c)
{
	register long v0 asm("$2") = n, a0 asm("$4") = a, a1 asm("$5") = b,
		       a2 asm("$6") = c, a3 asm("$7");
	asm volatile("syscall"
		     : "+r"(v0), "+r"(a0), "+r"(a1), "+r"(a2), "=r"(a3)
		     : : "memory");
	return a3 ? -v0 : v0;
}
static unsigned slen(const char *s){unsigned n=0;while(s[n])n++;return n;}
static void wr(const char *s){unsigned l=slen(s);const char*p=s;
	while(l){long n=sc3(__NR_WRITE,1,(long)p,l);if(n<=0)return;p+=n;l-=n;}}
static void wdec(long v){char b[16];unsigned p=16;unsigned long u;
	if(v<0){wr("-");u=(unsigned long)(-(v+1))+1;}else u=v;
	if(!u)b[--p]='0';else while(u){b[--p]='0'+u%10;u/=10;}
	sc3(__NR_WRITE,1,(long)(b+p),16-p);}

void _start(void)
{
	long f = sc3(__NR_OPEN, (long)"/dev/ttyS0", O_WRONLY, 0);
	if (f >= 0) { sc3(__NR_LINUX + 63, f, 1, 0); /* dup2 -> fd1 */ }

	wr("\nEXITG: calling syscall 4246 exit_group(7)\n");
	long rc = sc1(__NR_EXITG, 7);
	/* Only reached if exit_group did NOT terminate us. */
	wr("EXITG: RETURNED rc=");
	wdec(rc);
	wr(" (4246 still broken at runtime)\n");
	sc1(__NR_EXIT, 0);
	for (;;) ;
}
