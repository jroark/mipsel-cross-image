/*
 * Minimal C /init for BE-300 — tests whether C programs work from initramfs.
 * Statically linked with musl, no GOT/PIC.
 *
 * Build:
 *   mipsel-linux-gnu-gcc -static -march=mips32 -mabi=32 \
 *       -specs /work/musl-mipsel/lib/musl-gcc.specs \
 *       -o init test_c_init.c
 */
#include <unistd.h>
#include <sys/mount.h>
#include <sys/stat.h>

static const char msg[] = "\n=== BE-300 Linux 4.2.9 (C init) ===\n"
                           "Hello from C with musl!\n";

/* Global data in .data section — tests that data pages are readable */
static int magic = 0xBE300C0D;

int main(void)
{
	char buf[64];
	int i;

	/* write banner */
	write(1, msg, sizeof(msg) - 1);

	/* Verify .data section is readable (not zeros) */
	if (magic == 0xBE300C0D) {
		write(1, "DATA OK\n", 8);
	} else {
		write(1, "DATA BAD (zeros?)\n", 18);
		/* Print the actual value as hex for diagnosis */
		buf[0] = '0';
		buf[1] = 'x';
		for (i = 7; i >= 0; i--) {
			int nib = (magic >> (i * 4)) & 0xf;
			buf[9 - i] = nib < 10 ? '0' + nib : 'a' + nib - 10;
		}
		buf[10] = '\n';
		write(1, buf, 11);
	}

	/* Mount standard filesystems */
	mkdir("/proc", 0755);
	mount("proc", "/proc", "proc", 0, NULL);
	mkdir("/sys", 0755);
	mount("sysfs", "/sys", "sysfs", 0, NULL);
	mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);

	write(1, "Mounts done. Looping.\n", 22);

	for (;;)
		pause();

	return 0;
}
