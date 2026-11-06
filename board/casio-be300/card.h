/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef BE300_CARD_H
#define BE300_CARD_H
#include <asm/io.h>
/* Read tuples only. Attribute byte 0x100 at this alias is NAND DIO. */
static inline int be300_card_identity(unsigned int *function_out,
				      unsigned int *man_out,
				      unsigned int *product_out)
{
	unsigned int pos = 0, tuples, code, n, function = 0xff, man = 0,
		     product = 0;
	unsigned int i;
	u8 data[4];
	/* Card-detect inputs, active low (A008 bits 1-2). 1000 reads 4 only
	 * after Windows CE has set a card up, 0 after a power-on (glaze-os
	 * docs/NAND_BOOT_AUDIT.md, "Power-on findings"). */
	if (readl((void *)0xaa00a008UL) & 6)
		return 0;
	for (tuples = 0; tuples < 64 && pos + 2 < 256; tuples++) {
		code = readb((void *)(0xaa00d000UL + pos * 2));
		if (code == 0xff)
			break;
		if (!code) {
			pos++;
			continue;
		}
		n = readb((void *)(0xaa00d000UL + (pos + 1) * 2));
		if (n == 255 || n > 256 - pos - 2)
			break;
		if ((code == 0x20 && n >= 4) || (code == 0x21 && n >= 2)) {
			for (i = 0; i < (code == 0x20 ? 4 : 2); i++)
				data[i] = readb((void *)(0xaa00d000UL +
							 (pos + 2 + i) * 2));
			if (code == 0x21)
				function = data[0];
			else {
				man = data[0] | (data[1] << 8);
				product = data[2] | (data[3] << 8);
			}
		}
		pos += n + 2;
	}
	*function_out = function;
	*man_out = man;
	*product_out = product;
	return function == 6;
}
#define BE300_CIS(i) readb((void *)(0xaa00d000UL + (i) * 2))
/*
 * CFTABLE_ENTRY (1Bh): note the entry's index, the default one, and the
 * first that decodes I/O 0x300 (a range starting there, or address lines
 * only). PC Card Standard 8 vol. 4 3.3.2; glaze-os cf.c cis_entry.
 */
static inline void be300_cis_entry(unsigned int p, unsigned int end,
				   int *index_out, int *io_index_out)
{
	unsigned int indx, fs, sel, bit, n, b, io, r, asz, lsz, base, t;
	int index, decodes;
#define BE300_CIS_NEXT() (p < end ? BE300_CIS(p++) : 0)
	indx = BE300_CIS_NEXT();
	index = indx & 0x3f;
	if (*index_out < 0 || (indx & 0x40))
		*index_out = index;
	if (indx & 0x80)
		(void)BE300_CIS_NEXT();
	fs = BE300_CIS_NEXT();
	for (n = fs & 3; n; n--) {
		sel = BE300_CIS_NEXT();
		for (bit = 0; bit < 7; bit++)
			if (sel & (1U << bit))
				while ((BE300_CIS_NEXT() & 0x80) && p < end)
					;
	}
	if (fs & 4) {
		t = BE300_CIS_NEXT();
		if ((t & 3) != 3)
			while ((BE300_CIS_NEXT() & 0x80) && p < end)
				;
		if (((t >> 2) & 7) != 7)
			while ((BE300_CIS_NEXT() & 0x80) && p < end)
				;
		if (((t >> 5) & 7) != 7)
			while ((BE300_CIS_NEXT() & 0x80) && p < end)
				;
	}
	if (!(fs & 8))
		return;
	io = BE300_CIS_NEXT();
	decodes = !(io & 0x80) && (io & 0x1f) >= 5;
	if (io & 0x80) {
		r = BE300_CIS_NEXT();
		asz = (r >> 4) & 3;
		lsz = (r >> 6) & 3;
		asz = asz == 3 ? 4 : asz;
		lsz = lsz == 3 ? 4 : lsz;
		for (n = (r & 0x0f) + 1; n; n--) {
			base = 0;
			for (b = 0; b < asz; b++)
				base |= BE300_CIS_NEXT() << (8 * b);
			for (b = 0; b < lsz; b++)
				(void)BE300_CIS_NEXT();
			if (base == 0x300)
				decodes = 1;
		}
	}
	if (decodes && *io_index_out < 0)
		*io_index_out = index;
#undef BE300_CIS_NEXT
}

/*
 * The card's configuration-register base (CONFIG, 1Ah) and the COR an I/O
 * card at port 0x300 needs: entry index plus level interrupts (0x40).
 * Returns 0 if the card has no usable CONFIG tuple. glaze-os cf.c
 * read_cis/configure_network, which a real WL54-CF accepted.
 */
static inline int be300_card_io_config(unsigned int *cor_addr,
				       unsigned int *cor_value)
{
	unsigned int pos = 0, tuples, code, n, b, rasz, cor = 0;
	int index = -1, io_index = -1;

	if (readl((void *)0xaa00a008UL) & 6)
		return 0;
	for (tuples = 0; tuples < 64 && pos + 2 < 256; tuples++) {
		code = BE300_CIS(pos);
		if (code == 0xff)
			break;
		if (!code) {
			pos++;
			continue;
		}
		n = BE300_CIS(pos + 1);
		if (n == 255 || n > 256 - pos - 2)
			break;
		if (code == 0x1a && n >= 3) {
			rasz = (BE300_CIS(pos + 2) & 3) + 1;
			cor = 0;
			for (b = 0; b < rasz && 2 + b < n; b++)
				cor |= BE300_CIS(pos + 4 + b) << (8 * b);
		} else if (code == 0x1b && n >= 1) {
			be300_cis_entry(pos + 2, pos + 2 + n, &index, &io_index);
		}
		pos += n + 2;
	}
	if (!cor || cor >= 0x800)
		return 0;
	*cor_addr = cor;
	*cor_value = 0x40 | (io_index >= 0 ? io_index : index >= 0 ? index : 1);
	return 1;
}

static inline int be300_wireless_card(void)
{
	unsigned int function, man, product;
	if (!be300_card_identity(&function, &man, &product))
		return 0;
	if (man == 0xd601 && product == 5)
		return 1;
	if (man == 0x02df && product == 0x8103)
		return 2;
	return 0;
}
/* Socket 0's FUNCID (2 serial, 4 fixed disk, 6 network), 0xff if it has
 * none, -1 if the socket is empty. */
static inline int be300_card_function(void)
{
	unsigned int function = 0xff, man, product;
	if (readl((void *)0xaa00a008UL) & 6)
		return -1;
	be300_card_identity(&function, &man, &product);
	return function;
}
/*
 * A network card for the NE2000 driver: not one with its own driver or one
 * NE2000 registers would only misprogram. 3Com (0101, 3c589: an EtherLink
 * III) and Lucent (0156, Hermes/Orinoco) are not NS8390s.
 */
static inline int be300_wired_card(void)
{
	unsigned int function, man, product;
	if (!be300_card_identity(&function, &man, &product) ||
	    be300_wireless_card())
		return 0;
	return man != 0x0101 && man != 0x0156;
}
static inline int be300_card_node_id(u8 *mac)
{
	unsigned int pos = 0, code, n, i;
	while (pos + 2 < 256) {
		code = readb((void *)(0xaa00d000UL + pos * 2));
		if (code == 255)
			break;
		if (!code) {
			pos++;
			continue;
		}
		n = readb((void *)(0xaa00d000UL + (pos + 1) * 2));
		if (n == 255 || n > 256 - pos - 2)
			break;
		if (code == 0x22 && n >= 8 &&
		    readb((void *)(0xaa00d000UL + (pos + 2) * 2)) == 4 &&
		    readb((void *)(0xaa00d000UL + (pos + 3) * 2)) == 6) {
			for (i = 0; i < 6; i++)
				mac[i] = readb((void *)(0xaa00d000UL +
							(pos + 4 + i) * 2));
			return 1;
		}
		pos += n + 2;
	}
	return 0;
}
#endif
