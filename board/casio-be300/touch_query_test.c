/*
 * Phase B verification: query /dev/input/event1 capabilities to confirm
 * the BE-300 PIU touch driver registered with correct EV_ABS ranges and
 * BTN_TOUCH support.
 *
 * Build (against musl):
 *   mipsel-linux-gnu-gcc -march=mips2 -static -O2 \
 *     -specs /work/musl-mipsel/lib/musl-gcc.specs \
 *     -isystem /work/musl-khdrs/include \
 *     touch_query_test.c -o touch_query_test \
 *     -B/tmp/libgcc_patched
 */

#include <stdio.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <linux/input.h>

#define BIT_WORD(nr)	((nr) / (8 * sizeof(unsigned long)))
#define BIT_MASK(nr)	(1UL << ((nr) & (8 * sizeof(unsigned long) - 1)))
#define TEST_BIT(b, n)	(((b)[BIT_WORD(n)] >> ((n) & (8 * sizeof(unsigned long) - 1))) & 1)

int main(int argc, char **argv)
{
	const char *path = argc > 1 ? argv[1] : "/dev/input/event1";
	int fd = open(path, O_RDONLY);
	if (fd < 0) {
		printf("touch_query_test: open(%s) failed errno=%d\n", path, errno);
		return 1;
	}

	char name[64] = { 0 };
	if (ioctl(fd, EVIOCGNAME(sizeof(name)), name) >= 0)
		printf("touch_query_test: name=\"%s\"\n", name);

	unsigned long evbits[(EV_MAX + 1) / (8 * sizeof(unsigned long)) + 1] = { 0 };
	if (ioctl(fd, EVIOCGBIT(0, sizeof(evbits)), evbits) >= 0) {
		printf("touch_query_test: evbits EV_KEY=%d EV_ABS=%d EV_SYN=%d\n",
		       (int)TEST_BIT(evbits, EV_KEY),
		       (int)TEST_BIT(evbits, EV_ABS),
		       (int)TEST_BIT(evbits, EV_SYN));
	}

	unsigned long keybits[(KEY_MAX + 1) / (8 * sizeof(unsigned long)) + 1] = { 0 };
	if (ioctl(fd, EVIOCGBIT(EV_KEY, sizeof(keybits)), keybits) >= 0) {
		printf("touch_query_test: BTN_TOUCH supported=%d\n",
		       (int)TEST_BIT(keybits, BTN_TOUCH));
	}

	struct input_absinfo abs;
	if (ioctl(fd, EVIOCGABS(ABS_X), &abs) == 0)
		printf("touch_query_test: ABS_X min=%d max=%d\n", abs.minimum, abs.maximum);
	if (ioctl(fd, EVIOCGABS(ABS_Y), &abs) == 0)
		printf("touch_query_test: ABS_Y min=%d max=%d\n", abs.minimum, abs.maximum);
	if (ioctl(fd, EVIOCGABS(ABS_PRESSURE), &abs) == 0)
		printf("touch_query_test: ABS_PRESSURE min=%d max=%d\n", abs.minimum, abs.maximum);

	close(fd);
	return 0;
}
