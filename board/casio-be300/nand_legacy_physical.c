/* SPDX-License-Identifier: GPL-2.0-only */
/* BE300 board hardware integration v1. */
/* Physical NAND binding for Linux 2.6.8.1 and the Linux 2.4 MTD backport. */
#include <linux/config.h>
#include <linux/init.h>
#include <linux/slab.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/types.h>
#include <linux/string.h>
#include <linux/mtd/mtd.h>
#include <linux/version.h>
#if LINUX_VERSION_CODE < KERNEL_VERSION(2, 6, 9)
#ifndef __iomem
#define __iomem
#endif
#endif
#include <linux/mtd/nand.h>
#include <linux/mtd/partitions.h>
#include <asm/io.h>
#include <stdbool.h>
#include "nand_controller.h"
#include "nand_ecc.c"

static struct mtd_info physical_mtd;
static struct nand_chip physical_chip;
static u8 quarantine[128];
static u8 page_raw[528] __attribute__((aligned(4)));
static struct nand_oobinfo physical_oob = {
	.useecc = MTD_NANDECC_AUTOPLACE,
	.eccbytes = 8,
	.eccpos = {8,9,10,11,12,13,14,15},
	.oobfree = {{0,4},{6,2}},
};

static void physical_command(struct mtd_info *mtd, unsigned command,
			     int column, int page)
{
	if (command == NAND_CMD_SEQIN) {
		unsigned area = column >= 512 ? NAND_CMD_READOOB :
			column >= 256 ? NAND_CMD_READ1 : NAND_CMD_READ0;
		be300_nand_send_command(area);
	}
	be300_nand_send_command(command);
	if (column >= 0)
		be300_nand_send_addr(column & 255);
	if (page >= 0) {
		be300_nand_send_addr(page & 255);
		be300_nand_send_addr(page >> 8);
	}
	be300_nand_finish_addr();
	if (command == NAND_CMD_READ0 || command == NAND_CMD_READ1 ||
	    command == NAND_CMD_READOOB)
		be300_nand_wait_xfer_ready();
}

static void physical_select(struct mtd_info *mtd, int chip)
{
	if (chip < 0) {
		be300_nand_xfer_write(BE300_NAND_XFER_MODE, 0);
		be300_nand_xfer_write(BE300_NAND_XFER_CMD, 0);
	}
}

static void physical_hwctl(struct mtd_info *mtd, int mode) {}

static int physical_calculate(struct mtd_info *mtd, const u8 *data, u8 *ecc)
{
	memcpy(page_raw, data, 512);
	memset(page_raw + 512, 0xff, 8);
	nand_ecc_encode(page_raw);
	memcpy(ecc, page_raw + 520, 8);
	return be300_nand_io_failed ? -EIO : 0;
}

static int physical_correct(struct mtd_info *mtd, u8 *data, u8 *ecc, u8 *calc)
{
	unsigned int i;
	int ret;

	memcpy(page_raw, data, 512);
	memset(page_raw + 512, 0xff, 8);
	if (be300_nand_read_page < 320*32 || be300_nand_read_page >= 1004*32)
		memcpy(page_raw + 512, be300_nand_tag, 8);
	memcpy(page_raw + 520, ecc, 8);
	for (i = 0; i < 528 && page_raw[i] == 0xff; i++)
		;
	ret = i == 528 ? 0 : nand_ecc_check(page_raw);
	if (ret >= 0)
		memcpy(data, page_raw, 512);
	return be300_nand_io_failed ? -EIO : ret;
}

static int physical_verify(struct mtd_info *mtd, const u8 *buf, int len)
{
	int i;
	for (i = 0; i < len; i++)
		if (be300_nand_read_byte(mtd) != buf[i])
			return -EIO;
	return be300_nand_io_failed ? -EIO : 0;
}

static int physical_bbt(struct mtd_info *mtd)
{
	struct nand_chip *chip = mtd->priv;
	unsigned int b, p;
	bool bad;

	chip->bbt = kmalloc(256, GFP_KERNEL);
	if (!chip->bbt)
		return -ENOMEM;
	memset(chip->bbt, 0, 256);
	for (b = 0; b < 1024; b++) {
		bad = !!(quarantine[b/8] & (1 << (b%8)));
		if (!bad && b >= 320 && b < 1004)
			for (p = 0; p < 2; p++) {
				physical_command(mtd, NAND_CMD_READ0, 0, b*32+p);
				be300_nand_read_buf(mtd, page_raw, 528);
				if (be300_nand_io_failed)
					return -EIO;
				bad |= page_raw[517] != 0xff;
			}
		if (bad)
			chip->bbt[b/4] |= 1 << ((b%4)*2);
	}
	return 0;
}

static u32 get_u32(const u8 *p)
{
	return p[0] | (u32)p[1] << 8 | (u32)p[2] << 16 | (u32)p[3] << 24;
}

static int physical_manifest(void)
{
	u32 crc = ~0U;
	unsigned int i, j, count = 0;

	physical_command(NULL, NAND_CMD_READ0, 0, 1);
	be300_nand_read_buf(NULL, page_raw, 528);
	if (be300_nand_io_failed || nand_ecc_check(page_raw) < 0 ||
	    memcmp(page_raw, "GZNAND1", 8) ||
	    memcmp(page_raw+188, "LINUX1\0", 8))
		return -EINVAL;
	for (i = 0; i < 508; i++) {
		crc ^= page_raw[i];
		for (j = 0; j < 8; j++)
			crc = (crc >> 1) ^ (0xedb88320U & -(crc & 1));
	}
	for (i = 0; i < 1024; i++)
		count += !!(page_raw[28+i/8] & (1 << (i%8)));
	if (~crc != get_u32(page_raw+508) || get_u32(page_raw+8) != 1 ||
	    get_u32(page_raw+12) != 320 || get_u32(page_raw+16) != 684 ||
	    get_u32(page_raw+20) != 1004 || get_u32(page_raw+24) != count ||
	    (page_raw[28] & 1))
		return -EINVAL;
	memcpy(quarantine, page_raw+28, 128);
	return 0;
}

static struct mtd_partition physical_parts[] = {
	{ .name="ptable", .offset=0, .size=0x4000, .mask_flags=MTD_WRITEABLE },
	{ .name="spl", .offset=0x4000, .size=0x10000, .mask_flags=MTD_WRITEABLE },
	{ .name="kernel", .offset=0x14000, .size=0x4ec000, .mask_flags=MTD_WRITEABLE },
	{ .name="rootfs", .offset=0x500000, .size=684*16384 },
};

static int __init be300_physical_init(void)
{
	struct nand_chip *chip = &physical_chip;
	struct mtd_info *mtd = &physical_mtd;
	int ret;

	be300_nand_xfer_io = ioremap(BE300_NAND_XFER_PA, BE300_NAND_XFER_LEN);
	be300_nand_stream_io = ioremap(BE300_NAND_STREAM_PA, BE300_NAND_STREAM_LEN);
	if (!be300_nand_xfer_io || !be300_nand_stream_io)
		return -ENOMEM;
	ret = physical_manifest();
	if (ret)
		return ret;
	be300_nand_physical = true;
	mtd->priv = chip;
	mtd->owner = THIS_MODULE;
	#if LINUX_VERSION_CODE < KERNEL_VERSION(2, 6, 0)
	chip->IO_ADDR_R = chip->IO_ADDR_W = be300_nand_stream_io;
#else
	chip->IO_ADDR_R = chip->IO_ADDR_W = (unsigned long)be300_nand_stream_io;
#endif
	chip->cmdfunc = physical_command;
	chip->select_chip = physical_select;
	chip->read_byte = be300_nand_read_byte;
	chip->read_buf = be300_nand_read_buf;
	chip->write_buf = be300_nand_write_buf;
	chip->verify_buf = physical_verify;
	chip->dev_ready = be300_nand_dev_ready;
	chip->calculate_ecc = physical_calculate;
	chip->correct_data = physical_correct;
	chip->enable_hwecc = physical_hwctl;
	chip->eccmode = NAND_ECC_HW8_512;
	chip->autooob = &physical_oob;
	chip->scan_bbt = physical_bbt;
	chip->chip_delay = 25;
	ret = nand_scan(mtd, 1);
	if (ret)
		return ret;
	printk(KERN_INFO "BE300_PHYSICAL_NAND_V1: RS ECC and protected inventory\n");
	return add_mtd_partitions(mtd, physical_parts, ARRAY_SIZE(physical_parts));
}
module_init(be300_physical_init);
