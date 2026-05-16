/*
 * be300_hw_test.c — BE-300 2.4.18 userspace HW smoke test.
 *
 * Compiled with -nostdlib -fno-pic -mno-abicalls -march=mips2 so it
 * runs without any libc startup. Modern musl's __start_c walks AUX
 * vectors (AT_RANDOM, AT_SYSINFO_EHDR, …) that 2.4.18 doesn't supply,
 * which SIGSEGV's the process before main() — bare syscalls dodge it.
 *
 * The binary does the one HW test that really needs an ELF: mmap
 * /dev/fb0 and paint a 6-band RGB565 pattern across the bottom 16 LCD
 * rows. The rest of the HW checks (mtd, input, tpanel, time) are
 * shell commands in /etc/init.d/rcS via BusyBox applets.
 */

/* o32 syscall numbers, from linux-2.4.18/include/asm-mips/unistd.h. */
#define __NR_Linux  4000
#define __NR_write  (__NR_Linux + 4)
#define __NR_open   (__NR_Linux + 5)
#define __NR_close  (__NR_Linux + 6)
#define __NR_exit   (__NR_Linux + 1)
#define __NR_mmap   (__NR_Linux + 90)
#define __NR_munmap (__NR_Linux + 91)

#define O_RDWR      2

/* mmap2-style arg packing; o32 sys_mmap takes a struct in 2.4 kernel. */

static long _syscall6(long n, long a0, long a1, long a2,
		       long a3, long a4, long a5)
{
	register long r_v0 asm("v0") = n;
	register long r_a0 asm("a0") = a0;
	register long r_a1 asm("a1") = a1;
	register long r_a2 asm("a2") = a2;
	register long r_a3 asm("a3") = a3;
	/* a4/a5 go on the stack on o32. */
	register long r_a4 asm("t0") = a4;
	register long r_a5 asm("t1") = a5;
	long r;
	/* Operand numbering: %0..%1 are outputs (r, r_v0), inputs start at %2.
	 * So r_a0=%2, r_a1=%3, r_a2=%4, r_a3=%5, r_a4=%6, r_a5=%7.
	 * Stack slots for o32 syscall(6) are 16(sp)=arg5, 20(sp)=arg6. */
	asm volatile (
		"addiu $sp, $sp, -32\n\t"
		"sw %6, 16($sp)\n\t"
		"sw %7, 20($sp)\n\t"
		"syscall\n\t"
		"addiu $sp, $sp, 32\n\t"
		"move %0, $2"
		: "=r" (r), "+r" (r_v0)
		: "r" (r_a0), "r" (r_a1), "r" (r_a2), "r" (r_a3),
		  "r" (r_a4), "r" (r_a5)
		: "memory");
	return r;
}

static long _syscall3(long n, long a0, long a1, long a2)
{
	register long r_v0 asm("v0") = n;
	register long r_a0 asm("a0") = a0;
	register long r_a1 asm("a1") = a1;
	register long r_a2 asm("a2") = a2;
	long r;
	asm volatile ("syscall\n\tmove %0,$2"
		      : "=r" (r), "+r" (r_v0)
		      : "r" (r_a0), "r" (r_a1), "r" (r_a2)
		      : "memory");
	return r;
}

static long _syscall1(long n, long a0)
{
	register long r_v0 asm("v0") = n;
	register long r_a0 asm("a0") = a0;
	long r;
	asm volatile ("syscall\n\tmove %0,$2"
		      : "=r" (r), "+r" (r_v0)
		      : "r" (r_a0)
		      : "memory");
	return r;
}

static int _strlen(const char *s) {
	int n = 0;
	while (s[n]) n++;
	return n;
}

static void _puts(const char *s) {
	_syscall3(__NR_write, 1, (long)s, _strlen(s));
}

/* RGB565 helper. */
static unsigned short rgb565(int r, int g, int b) {
	return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3);
}

void _start(void) {
	_puts("be300_hw_test: opening /dev/fb0\n");

	int fd = _syscall3(__NR_open, (long)"/dev/fb0", O_RDWR, 0);
	if (fd < 0) {
		_puts("be300_hw_test: open /dev/fb0 failed\n");
		_syscall1(__NR_exit, 1);
	}

	/* 240x320 16bpp = 0x25800 = 150 KB. */
	const unsigned long len = 240 * 320 * 2;
	/* o32 sys_mmap(addr, len, prot, flags, fd, offset). prot=R|W (3),
	 * flags=MAP_SHARED (1). */
	long addr = _syscall6(__NR_mmap, 0, len, 3, 1, fd, 0);
	if (addr < 0 || addr == -1) {
		_puts("be300_hw_test: mmap fb0 failed\n");
		_syscall1(__NR_exit, 2);
	}

	unsigned short *fb = (unsigned short *)addr;
	unsigned short band[6] = {
		rgb565(255,0,0), rgb565(0,255,0), rgb565(0,0,255),
		rgb565(255,255,255), rgb565(255,255,0), rgb565(255,0,255)
	};
	int bandw = 240 / 6;
	for (int y = 320 - 16; y < 320; y++) {
		for (int x = 0; x < 240; x++) {
			int b = x / bandw;
			if (b > 5) b = 5;
			fb[y * 240 + x] = band[b];
		}
	}

	_puts("be300_hw_test: painted 6-band fb pattern at bottom 16 rows\n");

	_syscall3(__NR_munmap, addr, len, 0);
	_syscall1(__NR_close, fd);
	_syscall1(__NR_exit, 0);

	/* not reached */
	while (1) {}
}
