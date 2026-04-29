/*
 * Phase A smoke test: verify /dev/fb0 mmap support on the BE-300 sfb driver.
 * Draws a 16x16 red/white checkerboard via the mmap'd framebuffer.
 *
 * Build (against musl): mipsel-linux-gnu-gcc -march=mips2 \
 *   -specs /work/musl-mipsel/lib/musl-gcc.specs \
 *   -isystem /work/musl-khdrs/include \
 *   -static -O2 fb_mmap_test.c -o fb_mmap_test \
 *   -B/tmp/libgcc_patched
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <linux/fb.h>

int main(void)
{
	int fd = open("/dev/fb0", O_RDWR);
	if (fd < 0) {
		perror("open /dev/fb0");
		return 1;
	}

	struct fb_var_screeninfo vinfo;
	struct fb_fix_screeninfo finfo;
	if (ioctl(fd, FBIOGET_VSCREENINFO, &vinfo) < 0) {
		perror("FBIOGET_VSCREENINFO");
		return 1;
	}
	if (ioctl(fd, FBIOGET_FSCREENINFO, &finfo) < 0) {
		perror("FBIOGET_FSCREENINFO");
		return 1;
	}

	printf("fb: %ux%u, %u bpp, line_length=%u, smem_len=%u\n",
	       vinfo.xres, vinfo.yres, vinfo.bits_per_pixel,
	       finfo.line_length, finfo.smem_len);

	void *p = mmap(NULL, finfo.smem_len, PROT_READ | PROT_WRITE,
		       MAP_SHARED, fd, 0);
	if (p == MAP_FAILED) {
		perror("mmap /dev/fb0");
		close(fd);
		return 1;
	}

	if (vinfo.bits_per_pixel != 16) {
		printf("expected 16bpp, got %u — bailing\n",
		       vinfo.bits_per_pixel);
		munmap(p, finfo.smem_len);
		close(fd);
		return 1;
	}

	unsigned short *fb = p;
	unsigned stride = finfo.line_length / 2;
	for (unsigned y = 0; y < vinfo.yres; y++) {
		for (unsigned x = 0; x < vinfo.xres; x++) {
			int blk = ((x >> 4) ^ (y >> 4)) & 1;
			fb[y * stride + x] = blk ? 0xffff : 0xf800;
		}
	}

	printf("checkerboard drawn via mmap — visually confirm screen\n");
	/* Read back a known cell via mmap. */
	printf("mmap readback fb[0]=0x%04x fb[16]=0x%04x (expected 0xf800, 0xffff)\n",
	       fb[0], fb[16]);

	/* Cross-check: read the same locations via /dev/fb0 file I/O. If mmap
	 * aliases the framebuffer device memory, lseek+read should return the
	 * same values we just wrote through mmap. If mmap mapped a private
	 * page instead of the device, file I/O reads will be all-zero. */
	if (lseek(fd, 0, SEEK_SET) == 0) {
		unsigned short fbio[2] = { 0xdead, 0xdead };
		ssize_t n = read(fd, fbio, 2);
		if (n == 2) {
			printf("file I/O readback fb[0]=0x%04x (expect 0xf800)\n",
			       fbio[0]);
		} else {
			printf("file I/O read returned n=%zd errno=%d\n", n, errno);
		}
	}

	sleep(8);
	munmap(p, finfo.smem_len);
	close(fd);
	return 0;
}
