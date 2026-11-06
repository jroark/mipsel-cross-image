/* Host stand-in for <asm/io.h>, for tests that include board headers.
 * Attribute memory at KSEG1 0xAA00D000 reads the test's CIS with the PC
 * Card every-other-byte stride; readl() is the A008 card-detect word. */
#ifndef TEST_ASM_IO_H
#define TEST_ASM_IO_H
#include <stdint.h>
typedef uint8_t u8;
extern unsigned char test_cis[256];
extern unsigned int test_a008;
static inline unsigned int readb(const volatile void *addr)
{
	unsigned long off = (unsigned long)addr - 0xaa00d000UL;
	if (off >= 0x200)
		return 0xff;
	return (off & 1) ? 0xff : test_cis[off / 2];
}
static inline unsigned int readl(const volatile void *addr)
{
	(void)addr;
	return test_a008;
}
#endif
