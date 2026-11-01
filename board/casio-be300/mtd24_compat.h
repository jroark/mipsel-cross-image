/* SPDX-License-Identifier: GPL-2.0-only */
/* Interfaces added after 2.4.18, needed by the upstream MTD snapshot. */
#ifndef BE300_MTD24_COMPAT_H
#define BE300_MTD24_COMPAT_H
#include <linux/list.h>
#include <linux/delay.h>
struct inode;
struct super_block;
extern struct inode *ilookup(struct super_block *, unsigned long);
#ifndef unlikely
#define unlikely(x) __builtin_expect(!!(x), 0)
#endif
#ifndef ndelay
#define ndelay(ns) udelay(((ns) + 999) / 1000)
#endif
#ifndef BUG_ON
#define BUG_ON(condition) do { if (condition) BUG(); } while (0)
#endif
#ifndef container_of
#define container_of(ptr, type, member) list_entry(ptr, type, member)
#endif
#ifndef list_for_each_entry
#define list_for_each_entry(pos, head, member) \
	for (pos = list_entry((head)->next, typeof(*pos), member); \
	     &pos->member != (head); \
	     pos = list_entry(pos->member.next, typeof(*pos), member))
#endif
/* chipreg builds even when no mapped-flash driver is configured. */
#if !defined(CONFIG_MTD_MAP_BANK_WIDTH_1) && !defined(CONFIG_MTD_MAP_BANK_WIDTH_2) && !defined(CONFIG_MTD_MAP_BANK_WIDTH_4) && !defined(CONFIG_MTD_MAP_BANK_WIDTH_8) && !defined(CONFIG_MTD_MAP_BANK_WIDTH_16) && !defined(CONFIG_MTD_MAP_BANK_WIDTH_32)
#define CONFIG_MTD_MAP_BANK_WIDTH_1 1
#endif
#endif
