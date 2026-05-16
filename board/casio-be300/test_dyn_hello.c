/*
 * test_dyn_hello.c — minimal dynamic-link userspace test.
 *
 * Build against uClibc-ng with the standard libc startup, exactly
 * like qpe does.  If this prints its message on the LCD, the
 * dynamic-loader / libc startup path is fine and the qpe SIGSEGV
 * is Qt-specific.  If it crashes the same way as qpe (SIGSEGV at
 * libuClibc strnlen called via vfprintf), the issue is general to
 * dynamic-link binaries on 2.4.18 + BE-300.
 *
 * Comparable static-linked diagnostic /usr/bin/test_mount_proc
 * already proved static-link works on this build.
 */

#include <unistd.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv)
{
	const char *msg = "[test_dyn_hello] hello from dynamic main\n";
	write(2, msg, strlen(msg));
	fprintf(stderr, "[test_dyn_hello] fprintf works, argc=%d argv[0]=%s\n",
	        argc, argv[0] ? argv[0] : "(null)");
	fflush(stderr);
	return 0;
}
