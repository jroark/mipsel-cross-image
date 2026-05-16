/*
 * test_dyn_noexit.c — dynamic-linked (uClibc-ng) like busybox, but with
 * a custom _start that calls main() then issues a RAW _exit syscall,
 * bypassing the entire gcc/uClibc finalization path (atexit,
 * __cxa_finalize, _fini / .fini_array, crtend __do_global_dtors_aux,
 * stdio cleanup).
 *
 * The dynamic loader (ld-uClibc.so.0) and all load-time relocations
 * still run normally. libc functions (write, fprintf/vfprintf) are
 * exercised in main().
 *
 * Discriminator vs test_dyn_hello (which SIGTRAPs at exit, rc=133):
 *   - this exits clean (rc=0)  -> bug is in the crt/atexit/_fini path
 *                                 (hard-float gcc crtend on no-FPU VR4131,
 *                                  or a mis-relocated destructor pointer)
 *   - this still SIGTRAPs      -> bug is in the loader / pre-main libc init
 *
 * Build: /work/mipsel-uclibc-gcc plus -nostartfiles, and DO NOT let the
 * wrapper add crt1/crtbegin/crtend (we pass -nostartfiles; the wrapper
 * still lists them, so this file also defines _start and never returns).
 */

#include <unistd.h>
#include <stdio.h>
#include <string.h>

int real_main(void)
{
	/* Only write() — a thin libc syscall wrapper needing no global
	 * libc init (we have no crt1/__libc_start_main here). The point is
	 * purely: dynamic-loaded + skip crt fini -> clean exit? */
	const char *m = "[noexit] dynamic main via libc write() OK\n";
	write(2, m, strlen(m));
	write(2, "[noexit] raw _exit(0), crt fini skipped\n", 40);
	return 0;
}

/* Raw _exit via o32 syscall — no libc, no atexit, no _fini. */
static void raw_exit(int code)
{
	register long v0 asm("$2") = 4001; /* __NR_exit */
	register long a0 asm("$4") = code;
	asm volatile("syscall" : "+r"(v0), "+r"(a0) : : "memory");
	for (;;)
		;
}

/* Custom entry: no crt1, no __libc_start_main, no _fini. We still need
 * the dynamic loader to have relocated us + libc (it runs before _start
 * via the PT_INTERP / DT_INIT path of ld-uClibc itself). */
void _start(void)
{
	int rc = real_main();
	raw_exit(rc);
}
