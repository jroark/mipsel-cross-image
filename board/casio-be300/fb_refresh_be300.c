/*
 * BE-300 framebuffer refresh helper.
 *
 * Xfbdev renders through an mmap of /dev/fb0. The BE-300 emulator maps that
 * framebuffer with a direct host backing pointer, so mmap writes can bypass
 * the emulator's dirty-rectangle path. Periodically issuing a tiny VRC4173
 * fill into the hidden row padding marks the visible area dirty without
 * changing displayed pixels. If a future framebuffer layout has no padding,
 * fall back to a same-source/same-destination framebuffer copy.
 */

#include <errno.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#define BE300_VRC4173_PHYS		0x0a000000UL
#define BE300_VRC4173_MAP_SIZE		0x1000
#define BE300_VRC4173_DISPLAY_OFFSET	0x200

#define BE300_DISPLAY_MODE		0x00
#define BE300_DISPLAY_COLOR		0x04
#define BE300_DISPLAY_WIDTH		0x08
#define BE300_DISPLAY_HEIGHT		0x0c
#define BE300_DISPLAY_DST_LO		0x10
#define BE300_DISPLAY_DST_HI		0x14
#define BE300_DISPLAY_SRC_LO		0x18
#define BE300_DISPLAY_SRC_HI		0x1c
#define BE300_DISPLAY_TRIGGER		0x34

static volatile uint32_t *regs;

static void usage(const char *argv0)
{
	fprintf(stderr,
		"usage: %s [-1] [-i interval-ms] [-s sample-frames]\n",
		argv0);
}

static uint32_t reg_read(unsigned int reg)
{
	return regs[reg >> 2];
}

static void reg_write(unsigned int reg, uint32_t value)
{
	regs[reg >> 2] = value;
}

static void reg_write_offset(unsigned int lo_reg, unsigned int hi_reg,
			     uint32_t value)
{
	reg_write(lo_reg, value & 0xffffu);
	reg_write(hi_reg, (value >> 16) & 0xffffu);
}

static int wait_idle(void)
{
	unsigned int i;

	for (i = 0; i < 100000; i++) {
		if ((reg_read(BE300_DISPLAY_TRIGGER) & 1u) == 0)
			return 0;
	}

	return -1;
}

static int pulse_dirty_fill(uint32_t dst, uint32_t height, uint16_t color)
{
	if (wait_idle() < 0)
		return -1;

	reg_write(BE300_DISPLAY_MODE, 0);
	reg_write(BE300_DISPLAY_COLOR, color);
	reg_write(BE300_DISPLAY_WIDTH, 1);
	reg_write(BE300_DISPLAY_HEIGHT, height);
	reg_write_offset(BE300_DISPLAY_DST_LO, BE300_DISPLAY_DST_HI, dst);
	reg_write(BE300_DISPLAY_TRIGGER, 1);

	return wait_idle();
}

static int refresh_copy(uint32_t offset, uint32_t width, uint32_t height)
{
	if (wait_idle() < 0)
		return -1;

	reg_write(BE300_DISPLAY_MODE, 1);
	reg_write(BE300_DISPLAY_WIDTH, width);
	reg_write(BE300_DISPLAY_HEIGHT, height);
	reg_write_offset(BE300_DISPLAY_DST_LO, BE300_DISPLAY_DST_HI, offset);
	reg_write_offset(BE300_DISPLAY_SRC_LO, BE300_DISPLAY_SRC_HI, offset);
	reg_write(BE300_DISPLAY_TRIGGER, 1);

	return wait_idle();
}

static int refresh_frame(uint32_t offset, uint32_t width, uint32_t height,
			 uint32_t stride, uint32_t fb_size)
{
	static uint16_t color;
	uint32_t visible_bytes;
	uint32_t pad_offset;
	uint32_t row_offset;
	uint64_t last_pixel;

	visible_bytes = width * 2u;
	row_offset = offset % stride;
	pad_offset = offset + visible_bytes;
	last_pixel = (uint64_t)pad_offset + (uint64_t)(height - 1u) * stride + 2u;

	if (stride > visible_bytes && row_offset + visible_bytes + 2u <= stride &&
	    last_pixel <= fb_size) {
		color ^= 0xffffu;
		return pulse_dirty_fill(pad_offset, height, color);
	}

	return refresh_copy(offset, width, height);
}

static int parse_uint(const char *s, unsigned int *out)
{
	char *end;
	unsigned long v;

	errno = 0;
	v = strtoul(s, &end, 0);
	if (errno || !s[0] || *end || v > 60000)
		return -1;

	*out = (unsigned int)v;
	return 0;
}

static void sample_framebuffer(volatile const uint16_t *fb, uint32_t width,
			       uint32_t height, uint32_t stride_bytes,
			       unsigned long frame)
{
	uint32_t stride = stride_bytes / 2u;
	uint32_t nonzero = 0;
	uint32_t pixels = width * height;
	uint32_t hash = 2166136261u;
	uint32_t x;
	uint32_t y;

	for (y = 0; y < height; y++) {
		volatile const uint16_t *row = fb + y * stride;

		for (x = 0; x < width; x++) {
			uint16_t px = row[x];

			if (px)
				nonzero++;
			hash ^= px;
			hash *= 16777619u;
		}
	}

	fprintf(stderr,
		"sample frame=%lu visible_nonzero=%u/%u hash=0x%08x "
		"first=%04x,%04x,%04x,%04x center=%04x,%04x,%04x,%04x\n",
		frame, nonzero, pixels, hash,
		fb[0], fb[1], fb[2], fb[3],
		fb[(height / 2u) * stride + (width / 2u) + 0],
		fb[(height / 2u) * stride + (width / 2u) + 1],
		fb[(height / 2u) * stride + (width / 2u) + 2],
		fb[(height / 2u) * stride + (width / 2u) + 3]);
}

int main(int argc, char **argv)
{
	unsigned int interval_ms = 100;
	unsigned int sample_frames = 0;
	unsigned long frame = 0;
	int once = 0;
	int fb_fd = -1;
	int mem_fd = -1;
	void *map;
	void *fb_map = MAP_FAILED;
	struct fb_var_screeninfo var;
	struct fb_fix_screeninfo fix;
	uint32_t offset;
	int i;

	for (i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "-1")) {
			once = 1;
		} else if (!strcmp(argv[i], "-i") && i + 1 < argc) {
			if (parse_uint(argv[++i], &interval_ms) < 0) {
				usage(argv[0]);
				return 2;
			}
		} else if (!strcmp(argv[i], "-s") && i + 1 < argc) {
			if (parse_uint(argv[++i], &sample_frames) < 0) {
				usage(argv[0]);
				return 2;
			}
		} else {
			usage(argv[0]);
			return 2;
		}
	}

	if (interval_ms == 0)
		interval_ms = 1;

	fb_fd = open("/dev/fb0", O_RDONLY);
	if (fb_fd < 0) {
		perror("open /dev/fb0");
		return 1;
	}
	if (ioctl(fb_fd, FBIOGET_VSCREENINFO, &var) < 0) {
		perror("FBIOGET_VSCREENINFO");
		close(fb_fd);
		return 1;
	}
	if (ioctl(fb_fd, FBIOGET_FSCREENINFO, &fix) < 0) {
		perror("FBIOGET_FSCREENINFO");
		close(fb_fd);
		return 1;
	}

	if (var.bits_per_pixel != 16 || fix.line_length == 0 ||
	    var.xres == 0 || var.yres == 0) {
		fprintf(stderr, "unsupported fb: %ux%u %ubpp stride=%u\n",
			var.xres, var.yres, var.bits_per_pixel,
			fix.line_length);
		close(fb_fd);
		return 1;
	}

	offset = var.yoffset * fix.line_length + var.xoffset * 2u;

	if (sample_frames) {
		fb_map = mmap(NULL, fix.smem_len, PROT_READ, MAP_SHARED, fb_fd, 0);
		if (fb_map == MAP_FAILED)
			perror("mmap /dev/fb0 sample");
	}
	close(fb_fd);

	mem_fd = open("/dev/mem", O_RDWR | O_SYNC);
	if (mem_fd < 0) {
		perror("open /dev/mem");
		if (fb_map != MAP_FAILED)
			munmap(fb_map, fix.smem_len);
		return 1;
	}

	map = mmap(NULL, BE300_VRC4173_MAP_SIZE, PROT_READ | PROT_WRITE,
		   MAP_SHARED, mem_fd, BE300_VRC4173_PHYS);
	if (map == MAP_FAILED) {
		perror("mmap VRC4173");
		if (fb_map != MAP_FAILED)
			munmap(fb_map, fix.smem_len);
		close(mem_fd);
		return 1;
	}

	regs = (volatile uint32_t *)((unsigned char *)map +
				    BE300_VRC4173_DISPLAY_OFFSET);
	fprintf(stderr, "refresh %ux%u stride=%u offset=0x%08x interval=%ums\n",
		var.xres, var.yres, fix.line_length, offset, interval_ms);

	do {
		if (refresh_frame(offset, var.xres, var.yres,
				  fix.line_length, fix.smem_len) < 0) {
			fprintf(stderr, "VRC4173 display engine did not become idle\n");
			break;
		}
		frame++;
		if (sample_frames && fb_map != MAP_FAILED &&
		    (frame == 1 || frame % sample_frames == 0)) {
			sample_framebuffer((volatile const uint16_t *)fb_map,
					   var.xres, var.yres,
					   fix.line_length, frame);
		}
		if (once)
			break;
		usleep(interval_ms * 1000u);
	} while (1);

	if (fb_map != MAP_FAILED)
		munmap(fb_map, fix.smem_len);
	munmap(map, BE300_VRC4173_MAP_SIZE);
	close(mem_fd);
	return once ? 0 : 1;
}
