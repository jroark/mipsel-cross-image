/*
 * test_mount_proc.c — bare-syscall reproducer for the 2.4.18
 * `mount -t proc proc /proc` boot stall on the BE-300 emulator.
 *
 * BusyBox's mount applet hangs indefinitely during rcS on 2.4.18 +
 * JFFS2 root + Opie.  The stall PCs all fall inside cpu_idle, which
 * means the user task blocked on a wait that never fires — not a
 * userspace bug per se, but we want to be SURE it isn't BusyBox doing
 * something subtle (mtab? fstab? helper exec?) before we instrument
 * the kernel.  This binary issues a raw mount(2) syscall via o32
 * conventions, with no libc, no shared object, no AUX-vector walk,
 * and no helper processes.  If the kernel mount path is at fault the
 * "after mount" line will not appear in the boot log either; if the
 * kernel returns we will see "rc=0" or "rc=-N" for some errno N.
 *
 * Modeled after board/casio-be300/cf_init.c.  Compiled with the same
 * flags (-march=mips2 -static -nostdlib -nostdinc -fno-pic
 * -mno-abicalls -Wl,--entry=_start) so the e_flags rewriter in
 * build_be300_2_4_kernel.sh can fix the mips32r2 metadata to mips2.
 */

#define __NR_LINUX	4000
#define __NR_EXIT	(__NR_LINUX + 1)
#define __NR_WRITE	(__NR_LINUX + 4)
#define __NR_OPEN	(__NR_LINUX + 5)
#define __NR_CLOSE	(__NR_LINUX + 6)
#define __NR_MOUNT	(__NR_LINUX + 21)
#define __NR_DUP2	(__NR_LINUX + 63)

#define O_RDONLY	0
#define O_WRONLY	1
#define O_RDWR		2

#define SYSCALL_ATTR	__attribute__((noipa))

static long SYSCALL_ATTR syscall1(long nr, long arg0)
{
	register long v0 asm("$2") = nr;
	register long a0 asm("$4") = arg0;
	register long a3 asm("$7");

	asm volatile("syscall"
		     : "+r"(v0), "+r"(a0), "=r"(a3)
		     :
		     : "memory");
	return a3 ? -v0 : v0;
}

static long SYSCALL_ATTR syscall3(long nr, long arg0, long arg1, long arg2)
{
	register long v0 asm("$2") = nr;
	register long a0 asm("$4") = arg0;
	register long a1 asm("$5") = arg1;
	register long a2 asm("$6") = arg2;
	register long a3 asm("$7");

	asm volatile("syscall"
		     : "+r"(v0), "+r"(a0), "+r"(a1), "+r"(a2), "=r"(a3)
		     :
		     : "memory");
	return a3 ? -v0 : v0;
}

static long SYSCALL_ATTR syscall5(long nr, long arg0, long arg1, long arg2,
			      long arg3, long arg4)
{
	register long v0 asm("$2") = nr;
	register long a0 asm("$4") = arg0;
	register long a1 asm("$5") = arg1;
	register long a2 asm("$6") = arg2;
	register long a3 asm("$7") = arg3;

	asm volatile(
		"subu $sp, $sp, 32\n\t"
		"sw %5, 16($sp)\n\t"
		"syscall\n\t"
		"addu $sp, $sp, 32"
		: "+r"(v0), "+r"(a0), "+r"(a1), "+r"(a2), "+r"(a3)
		: "r"(arg4)
		: "memory");
	return a3 ? -v0 : v0;
}

static unsigned int strlen_c(const char *s)
{
	unsigned int len = 0;

	while (s[len])
		len++;
	return len;
}

static void write_all(int fd, const char *buf, unsigned int len)
{
	while (len) {
		long done = syscall3(__NR_WRITE, fd, (long)buf, len);

		if (done <= 0)
			return;
		buf += done;
		len -= done;
	}
}

static void write_str(int fd, const char *s)
{
	write_all(fd, s, strlen_c(s));
}

/* Print a signed decimal integer to fd.  Range covers the full long
 * (mount syscall returns -errno on error, which is small in practice
 * but we don't want surprises). */
static void write_dec(int fd, long v)
{
	char buf[24];
	unsigned int pos = sizeof(buf);
	unsigned long u;

	if (v < 0) {
		write_all(fd, "-", 1);
		u = (unsigned long)(-(v + 1)) + 1UL;  /* avoids LONG_MIN UB */
	} else {
		u = (unsigned long)v;
	}

	if (u == 0) {
		buf[--pos] = '0';
	} else {
		while (u) {
			buf[--pos] = (char)('0' + (u % 10));
			u /= 10;
		}
	}
	write_all(fd, buf + pos, sizeof(buf) - pos);
}

void _start(void)
{
	long kmsg;
	long rc;

	/* /dev/console output is broken on this 2.4 build (tty0/fbcon is
	 * silent, ttyS0 tty path hangs).  /dev/kmsg (char 1,11) routes
	 * userspace writes through printk -> every registered console
	 * via the poll-write path, which is proven working (every kernel
	 * printk in the boot log reaches the emulator via that path).
	 * Open it explicitly and force fd 1/2 onto it; ignore any pre-
	 * existing redirects from rcS so this binary is also usable when
	 * launched directly from a serial shell. */
	kmsg = syscall3(__NR_OPEN, (long)"/dev/kmsg", O_WRONLY, 0);
	if (kmsg >= 0) {
		(void)syscall3(__NR_DUP2, kmsg, 1, 0);
		(void)syscall3(__NR_DUP2, kmsg, 2, 0);
		if (kmsg > 2)
			(void)syscall1(__NR_CLOSE, kmsg);
	}

	/* "<6>" is the printk KERN_INFO prefix; without it the kernel
	 * tags the message KERN_DEFAULT which on 2.4 ends up at level 4
	 * (KERN_WARNING) which is fine but less obviously informational.
	 * Newline at the end matters — printk buffers until \n. */
	write_str(1, "<6>test_mount_proc: before mount\n");
	write_str(2, "<6>test_mount_proc: before mount (stderr)\n");

	/* sys_mount(dev_name, dir_name, type, flags, data).
	 * Matches the BusyBox `mount -t proc proc /proc` invocation. */
	rc = syscall5(__NR_MOUNT,
		      (long)"proc",
		      (long)"/proc",
		      (long)"proc",
		      0L,
		      0L);

	/* If syscall5 never returns (kernel mount path hangs), the next
	 * line never appears in the log — that absence IS the diagnostic
	 * signal.  If syscall5 does return, print the result so we know
	 * whether it succeeded (rc=0) or failed fast (rc=-errno). */
	write_str(1, "<6>test_mount_proc: after mount, rc=");
	write_dec(1, rc);
	write_str(1, "\n");
	write_str(2, "<6>test_mount_proc: after mount (stderr)\n");

	(void)syscall1(__NR_EXIT, 0);
	while (1)
		;  /* unreachable */
}
