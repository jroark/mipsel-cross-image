/* BE300 board hardware integration v1. */
#include <linux/be300_hardware.h>
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
#include <linux/slab.h>
#include <linux/io.h>
#include <linux/ioport.h>
#include <linux/mtd/mtd.h>
#include <linux/mtd/nand.h>
#include <linux/mtd/partitions.h>
#include <linux/platform_device.h>

#include "nand_controller.h"

#include "nand_physical.h"

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

static void physical_partition_size(void);

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
	int physical;

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
	physical = physical_setup(chip);
	if (physical > 0)
		physical_partition_size();
	if (physical < 0) {
		iounmap(be300_nand_xfer_io);
		be300_nand_xfer_io = NULL;
		return physical;
	}
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

static void physical_partition_size(void)
{
	be300_nand_partitions[3].size = 684 * 16384;
}

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
