/*
 * CF-resident Linux bootstrap for the BE-300 recovery-button path.
 *
 * The stock boot ROM already knows how to find /NANDWRITER.bin on a FAT16
 * CompactFlash card and load it as a B000FF image. This replacement payload
 * keeps that filename but treats /All_nand.bin as a flat Linux kernel image
 * instead of as a NAND restore dump. It reads the kernel from the same FAT16
 * recovery partition, copies it to the baked-in kernel load address, and jumps
 * to the baked-in Linux entry point. NAND is never erased or programmed.
 */

#include <stdint.h>

#ifndef KERNEL_LOAD_VA
#define KERNEL_LOAD_VA		0x80020000u
#endif
#ifndef KERNEL_ENTRY_VA
#define KERNEL_ENTRY_VA		0x8020E890u
#endif
#ifndef KERNEL_SIZE
#define KERNEL_SIZE		0x30A81Cu
#endif

#define SECTOR_SIZE		512u

/* BE-300 boot-visible CF taskfile window, KSEG1 alias of PA 0x0A00C170. */
#define CF_BASE			0xAA00C170u
#define CF_ALT			0xAA00C376u
#define CF_DATA			(*(volatile uint32_t *)(CF_BASE + 0u))
#define CF_ERROR		(*(volatile uint8_t  *)(CF_BASE + 1u))
#define CF_SECCNT		(*(volatile uint8_t  *)(CF_BASE + 2u))
#define CF_LBA0			(*(volatile uint8_t  *)(CF_BASE + 3u))
#define CF_LBA1			(*(volatile uint8_t  *)(CF_BASE + 4u))
#define CF_LBA2			(*(volatile uint8_t  *)(CF_BASE + 5u))
#define CF_DRIVE		(*(volatile uint8_t  *)(CF_BASE + 6u))
#define CF_STATUS		(*(volatile uint8_t  *)(CF_BASE + 7u))
#define CF_COMMAND		(*(volatile uint8_t  *)(CF_BASE + 7u))
#define CF_ALTSTATUS		(*(volatile uint8_t  *)CF_ALT)
#define CF_DEVCTRL		(*(volatile uint8_t  *)CF_ALT)

#define CF_ST_ERR		0x01u
#define CF_ST_DRQ		0x08u
#define CF_ST_DRDY		0x40u
#define CF_ST_BSY		0x80u
#define CF_CMD_READ_SECTORS	0x20u

/* VRC4173 SIU at PA 0x0A008680, KSEG1 alias. */
#define SIU_THR			(*(volatile uint8_t *)0xAA008680u)
#define SIU_LSR			(*(volatile uint8_t *)(0xAA008680u + 5u * 4u))

struct fat16_layout {
	uint32_t base_lba;
	uint8_t sectors_per_cluster;
	uint16_t reserved_sectors;
	uint8_t fats;
	uint16_t root_entries;
	uint16_t fat_sectors;
	uint32_t fat_start_lba;
	uint32_t root_start_lba;
	uint32_t root_sectors;
	uint32_t data_start_lba;
};

struct fat_file {
	uint16_t first_cluster;
	uint32_t size;
};

static uint8_t sector_buf[SECTOR_SIZE] __attribute__((aligned(4)));
static struct fat16_layout fat;

static void uart_putc(char c)
{
	while (!(SIU_LSR & 0x20u))
		;
	SIU_THR = (uint8_t)c;
}

static void uart_puts(const char *s)
{
	while (*s) {
		if (*s == '\n')
			uart_putc('\r');
		uart_putc(*s++);
	}
}

static void uart_puthex32(uint32_t v)
{
	static const char hex[] = "0123456789ABCDEF";
	int i;

	for (i = 28; i >= 0; i -= 4)
		uart_putc(hex[(v >> i) & 0x0Fu]);
}

static uint16_t get_le16(const uint8_t *p)
{
	return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

static uint32_t get_le32(const uint8_t *p)
{
	return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
	       ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static void delay_cycles(volatile uint32_t count)
{
	while (count--)
		;
}

static int cf_wait_ready(uint8_t set, uint8_t clear)
{
	uint32_t timeout = 2000000u;

	while (timeout--) {
		uint8_t st = CF_STATUS;

		if ((st & CF_ST_ERR) != 0u)
			return -1;
		if ((st & clear) == 0u && (st & set) == set)
			return 0;
	}
	return -1;
}

static void cf_reset(void)
{
	CF_DEVCTRL = 0x04u;
	delay_cycles(20000u);
	CF_DEVCTRL = 0x00u;
	delay_cycles(20000u);
	(void)CF_ALTSTATUS;
}

static int cf_read_sector(uint32_t lba, uint8_t *dst)
{
	uint32_t *out = (uint32_t *)dst;
	int i;

	if (cf_wait_ready(CF_ST_DRDY, CF_ST_BSY) != 0)
		return -1;

	CF_SECCNT = 1u;
	CF_LBA0 = (uint8_t)(lba & 0xFFu);
	CF_LBA1 = (uint8_t)((lba >> 8) & 0xFFu);
	CF_LBA2 = (uint8_t)((lba >> 16) & 0xFFu);
	CF_DRIVE = (uint8_t)(0xE0u | ((lba >> 24) & 0x0Fu));
	CF_COMMAND = CF_CMD_READ_SECTORS;

	if (cf_wait_ready(CF_ST_DRQ, CF_ST_BSY) != 0)
		return -1;

	for (i = 0; i < (int)(SECTOR_SIZE / 4u); i++)
		out[i] = CF_DATA;

	return cf_wait_ready(CF_ST_DRDY, CF_ST_BSY);
}

static int is_fat16_boot_sector(const uint8_t *sector)
{
	uint16_t bytes_per_sector;

	if (sector[510] != 0x55u || sector[511] != 0xAAu)
		return 0;
	bytes_per_sector = get_le16(&sector[11]);
	if (bytes_per_sector != SECTOR_SIZE)
		return 0;
	if (sector[54] != 'F' || sector[55] != 'A' ||
	    sector[56] != 'T' || sector[57] != '1' ||
	    sector[58] != '6')
		return 0;
	return 1;
}

static int fat_try_mount(uint32_t base_lba)
{
	uint32_t total16;
	uint32_t total32;

	if (cf_read_sector(base_lba, sector_buf) != 0)
		return -1;
	if (!is_fat16_boot_sector(sector_buf))
		return -1;

	fat.base_lba = base_lba;
	fat.sectors_per_cluster = sector_buf[13];
	fat.reserved_sectors = get_le16(&sector_buf[14]);
	fat.fats = sector_buf[16];
	fat.root_entries = get_le16(&sector_buf[17]);
	fat.fat_sectors = get_le16(&sector_buf[22]);

	total16 = get_le16(&sector_buf[19]);
	total32 = get_le32(&sector_buf[32]);
	(void)total16;
	(void)total32;

	if (fat.sectors_per_cluster == 0u || fat.reserved_sectors == 0u ||
	    fat.fats == 0u || fat.root_entries == 0u || fat.fat_sectors == 0u)
		return -1;

	fat.fat_start_lba = fat.base_lba + fat.reserved_sectors;
	fat.root_start_lba = fat.fat_start_lba +
		(uint32_t)fat.fats * (uint32_t)fat.fat_sectors;
	fat.root_sectors = ((uint32_t)fat.root_entries * 32u +
			    SECTOR_SIZE - 1u) / SECTOR_SIZE;
	fat.data_start_lba = fat.root_start_lba + fat.root_sectors;
	return 0;
}

static int is_fat_partition_type(uint8_t type)
{
	return type == 0x01u || type == 0x04u || type == 0x06u || type == 0x0Eu;
}

static int fat_mount(void)
{
	uint8_t mbr[SECTOR_SIZE] __attribute__((aligned(4)));
	int i;

	if (fat_try_mount(0) == 0)
		return 0;

	if (cf_read_sector(0, mbr) != 0)
		return -1;
	if (mbr[510] != 0x55u || mbr[511] != 0xAAu)
		return -1;

	for (i = 0; i < 4; i++) {
		const uint8_t *part = &mbr[0x1BE + i * 16];
		uint8_t type = part[4];
		uint32_t start_lba = get_le32(&part[8]);
		uint32_t sectors = get_le32(&part[12]);

		if (!is_fat_partition_type(type) || start_lba == 0u || sectors == 0u)
			continue;
		if (fat_try_mount(start_lba) == 0)
			return 0;
	}

	return -1;
}

static int short_name_matches(const uint8_t *entry, const char want[11])
{
	int i;

	for (i = 0; i < 11; i++) {
		if ((char)entry[i] != want[i])
			return 0;
	}
	return 1;
}

static int fat_find_root_file(const char short_name[11], struct fat_file *file)
{
	uint32_t s;

	for (s = 0; s < fat.root_sectors; s++) {
		uint32_t off;

		if (cf_read_sector(fat.root_start_lba + s, sector_buf) != 0)
			return -1;

		for (off = 0; off < SECTOR_SIZE; off += 32u) {
			const uint8_t *ent = &sector_buf[off];
			uint8_t attr = ent[11];

			if (ent[0] == 0x00u)
				return -1;
			if (ent[0] == 0xE5u)
				continue;
			if (attr == 0x0Fu || (attr & 0x08u) != 0u)
				continue;
			if (!short_name_matches(ent, short_name))
				continue;

			file->first_cluster = get_le16(&ent[26]);
			file->size = get_le32(&ent[28]);
			return 0;
		}
	}

	return -1;
}

static int fat_next_cluster(uint16_t cluster, uint16_t *next)
{
	uint32_t fat_offset = (uint32_t)cluster * 2u;
	uint32_t lba = fat.fat_start_lba + (fat_offset / SECTOR_SIZE);
	uint32_t off = fat_offset & (SECTOR_SIZE - 1u);

	if (cf_read_sector(lba, sector_buf) != 0)
		return -1;
	*next = get_le16(&sector_buf[off]);
	return 0;
}

static void copy_to_kernel(uint8_t *dst, const uint8_t *src, uint32_t len)
{
	while (len >= 4u) {
		*(volatile uint32_t *)dst = get_le32(src);
		dst += 4u;
		src += 4u;
		len -= 4u;
	}
	while (len--) {
		*(volatile uint8_t *)dst = *src;
		dst++;
		src++;
	}
}

static int fat_load_file(const struct fat_file *file, uint8_t *dst,
			 uint32_t expected_size)
{
	uint16_t cluster = file->first_cluster;
	uint32_t remaining = file->size;
	uint32_t loaded = 0;

	if (remaining < expected_size)
		return -1;
	if (remaining > expected_size)
		remaining = expected_size;

	while (remaining > 0u && cluster >= 2u && cluster < 0xFFF8u) {
		uint32_t cluster_lba = fat.data_start_lba +
			((uint32_t)cluster - 2u) *
			(uint32_t)fat.sectors_per_cluster;
		uint8_t sector;

		for (sector = 0; sector < fat.sectors_per_cluster &&
		     remaining > 0u; sector++) {
			uint32_t take = remaining > SECTOR_SIZE ?
				SECTOR_SIZE : remaining;

			if (cf_read_sector(cluster_lba + sector, sector_buf) != 0)
				return -1;
			copy_to_kernel(dst + loaded, sector_buf, take);
			loaded += take;
			remaining -= take;
		}

		if (remaining > 0u && fat_next_cluster(cluster, &cluster) != 0)
			return -1;
	}

	return remaining == 0u ? 0 : -1;
}

uint32_t cf_linux_main(void)
{
	static const char all_nand_bin[11] = {
		'A', 'L', 'L', '_', 'N', 'A', 'N', 'D', 'B', 'I', 'N'
	};
	struct fat_file kernel;
	uint8_t *kernel_dst = (uint8_t *)((KERNEL_LOAD_VA & 0x1FFFFFFFu) |
					  0xA0000000u);

	uart_puts("\nBE-300 CF Linux bootstrap\n");
	uart_puts("kernel load = 0x");
	uart_puthex32(KERNEL_LOAD_VA);
	uart_puts(", entry = 0x");
	uart_puthex32(KERNEL_ENTRY_VA);
	uart_puts(", size = 0x");
	uart_puthex32(KERNEL_SIZE);
	uart_puts("\n");

	cf_reset();
	if (fat_mount() != 0) {
		uart_puts("FAT16 mount failed\n");
		goto fail;
	}
	uart_puts("FAT16 base LBA = 0x");
	uart_puthex32(fat.base_lba);
	uart_puts("\n");
	if (fat_find_root_file(all_nand_bin, &kernel) != 0) {
		uart_puts("All_nand.bin not found\n");
		goto fail;
	}

	uart_puts("All_nand.bin cluster = 0x");
	uart_puthex32(kernel.first_cluster);
	uart_puts(", size = 0x");
	uart_puthex32(kernel.size);
	uart_puts("\n");

	if (fat_load_file(&kernel, kernel_dst, KERNEL_SIZE) != 0) {
		uart_puts("kernel load failed\n");
		goto fail;
	}

	uart_puts("kernel loaded from CF; jumping\n");
	return KERNEL_ENTRY_VA;

fail:
	uart_puts("CF Linux bootstrap halted\n");
	while (1)
		;
}
