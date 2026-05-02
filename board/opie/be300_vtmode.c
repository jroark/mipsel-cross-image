#include <fcntl.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define KDSETMODE 0x4B3A
#define KD_TEXT 0x00
#define KD_GRAPHICS 0x01

int main(int argc, char **argv)
{
	int fd;
	int mode = KD_GRAPHICS;

	if (argc > 1 && strcmp(argv[1], "text") == 0)
		mode = KD_TEXT;

	fd = open("/dev/tty0", O_RDONLY | O_NOCTTY);
	if (fd < 0)
		fd = open("/dev/tty1", O_RDONLY | O_NOCTTY);
	if (fd < 0)
		return 1;

	if (ioctl(fd, KDSETMODE, mode) < 0) {
		close(fd);
		return 1;
	}

	close(fd);
	return 0;
}
