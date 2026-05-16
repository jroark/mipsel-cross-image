/*
 * be300_linuxrc.c — minimal /linuxrc for the 2.4.18 BE-300 initrd-to-NAND
 * root pivot. The kernel runs `execve("/linuxrc", { "linuxrc", NULL }, ...)`
 * as process 1, waits for it to exit, then calls change_root() to switch
 * to the real_root_dev parsed from `root=` on the cmdline.
 *
 * The original initrd ships /linuxrc as a symlink to /bin/busybox, which
 * BusyBox 0.60.5 dispatches to its init applet — init never exits, so
 * the kernel hangs waiting. This binary prints a marker and exits(0)
 * via raw syscalls, letting the kernel proceed with change_root.
 *
 * Built with the same -nostdlib -fno-pic -mno-abicalls -march=mips2 +
 * post-link e_flags patch that be300_hw_test uses.
 */

#define MSG "be300_linuxrc: exiting; kernel should now change_root\n"

void _start(void) {
	/* write(1, MSG, sizeof(MSG)-1) */
	register int r_v0 asm("v0") = 4004;	/* __NR_write */
	register int r_a0 asm("a0") = 1;	/* fd = 1 */
	register const char *r_a1 asm("a1") = MSG;
	register int r_a2 asm("a2") = sizeof(MSG) - 1;
	asm volatile ("syscall"
		      : "+r" (r_v0)
		      : "r" (r_a0), "r" (r_a1), "r" (r_a2)
		      : "memory");

	/* exit(0) */
	register int r2_v0 asm("v0") = 4001;	/* __NR_exit */
	register int r2_a0 asm("a0") = 0;	/* exit code */
	asm volatile ("syscall"
		      : "+r" (r2_v0)
		      : "r" (r2_a0)
		      : "memory");
	while (1) {}
}
