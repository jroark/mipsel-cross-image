/* be300-tap — inject a stylus tap into the BE-300 touchscreen evdev node.
 *
 * Writing input_event records to /dev/input/eventN makes the kernel
 * inject them into that device (evdev_write -> input_inject_event), and
 * they reach the client holding EVIOCGRAB (pgserver).  Used by
 * tools/be300_picogui_smoke.sh to drive the UI over the serial shell,
 * since the emulator has no scripted touch input.
 *
 *   be300-tap X Y [hold_ms]       press at X,Y, hold, release
 *   be300-tap --flood N X Y       press + N move packets in ONE write()
 *                                 (overflows the reader's evdev queue so
 *                                 it sees SYN_DROPPED), then release
 *   be300-tap --fbsum Y0 Y1       print an FNV-1a hash of framebuffer rows
 *                                 [Y0,Y1) so the smoke test can tell whether
 *                                 a region changed (omnibar's clock and
 *                                 load meter rule out whole-screen sums)
 *
 * Copyright (C) 2026 John Roark
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */

#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <linux/fb.h>
#include <linux/input.h>

#define TOUCH_NAME "BE-300 PIU touchscreen"
#define FLOOD_MAX  512

/* Linux 4.2 on 32-bit MIPS uses the original 16-byte evdev record. */
struct wire_event {
  int32_t  tv_sec;
  int32_t  tv_usec;
  uint16_t type;
  uint16_t code;
  int32_t  value;
};

static struct wire_event evbuf[FLOOD_MAX * 3 + 8];
static int nev;

static void put(uint16_t type, uint16_t code, int32_t value)
{
  memset(&evbuf[nev], 0, sizeof(evbuf[nev]));
  evbuf[nev].type = type;
  evbuf[nev].code = code;
  evbuf[nev].value = value;
  nev++;
}

static int flush(int fd)
{
  ssize_t want = nev * sizeof(evbuf[0]);
  ssize_t n = write(fd, evbuf, want);

  nev = 0;
  if (n != want) {
    perror("be300-tap: write");
    return -1;
  }
  return 0;
}

static int open_touch(void)
{
  char path[32], name[80];
  int i, fd;

  for (i = 0; i < 8; i++) {
    snprintf(path, sizeof(path), "/dev/input/event%d", i);
    fd = open(path, O_WRONLY);
    if (fd < 0)
      continue;
    memset(name, 0, sizeof(name));
    if (ioctl(fd, EVIOCGNAME(sizeof(name) - 1), name) >= 0 &&
        strcmp(name, TOUCH_NAME) == 0)
      return fd;
    close(fd);
  }
  return -1;
}

static int fbsum(int y0, int y1)
{
  struct fb_fix_screeninfo fix;
  struct fb_var_screeninfo var;
  unsigned char row[2048];
  uint32_t h = 2166136261u;
  int fd, y, i, len;

  fd = open("/dev/fb0", O_RDONLY);
  if (fd < 0 || ioctl(fd, FBIOGET_FSCREENINFO, &fix) < 0 ||
      ioctl(fd, FBIOGET_VSCREENINFO, &var) < 0) {
    perror("be300-tap: /dev/fb0");
    return 1;
  }
  len = var.xres * var.bits_per_pixel / 8;
  if (len > (int)sizeof(row))
    len = sizeof(row);
  if (y1 > (int)var.yres)
    y1 = var.yres;
  for (y = y0; y < y1; y++) {
    if (pread(fd, row, len, (off_t)y * fix.line_length) != len) {
      perror("be300-tap: read fb");
      return 1;
    }
    for (i = 0; i < len; i++)
      h = (h ^ row[i]) * 16777619u;
  }
  printf("%08x\n", h);
  close(fd);
  return 0;
}

static void usage(void)
{
  fprintf(stderr, "usage: be300-tap X Y [hold_ms]\n"
                  "       be300-tap --flood N X Y\n"
                  "       be300-tap --fbsum Y0 Y1\n");
  exit(2);
}

int main(int argc, char **argv)
{
  int fd, x, y, hold_ms = 80, flood = 0, i;

  if (argc == 4 && strcmp(argv[1], "--fbsum") == 0)
    return fbsum(atoi(argv[2]), atoi(argv[3]));

  if (argc >= 2 && strcmp(argv[1], "--flood") == 0) {
    if (argc != 5)
      usage();
    flood = atoi(argv[2]);
    if (flood < 1 || flood > FLOOD_MAX)
      usage();
    argv += 2;
    argc -= 2;
  }
  if (argc < 3 || argc > 4)
    usage();
  x = atoi(argv[1]);
  y = atoi(argv[2]);
  if (argc == 4)
    hold_ms = atoi(argv[3]);

  fd = open_touch();
  if (fd < 0) {
    fprintf(stderr, "be300-tap: no '%s' evdev node\n", TOUCH_NAME);
    return 1;
  }

  put(EV_ABS, ABS_X, x);
  put(EV_ABS, ABS_Y, y);
  put(EV_ABS, ABS_PRESSURE, 1);
  put(EV_KEY, BTN_TOUCH, 1);
  put(EV_SYN, SYN_REPORT, 0);
  /* Jitter by one pixel so the input core doesn't filter the repeats. */
  for (i = 0; i < flood; i++) {
    put(EV_ABS, ABS_X, x + (i & 1));
    put(EV_SYN, SYN_REPORT, 0);
  }
  if (flood) {
    put(EV_ABS, ABS_X, x);
    put(EV_SYN, SYN_REPORT, 0);
  }
  if (flush(fd) < 0)
    return 1;

  usleep(hold_ms * 1000);

  put(EV_KEY, BTN_TOUCH, 0);
  put(EV_ABS, ABS_PRESSURE, 0);
  put(EV_SYN, SYN_REPORT, 0);
  if (flush(fd) < 0)
    return 1;

  close(fd);
  return 0;
}
