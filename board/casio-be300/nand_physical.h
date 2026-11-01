/* SPDX-License-Identifier: GPL-2.0-only */
/* Included by the Linux 4.2 board driver, while the NAND core holds its lock. */
#include "nand_ecc.c"
#include "nand_boot.c"

static struct nand_boot_map physical_map;
static struct nand_ecclayout physical_layout = {
	.eccbytes = 8,
	.eccpos = { 8, 9, 10, 11, 12, 13, 14, 15 },
	.oobfree = { { .offset = 0, .length = 4 },
		     { .offset = 6, .length = 2 } },
};
static u8 physical_page[528] __aligned(4);
static u8 physical_manifest[512] __aligned(4);

static int physical_raw_read(void *ctx, uint32_t page, uint8_t raw[528])
{
	be300_nand_send_command(NAND_CMD_READ0);
	be300_nand_send_addr(0);
	be300_nand_send_addr(page & 255);
	be300_nand_send_addr(page >> 8);
	be300_nand_finish_addr();
	be300_nand_read_buf(NULL, raw, 528);
	return be300_nand_io_failed ? -EIO : 0;
}

static int physical_read_page(struct mtd_info *mtd, struct nand_chip *chip,
			      u8 *buf, int oob_required, int page)
{
	int corrected;
	unsigned int i;

	be300_nand_read_buf(mtd, physical_page, 528);
	if (be300_nand_io_failed)
		return -EIO;
	for (i = 0; i < 512 && physical_page[i] == 0xff; i++)
		;
	if (i == 512)
		for (i = 520; i < 528 && physical_page[i] == 0xff; i++)
			;
	/* Filesystem ECC protects data with an implicit FF tag. JFFS2
	 * owns OOB 0..3,6..7, so cleanmarker updates cannot invalidate
	 * data parity or require forbidden parity reprogramming. */
	memcpy(chip->oob_poi, physical_page + 512, 16);
	if (page >= 320*32 && page < 1004*32)
		memset(physical_page + 512, 0xff, 8);
	corrected = i == 528 ? 0 : nand_ecc_check(physical_page);
	if (corrected < 0) {
		mtd->ecc_stats.failed++;
		return -EBADMSG;
	}
	mtd->ecc_stats.corrected += corrected;
	memcpy(buf, physical_page, 512);
	return corrected;
}

static int physical_write_page(struct mtd_info *mtd, struct nand_chip *chip,
			       const u8 *buf, int oob_required)
{
	memcpy(physical_page, buf, 512);
	memset(physical_page + 512, 0xff, 8);
	nand_ecc_encode(physical_page);
	memcpy(physical_page + 512, chip->oob_poi, 8);
	be300_nand_write_buf(mtd, physical_page, 528);
	return be300_nand_io_failed ? -EIO : 0;
}

static int physical_program(struct mtd_info *mtd, struct nand_chip *chip,
			    uint32_t offset, int data_len, const uint8_t *buf,
			    int oob_required, int page, int cached, int raw)
{
	u8 expected[528], old_oob[8];
	unsigned int block = page / 32, i;
	int status;

	if (page < 320 * 32 || page >= 1004 * 32 || raw ||
	    (physical_manifest[28+block/8] & (1 << (block%8))))
		return -EROFS;
	if (physical_raw_read(NULL, page, physical_page))
		return -EIO;
	/* Never attempt a second data/parity program. An OOB cleanmarker
	 * may already occupy the otherwise erased first page. */
	for (i = 0; i < 528; i++)
		if ((i < 512 || i >= 520) && physical_page[i] != 0xff)
			return -EIO;
	memcpy(old_oob, physical_page + 512, 8);
	chip->cmdfunc(mtd, NAND_CMD_SEQIN, 0, page);
	status = physical_write_page(mtd, chip, buf, oob_required);
	if (status)
		return status;
	memcpy(expected, physical_page, 528);
	for (i = 0; i < 8; i++)
		expected[512+i] &= old_oob[i];
	chip->cmdfunc(mtd, NAND_CMD_PAGEPROG, -1, -1);
	status = chip->waitfunc(mtd, chip);
	if (status & NAND_STATUS_FAIL)
		return -EIO;
	if (physical_raw_read(NULL, page, physical_page) ||
	    memcmp(expected, physical_page, 528))
		return -EIO;
	return 0;
}

static int physical_erase(struct mtd_info *mtd, int page)
{
	struct nand_chip *chip = mtd->priv;
	unsigned int block = page / 32, p, i;

	if (page < 320 * 32 || page >= 1004 * 32 || (page % 32) ||
	    (physical_manifest[28+block/8] & (1 << (block%8)))) {
		be300_nand_io_failed = true;
		return NAND_STATUS_FAIL;
	}
	chip->cmdfunc(mtd, NAND_CMD_ERASE1, -1, page);
	chip->cmdfunc(mtd, NAND_CMD_ERASE2, -1, -1);
	if (chip->waitfunc(mtd, chip) & NAND_STATUS_FAIL) {
		be300_nand_io_failed = true;
		return NAND_STATUS_FAIL;
	}
	for (p = page; p < page + 32; p++) {
		if (physical_raw_read(NULL, p, physical_page))
			return NAND_STATUS_FAIL;
		for (i = 0; i < 528; i++)
			if (physical_page[i] != 0xff) {
				be300_nand_io_failed = true;
				return NAND_STATUS_FAIL;
			}
	}
	return 0;
}

static int physical_block_bad(struct mtd_info *mtd, loff_t ofs, int getchip)
{
	unsigned int block = ofs >> 14;
	unsigned int i;

	if (block >= 1024)
		return -EINVAL;
	if (physical_manifest[28 + block / 8] & (1 << (block % 8)))
		return 1;
	/* Immutable ROM tags occupy the usual marker byte; never interpret
	 * those tags as runtime bad-block markers. No boot partition is writable. */
	if (block < 320 || block >= 1004)
		return 0;
	for (i = 0; i < 2; i++) {
		if (physical_raw_read(NULL, block * 32 + i, physical_page))
			return -EIO;
		if (physical_page[517] != 0xff)
			return 1;
	}
	return 0;
}

static int physical_scan_bbt(struct mtd_info *mtd)
{
	struct nand_chip *chip = mtd->priv;
	unsigned int b, p;
	bool bad;

	chip->bbt = kmalloc(256, GFP_KERNEL);
	if (!chip->bbt)
		return -ENOMEM;
	memset(chip->bbt, 0, 256);
	chip->erase = physical_erase;
	for (b = 0; b < 1024; b++) {
		bad = !!(physical_manifest[28+b/8] & (1 << (b%8)));
		/* ROM tags are not Linux markers. Scan runtime markers only
		 * in the filesystem arena, unioned with the protected inventory. */
		if (!bad && b >= 320 && b < 1004)
			for (p = 0; p < 2; p++) {
				if (physical_raw_read(NULL, b*32+p, physical_page))
					return -EIO;
				bad |= physical_page[517] != 0xff;
			}
		if (bad)
			chip->bbt[b/4] |= 1 << ((b%4)*2);
	}
	return 0;
}

static u32 physical_crc(const u8 *p, unsigned int len)
{
	u32 crc = ~0U;
	unsigned int i;

	while (len--) {
		crc ^= *p++;
		for (i = 0; i < 8; i++)
			crc = (crc >> 1) ^ (0xedb88320U & -(crc & 1));
	}
	return ~crc;
}

static u32 physical_u32(const u8 *p)
{
	return p[0] | (u32)p[1] << 8 | (u32)p[2] << 16 | (u32)p[3] << 24;
}

static int physical_setup(struct nand_chip *chip)
{
	unsigned int count = 0, i;
	bool parity = false;

	/* Detect the explicit physical image format; ordinary data-only
	 * emulator images retain their existing controller policy. */
	if (physical_raw_read(NULL, 1, physical_page))
		return -EIO;
	for (i = 520; i < 528; i++)
		parity |= physical_page[i] != 0xff;
	if (parity && nand_ecc_check(physical_page) < 0)
		return -EBADMSG;
	if (memcmp(physical_page, "GZNAND1", 8))
		return parity ? -EINVAL : 0;
	if (!parity)
		return -EBADMSG;
	if (nand_boot_scan(&physical_map, physical_raw_read, NULL, false) ||
	    nand_boot_read(&physical_map, physical_raw_read, NULL, 1,
			   physical_manifest, false))
		return -EBADMSG;
	for (i = 0; i < 1024; i++)
		count += !!(physical_manifest[28+i/8] & (1 << (i%8)));
	if (physical_u32(physical_manifest + 8) != 1 ||
	    physical_u32(physical_manifest + 12) != 320 ||
	    physical_u32(physical_manifest + 16) != 684 ||
	    physical_u32(physical_manifest + 20) != 1004 ||
	    physical_u32(physical_manifest + 24) != count ||
	    physical_u32(physical_manifest + 508) != physical_crc(physical_manifest, 508) ||
	    memcmp(physical_manifest + 188, "LINUX1\0", 8) ||
	    (physical_manifest[28] & 1))
		return -EINVAL;
	be300_nand_physical = true;
	chip->options &= ~NAND_SKIP_BBTSCAN;
	chip->options |= NAND_NO_SUBPAGE_WRITE;
	chip->block_bad = physical_block_bad;
	chip->scan_bbt = physical_scan_bbt;
	chip->ecc.mode = NAND_ECC_HW;
	chip->ecc.size = 512;
	chip->ecc.bytes = 8;
	chip->ecc.strength = 2;
	chip->ecc.layout = &physical_layout;
	chip->ecc.read_page = physical_read_page;
	chip->ecc.write_page = physical_write_page;
	chip->write_page = physical_program;
#if CONFIG_CASIO_BE300_SDRAM_MB == 16
	pr_info("BE300_PHYSICAL_NAND_V1: RS ECC and protected inventory\n");
#else
	pr_err("BE-300 physical NAND requires stock 16 MiB SDRAM\n");
	return -EINVAL;
#endif
	return 1;
}
