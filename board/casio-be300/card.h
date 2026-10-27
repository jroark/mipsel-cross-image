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
	if ((readl((void *)0xaa001000UL) & 12) != 4)
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
static inline int be300_wired_card(void)
{
	unsigned int function, man, product;
	return be300_card_identity(&function, &man, &product) &&
	       !be300_wireless_card();
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
