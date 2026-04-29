/*
 * arch/mips/vr41xx/casio-be300/nand.c
 *
 * NAND glue for the Casio BE-300. Drives the VRC4173 NAND controller's
 * transfer engine instead of the legacy direct-I/O ports. The DIO ports live
 * in the PCMCIA attribute-memory page and collide with NE2000 when the card
 * window is enabled; the XFER engine does not.
 *
 * Hands the chip off to the in-tree plat_nand (drivers/mtd/nand/plat_nand.c)
 * via platform_nand_data; we supply the command/address, byte/buffer I/O,
 * readiness, chip geometry hints, and partition map.
 *
 * Copyright (C) 2026 John Roark
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 2 as
 * published by the Free Software Foundation.
 */
#include <linux/init.h>
#include <linux/io.h>
#include <linux/ioport.h>
#include <linux/mtd/mtd.h>
#include <linux/mtd/nand.h>
#include <linux/mtd/partitions.h>
#include <linux/platform_device.h>

#define BE300_NAND_XFER_PA		0x0a00a400
#define BE300_NAND_XFER_LEN		0x100
#define BE300_NAND_STREAM_PA		0x0a00b000
#define BE300_NAND_STREAM_LEN		4

#define BE300_NAND_XFER_CMD		0x14
#define BE300_NAND_XFER_ADDR		0x20
#define BE300_NAND_XFER_ACK		0x30
#define BE300_NAND_XFER_STATUS		0x40
#define BE300_NAND_XFER_KICK		0x60
#define BE300_NAND_XFER_MODE		0x64

#define BE300_NAND_MODE_READ		0x05
#define BE300_NAND_MODE_PROGRAM		0x07
#define BE300_NAND_MODE_PROGRAM_OOB2	0x06

#define BE300_NAND_PAGE_DATA		512
#define BE300_NAND_PAGE_OOB		16
#define BE300_NAND_PAGE_RAW		(BE300_NAND_PAGE_DATA + \
					 BE300_NAND_PAGE_OOB)
#define BE300_NAND_STATUS_READY		0xc0

static void __iomem *be300_nand_xfer_io;
static void __iomem *be300_nand_stream_io;

static enum {
	BE300_NAND_PHASE_NONE,
	BE300_NAND_PHASE_ADDR,
} be300_nand_phase;

static u8 be300_nand_last_cmd;
static u8 be300_nand_id_pos;
static u8 be300_nand_addr_pos;
static u16 be300_nand_area_base;
static u16 be300_nand_read_skip;
static bool be300_nand_read_skip_done;
static bool be300_nand_stream_started;
static u16 be300_nand_program_column;
static u16 be300_nand_program_pos;
static bool be300_nand_program_started;

static inline void be300_nand_xfer_write(u32 off, u32 val)
{
	writel(val, be300_nand_xfer_io + off);
}

static inline u32 be300_nand_xfer_read(u32 off)
{
	return readl(be300_nand_xfer_io + off);
}

static void be300_nand_wait_xfer_ready(void)
{
	unsigned int timeout = 100000;

	while (timeout-- &&
	       !(be300_nand_xfer_read(BE300_NAND_XFER_STATUS) & 1))
		;
}

static void be300_nand_finish_addr(void)
{
	if (be300_nand_phase != BE300_NAND_PHASE_ADDR)
		return;

	be300_nand_xfer_write(BE300_NAND_XFER_ACK, 0);
	be300_nand_wait_xfer_ready();
	be300_nand_phase = BE300_NAND_PHASE_NONE;
}

static void be300_nand_begin_addr(void)
{
	if (be300_nand_phase == BE300_NAND_PHASE_ADDR)
		return;

	be300_nand_xfer_write(BE300_NAND_XFER_CMD, 0x06);
	be300_nand_addr_pos = 0;
	be300_nand_phase = BE300_NAND_PHASE_ADDR;
}

static void be300_nand_send_addr(int addr)
{
	u8 byte = addr;

	be300_nand_begin_addr();
	writeb(byte, be300_nand_xfer_io + BE300_NAND_XFER_ADDR);

	if (be300_nand_addr_pos == 0 &&
	    be300_nand_last_cmd == NAND_CMD_SEQIN)
		be300_nand_program_column += byte;
	be300_nand_addr_pos++;
}

static void be300_nand_send_command(u8 cmd)
{
	be300_nand_finish_addr();

	be300_nand_xfer_write(BE300_NAND_XFER_CMD, 0x03);
	writeb(cmd, be300_nand_xfer_io + BE300_NAND_XFER_ADDR);
	be300_nand_xfer_write(BE300_NAND_XFER_ACK, 0);
	be300_nand_wait_xfer_ready();

	be300_nand_last_cmd = cmd;
	be300_nand_stream_started = false;
	be300_nand_read_skip_done = false;

	switch (cmd) {
	case NAND_CMD_READ0:
		be300_nand_area_base = 0;
		be300_nand_read_skip = 0;
		break;
	case NAND_CMD_READ1:
		be300_nand_area_base = 256;
		be300_nand_read_skip = 256;
		break;
	case NAND_CMD_READOOB:
		be300_nand_area_base = BE300_NAND_PAGE_DATA;
		be300_nand_read_skip = BE300_NAND_PAGE_DATA;
		break;
	case NAND_CMD_SEQIN:
		be300_nand_program_column = be300_nand_area_base;
		be300_nand_program_pos = 0;
		be300_nand_program_started = false;
		break;
	case NAND_CMD_READID:
		be300_nand_id_pos = 0;
		break;
	case NAND_CMD_PAGEPROG:
		be300_nand_program_started = false;
		break;
	default:
		break;
	}
}

static void be300_nand_cmd_ctrl(struct mtd_info *mtd, int cmd,
				unsigned int ctrl)
{
	if (!be300_nand_xfer_io)
		return;

	if ((ctrl & NAND_CTRL_CHANGE) && !(ctrl & NAND_ALE))
		be300_nand_finish_addr();

	if (cmd == NAND_CMD_NONE)
		return;

	if (ctrl & NAND_ALE) {
		be300_nand_send_addr(cmd);
		return;
	}

	if (ctrl & NAND_CLE)
		be300_nand_send_command(cmd);
}

static int be300_nand_dev_ready(struct mtd_info *mtd)
{
	return !!(be300_nand_xfer_read(BE300_NAND_XFER_STATUS) & 1);
}

static void be300_nand_start_read_stream(void)
{
	be300_nand_finish_addr();

	if (!be300_nand_stream_started) {
		be300_nand_xfer_write(BE300_NAND_XFER_KICK, 1);
		be300_nand_xfer_write(BE300_NAND_XFER_MODE,
				       BE300_NAND_MODE_READ);
		be300_nand_wait_xfer_ready();
		be300_nand_stream_started = true;
	}
}

static u8 be300_nand_stream_read_byte(void)
{
	return readb(be300_nand_stream_io);
}

static void be300_nand_discard_stream(unsigned int len)
{
	while (len >= 4) {
		(void)readl(be300_nand_stream_io);
		len -= 4;
	}
	while (len--)
		(void)readb(be300_nand_stream_io);
}

static void be300_nand_read_buf(struct mtd_info *mtd, u8 *buf, int len)
{
	int i;

	if (len <= 0)
		return;

	if (be300_nand_last_cmd == NAND_CMD_STATUS) {
		memset(buf, BE300_NAND_STATUS_READY, len);
		return;
	}

	if (be300_nand_last_cmd == NAND_CMD_READID) {
		for (i = 0; i < len; i++) {
			static const u8 id[] = {
				0xec, 0x73, 0xff, 0xff,
				0xff, 0xff, 0xff, 0xff,
			};

			if (be300_nand_id_pos < ARRAY_SIZE(id))
				buf[i] = id[be300_nand_id_pos++];
			else
				buf[i] = 0xff;
		}
		return;
	}

	be300_nand_start_read_stream();
	if (!be300_nand_read_skip_done) {
		be300_nand_discard_stream(be300_nand_read_skip);
		be300_nand_read_skip_done = true;
	}

	for (i = 0; i < len; i++)
		buf[i] = be300_nand_stream_read_byte();
}

static unsigned char be300_nand_read_byte(struct mtd_info *mtd)
{
	u8 byte;

	be300_nand_read_buf(mtd, &byte, 1);
	return byte;
}

static void be300_nand_start_program_stream(void)
{
	if (!be300_nand_program_started) {
		be300_nand_finish_addr();
		be300_nand_xfer_write(BE300_NAND_XFER_KICK, 1);
		be300_nand_xfer_write(BE300_NAND_XFER_MODE,
				       BE300_NAND_MODE_PROGRAM);
		be300_nand_wait_xfer_ready();
		be300_nand_program_started = true;
		be300_nand_program_pos = 0;
	}
}

static void be300_nand_stream_write_byte(u8 byte)
{
	if (be300_nand_program_pos >= BE300_NAND_PAGE_RAW)
		return;

	if (be300_nand_program_pos == BE300_NAND_PAGE_DATA + 8) {
		be300_nand_xfer_write(BE300_NAND_XFER_MODE,
				       BE300_NAND_MODE_PROGRAM_OOB2);
		be300_nand_wait_xfer_ready();
	}

	writeb(byte, be300_nand_stream_io);
	be300_nand_program_pos++;
}

static void be300_nand_write_buf(struct mtd_info *mtd, const u8 *buf, int len)
{
	int i;

	if (len <= 0 || be300_nand_last_cmd != NAND_CMD_SEQIN)
		return;

	be300_nand_start_program_stream();

	while (be300_nand_program_pos < be300_nand_program_column)
		be300_nand_stream_write_byte(0xff);

	for (i = 0; i < len; i++)
		be300_nand_stream_write_byte(buf[i]);
}

/*
 * The emulator synthesizes OOB on the fly using Casio's NANDWRITER tag
 * format (OOB[0..1]=0x55AA, OOB[5..6]=block_id, etc.) instead of the
 * Linux/mainline bad-block-marker convention. With the default
 * nand_block_bad() reading OOB[chip->badblockpos], every block reads as
 * non-0xFF and is flagged bad, which makes JFFS2 skip the entire chip and
 * mount an empty rootfs. Force "always good" — NAND_SKIP_BBTSCAN already
 * suppresses the BBT build, this matches its intent for block lookups.
 */
static int be300_nand_block_bad(struct mtd_info *mtd, loff_t ofs, int getchip)
{
	return 0;
}

static int be300_nand_ctrl_probe(struct platform_device *pdev)
{
	/*
	 * plat_nand sets pdev drvdata to its `struct plat_nand_data` (which
	 * has `struct nand_chip chip` as its first member) BEFORE calling our
	 * ctrl.probe. We exploit that to get a pointer to the nand_chip so
	 * we can install block_bad before nand_scan() runs and walks every
	 * block's OOB. Without this, the emulator's NANDWRITER-style synthetic
	 * OOB makes every block look bad and JFFS2 sees an empty rootfs.
	 */
	struct nand_chip *chip = platform_get_drvdata(pdev);

	if (chip) {
		chip->block_bad = be300_nand_block_bad;
		/*
		 * plat_nand defaults ecc.mode = NAND_ECC_SOFT, which makes the
		 * kernel verify OOB-resident parity bytes on every read. The
		 * emulator's OOB carries NANDWRITER tags (not Hamming parity),
		 * so every page read trips __nand_correct_data and JFFS2 sees
		 * an unreadable chip. NAND_ECC_NONE skips the parity check; the
		 * NAND image was built without ECC anyway.
		 */
		chip->ecc.mode = NAND_ECC_NONE;
	}

	be300_nand_stream_io = chip ? chip->IO_ADDR_W : NULL;
	be300_nand_xfer_io = ioremap(BE300_NAND_XFER_PA,
				     BE300_NAND_XFER_LEN);
	if (!be300_nand_xfer_io)
		return -ENOMEM;
	return 0;
}

static void be300_nand_ctrl_remove(struct platform_device *pdev)
{
	if (be300_nand_xfer_io) {
		iounmap(be300_nand_xfer_io);
		be300_nand_xfer_io = NULL;
	}
	be300_nand_stream_io = NULL;
}

/*
 * 16 MiB flash carved to mirror the layout written by tools/mk_be300_nand.py:
 *   ptable  : the WinCE-style 8-entry partition table at NAND page 0
 *   spl     : the stage-1 SPL B000FF container
 *   kernel  : the flat kernel image consumed by the SPL
 *   rootfs  : JFFS2 (the only writable region)
 *
 * Sizes are aligned to 16 KiB erase blocks (32 pages × 512 B).
 */
static struct mtd_partition be300_nand_partitions[] = {
	{
		.name		= "ptable",
		.offset		= 0x000000,
		.size		= 0x004000,
		.mask_flags	= MTD_WRITEABLE,
	},
	{
		.name		= "spl",
		.offset		= 0x004000,
		.size		= 0x010000,
		.mask_flags	= MTD_WRITEABLE,
	},
	{
		.name		= "kernel",
		.offset		= 0x014000,
		.size		= 0x4ec000,
		.mask_flags	= MTD_WRITEABLE,
	},
	{
		.name		= "rootfs",
		.offset		= 0x500000,
		.size		= 0xb00000,
	},
};

static struct platform_nand_data be300_nand_data = {
	.chip = {
		.nr_chips	= 1,
		.chip_delay	= 25,
		.partitions	= be300_nand_partitions,
		.nr_partitions	= ARRAY_SIZE(be300_nand_partitions),
		/*
		 * The emulator synthesizes OOB on the fly and doesn't
		 * preserve the bad-block-marker convention (every block's
		 * first OOB byte reads as something other than 0xFF), so
		 * the kernel's bad-block scan would mark the entire chip
		 * bad. Skip the scan; the BE-300 NAND in the emulator is
		 * by definition perfect.
		 */
		.options	= NAND_SKIP_BBTSCAN,
	},
	.ctrl = {
		.cmd_ctrl	= be300_nand_cmd_ctrl,
		.dev_ready	= be300_nand_dev_ready,
		.write_buf	= be300_nand_write_buf,
		.read_buf	= be300_nand_read_buf,
		.read_byte	= be300_nand_read_byte,
		.probe		= be300_nand_ctrl_probe,
		.remove		= be300_nand_ctrl_remove,
	},
};


static struct resource be300_nand_resources[] = {
	{
		.start	= BE300_NAND_STREAM_PA,
		.end	= BE300_NAND_STREAM_PA + BE300_NAND_STREAM_LEN - 1,
		.flags	= IORESOURCE_MEM,
	},
};

static struct platform_device be300_nand_device = {
	.name		= "gen_nand",
	.id		= 0,
	.dev		= {
		.platform_data = &be300_nand_data,
	},
	.num_resources	= ARRAY_SIZE(be300_nand_resources),
	.resource	= be300_nand_resources,
};

static int __init be300_nand_init(void)
{
	return platform_device_register(&be300_nand_device);
}
arch_initcall(be300_nand_init);
