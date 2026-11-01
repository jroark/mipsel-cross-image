/* SPDX-License-Identifier: GPL-2.0-only */
#include <linux/version.h>
#if LINUX_VERSION_CODE < KERNEL_VERSION(2, 6, 9)
#ifndef __iomem
#define __iomem
#endif
#endif
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

#define BE300_NAND_MODE_READ		0x05	/* 512 data + first 8 spare */
#define BE300_NAND_MODE_READ_OOB2	0x04	/* last 8 spare bytes */
#define BE300_NAND_MODE_PROGRAM		0x07
#define BE300_NAND_MODE_PROGRAM_OOB2	0x06

#define BE300_NAND_PAGE_DATA		512
#define BE300_NAND_PAGE_OOB		16
#define BE300_NAND_PAGE_RAW		(BE300_NAND_PAGE_DATA + \
					 BE300_NAND_PAGE_OOB)
#define BE300_NAND_STATUS_READY		0xc0

static bool be300_nand_physical;
static bool be300_nand_io_failed;
static void __iomem *be300_nand_xfer_io;
static void __iomem *be300_nand_stream_io;

static enum {
	BE300_NAND_PHASE_NONE,
	BE300_NAND_PHASE_ADDR,
} be300_nand_phase;

static u8 be300_nand_last_cmd;
static u32 be300_nand_mutation_page;
static u32 be300_nand_read_page;
static u8 be300_nand_tag[8];
static u8 be300_nand_id_pos;
static u8 be300_nand_addr_pos;
static u16 be300_nand_area_base;
static u16 be300_nand_read_skip;
static bool be300_nand_read_skip_done;
static bool be300_nand_stream_started;
static u16 be300_nand_read_pos;
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

	while (!(be300_nand_xfer_read(BE300_NAND_XFER_STATUS) & 1)) {
		if (!--timeout) {
			be300_nand_io_failed = true;
			break;
		}
	}
}

static void be300_nand_finish_addr(void)
{
	if (be300_nand_phase != BE300_NAND_PHASE_ADDR)
		return;

	(void)be300_nand_xfer_read(BE300_NAND_XFER_ACK);
	be300_nand_xfer_write(BE300_NAND_XFER_CMD, 0x02);
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
	if (be300_nand_last_cmd == NAND_CMD_SEQIN && be300_nand_addr_pos > 0)
		be300_nand_mutation_page |= (u32)byte << (8 * (be300_nand_addr_pos - 1));
	if (be300_nand_last_cmd == NAND_CMD_ERASE1)
		be300_nand_mutation_page |= (u32)byte << (8 * be300_nand_addr_pos);
	if ((be300_nand_last_cmd == NAND_CMD_READ0 || be300_nand_last_cmd == NAND_CMD_READ1 ||
	     be300_nand_last_cmd == NAND_CMD_READOOB) && be300_nand_addr_pos == 1)
		be300_nand_read_page = byte;
	if ((be300_nand_last_cmd == NAND_CMD_READ0 || be300_nand_last_cmd == NAND_CMD_READ1 ||
	     be300_nand_last_cmd == NAND_CMD_READOOB) && be300_nand_addr_pos == 2)
		be300_nand_read_page |= (u32)byte << 8;
	be300_nand_addr_pos++;
}

static void be300_nand_send_command(u8 cmd)
{
	if (cmd == NAND_CMD_SEQIN || cmd == NAND_CMD_ERASE1)
		be300_nand_mutation_page = 0;
	if (be300_nand_physical && (cmd == NAND_CMD_PAGEPROG || cmd == NAND_CMD_ERASE2) &&
	    (be300_nand_mutation_page < 320 * 32 || be300_nand_mutation_page >= 1004 * 32)) {
		be300_nand_io_failed = true;
		return;
	}
	/* NK/SPL 80F0A654: select the unit explicitly. */
	writel(1, (void *)0xaa001134UL);
	writel(1, (void *)0xaa00a400UL);
	writel(1, (void *)0xaa00a408UL);
	writel(1, (void *)0xaa00a40cUL);
	writel(1, (void *)0xaa00a410UL);
	be300_nand_finish_addr();

	be300_nand_xfer_write(BE300_NAND_XFER_CMD, 0x02);
	be300_nand_xfer_write(BE300_NAND_XFER_CMD, 0x03);
	writeb(cmd, be300_nand_xfer_io + BE300_NAND_XFER_ADDR);
	(void)be300_nand_xfer_read(BE300_NAND_XFER_ACK);
	be300_nand_xfer_write(BE300_NAND_XFER_CMD, 0x02);
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

#if LINUX_VERSION_CODE >= KERNEL_VERSION(3, 0, 0)
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

#endif

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
		be300_nand_read_pos = 0;
	}
}

/*
 * A page streams as the ROM (9FC01A98-1AAE) and Casio's SPL read it: 520
 * bytes in MODE 5, then MODE 4 for the last 8 spare bytes. After the ROM's
 * NAND boot a MODE-5 burst ends at 520 bytes, and on a real BE-300 a
 * further stream read hangs the bus for good (glaze-os
 * docs/NAND_BOOT_AUDIT.md).
 */
static u8 be300_nand_stream_read_byte(void)
{
	u8 byte;

	if (be300_nand_read_pos >= BE300_NAND_PAGE_RAW)
		return 0xff;
	if (be300_nand_read_pos == BE300_NAND_PAGE_DATA + 8) {
		be300_nand_xfer_write(BE300_NAND_XFER_MODE,
				       BE300_NAND_MODE_READ_OOB2);
		be300_nand_wait_xfer_ready();
	}
	byte = readb(be300_nand_stream_io);
	if (be300_nand_read_pos >= 512 && be300_nand_read_pos < 520)
		be300_nand_tag[be300_nand_read_pos - 512] = byte;
	be300_nand_read_pos++;
	return byte;
}

static void be300_nand_discard_stream(unsigned int len)
{
	while (len >= 4 &&
	       be300_nand_read_pos + 4 <= BE300_NAND_PAGE_DATA + 8) {
		(void)readl(be300_nand_stream_io);
		be300_nand_read_pos += 4;
		len -= 4;
	}
	while (len--)
		(void)be300_nand_stream_read_byte();
}

static void be300_nand_read_buf(struct mtd_info *mtd, u8 *buf, int len)
{
	int i;

	if (len <= 0)
		return;

	if (be300_nand_last_cmd == NAND_CMD_STATUS) {
		memset(buf, be300_nand_io_failed ? 0xc1 :
		       be300_nand_physical ?
		       readl(be300_nand_xfer_io + BE300_NAND_XFER_ADDR) :
		       BE300_NAND_STATUS_READY, len);
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

