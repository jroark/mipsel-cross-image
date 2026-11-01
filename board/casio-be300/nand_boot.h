/* SPDX-License-Identifier: GPL-2.0-only
 * From jroark/glaze-os; Copyright (C) 2026 John Roark.
 * GPLv2 reuse authorized by the copyright owner, 2026-10-31.
 */
/* Read-only boot content in the ROM/CE logical block namespace. */
#ifndef GLAZE_NAND_BOOT_H
#define GLAZE_NAND_BOOT_H
#ifndef __KERNEL__
#include <stdbool.h>
#endif
#ifdef __KERNEL__
#include <linux/types.h>
#else
#include <stdint.h>
#endif
#define NAND_BOOT_BLOCKS 320u /* immutable image below physical FS arena 0x500000 */
#define NAND_BOOT_NONE 0xFFFFu
struct nand_boot_map {
    uint16_t block[NAND_BOOT_BLOCKS];
    uint8_t raw[528] __attribute__((aligned(4)));
    uint32_t corrected;
    bool protected;
    uint8_t protected_block[NAND_BOOT_BLOCKS];
    uint8_t quarantine[128]; /* conservative CE tag/ECC physical inventory */
    uint16_t journal;        /* an OTA journal's physical block (glaze/ota.h), or NONE */
    uint16_t journals;       /* how many blocks carried one */
};
typedef int (*nand_boot_raw_fn)(void *ctx, uint32_t physical_page, uint8_t raw[528]);
/* Both operations fail closed on read/ECC error, missing or duplicate mapping.
 * allow_no_ecc exists for data-only emulator images with synthetic spare tags.
 * Once any real parity is observed, every selected tag quorum and content
 * page must have valid ECC even in that compatibility mode. */
/* The scan also finds an OTA journal block: one whose first five pages
 * carry at least three GZ_OTA_JOURNAL_TAG spare tags and no logical tag.
 * It is neither mapped nor quarantined. */
int nand_boot_manifest_valid(const uint8_t data[512]);
int nand_boot_scan(struct nand_boot_map *map, nand_boot_raw_fn read, void *ctx,
                   bool allow_no_ecc);
int nand_boot_read(struct nand_boot_map *map, nand_boot_raw_fn read, void *ctx,
                   uint32_t logical_page, void *data, bool allow_no_ecc);
#endif
