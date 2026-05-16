/*
 * Tiny no-libc init for the BE-300 CF recovery Linux prototype.
 *
 * The normal BusyBox/musl rootfs is useful later, but it can exercise MIPS
 * instructions the VR4131 does not implement. This binary uses only raw o32
 * syscalls and is compiled for MIPS II so the first CF boot can prove that
 * the kernel reached PID 1 without depending on the rootfs toolchain.
 */

#define __NR_LINUX	4000
#define __NR_EXIT	(__NR_LINUX + 1)
#define __NR_READ	(__NR_LINUX + 3)
#define __NR_WRITE	(__NR_LINUX + 4)
#define __NR_OPEN	(__NR_LINUX + 5)
#define __NR_CLOSE	(__NR_LINUX + 6)
#define __NR_MOUNT	(__NR_LINUX + 21)
#define __NR_PAUSE	(__NR_LINUX + 29)
#define __NR_DUP2	(__NR_LINUX + 63)

#define O_RDONLY	0
#define O_WRONLY	1
#define O_RDWR		2

#define SYSCALL_ATTR	__attribute__((noipa))

static long kmsg_fd = -1;

static long SYSCALL_ATTR syscall0(long nr)
{
	register long v0 asm("$2") = nr;
	register long a3 asm("$7");

	asm volatile("syscall"
		     : "+r"(v0), "=r"(a3)
		     :
		     : "memory");
	return a3 ? -v0 : v0;
}

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

static void kmsg_open(void)
{
	if (kmsg_fd >= 0)
		return;
	kmsg_fd = syscall3(__NR_OPEN, (long)"/dev/kmsg", O_WRONLY, 0);
}

static void kmsg_marker(const char *s)
{
	static const char prefix[] = "<6>be300-cf-init: ";
	char buf[160];
	unsigned int pos = 0;
	unsigned int i;

	kmsg_open();
	if (kmsg_fd < 0)
		return;

	for (i = 0; prefix[i] && pos < sizeof(buf) - 1; i++)
		buf[pos++] = prefix[i];
	for (i = 0; s[i] && pos < sizeof(buf) - 1; i++)
		buf[pos++] = s[i];
	buf[pos++] = '\n';
	write_all(kmsg_fd, buf, pos);
}

static void mount_one(const char *type, const char *target)
{
	(void)syscall5(__NR_MOUNT, (long)type, (long)target, (long)type, 0,
		       (long)"");
}

static void dump_file(const char *label, const char *path)
{
	char buf[256];
	long fd;

	write_str(1, label);
	fd = syscall3(__NR_OPEN, (long)path, O_RDONLY, 0);
	if (fd < 0) {
		write_str(1, "(unavailable)\n");
		return;
	}

	while (1) {
		long got = syscall3(__NR_READ, fd, (long)buf, sizeof(buf));

		if (got <= 0)
			break;
		write_all(1, buf, got);
	}
	(void)syscall1(__NR_CLOSE, fd);
	write_str(1, "\n");
}

void _start(void)
{
	long console;

	console = syscall3(__NR_OPEN, (long)"/dev/console", O_RDWR, 0);
	if (console >= 0) {
		(void)syscall3(__NR_DUP2, console, 0, 0);
		(void)syscall3(__NR_DUP2, console, 1, 0);
		(void)syscall3(__NR_DUP2, console, 2, 0);
		if (console > 2)
			(void)syscall1(__NR_CLOSE, console);
	}

	kmsg_marker("entered PID 1 from CF recovery image");
	write_str(1, "\n=== Casio BE-300 CF Linux init ===\n");
	write_str(1, "boot source: recovery CF, NAND untouched\n");

	mount_one("proc", "/proc");
	mount_one("sysfs", "/sys");
	mount_one("devtmpfs", "/dev");
	mount_one("tmpfs", "/tmp");
	kmsg_marker("mounted proc/sysfs/devtmpfs/tmpfs");

	dump_file("cmdline: ", "/proc/cmdline");
	dump_file("partitions:\n", "/proc/partitions");
	write_str(1, "CF bootstrap init is alive; idling.\n");
	kmsg_marker("alive and idling");

	while (1)
		(void)syscall0(__NR_PAUSE);

	(void)syscall1(__NR_EXIT, 0);
}
