/*
 * Stage-1 SPL for the Casio BE-300.
 *
 * Loaded into SDRAM at 0x80F00000 by the boot ROM's record walker after
 * parsing the partition-1 B000FF container. Reads the kernel image as a
 * flat binary from NAND offset KERNEL_NAND_OFFSET and jumps to the kernel
 * entry. The kernel's load VA, entry, and size are baked in by the build
 * script as compile-time constants extracted from vmlinux.
 */

#include <stdint.h>
#include "nand_boot.h"
/* Keep the standalone SPL build shared by all kernel versions. */
#include "nand_ecc.c"
#include "nand_boot.c"

/* Kernel layout — overridden by -DKERNEL_* on the SPL command line. */
#ifndef KERNEL_LOAD_VA
#define KERNEL_LOAD_VA      0x80020000u
#endif
#ifndef KERNEL_ENTRY_VA
#define KERNEL_ENTRY_VA     0x8020E890u
#endif
#ifndef KERNEL_SIZE
#define KERNEL_SIZE         0x30A81Cu
#endif
#ifndef KERNEL_NAND_OFFSET
#define KERNEL_NAND_OFFSET  0x14000u
#endif

#define NAND_PAGE_DATA      512u

/* VRC4173 NAND XFER engine, KSEG1 (uncached) aliases of PA 0x0A00A4xx. */
#define XFER_CMD     (*(volatile uint32_t *)0xAA00A414u)  /* phase select */
#define XFER_ADDR8   (*(volatile uint8_t  *)0xAA00A420u)  /* cmd/addr byte */
#define XFER_ACK     (*(volatile uint32_t *)0xAA00A430u)  /* commit phase */
#define XFER_STATUS  (*(volatile uint32_t *)0xAA00A440u)  /* bit 0 ready */
#define XFER_KICK    (*(volatile uint32_t *)0xAA00A460u)  /* start busy */
#define XFER_MODE    (*(volatile uint32_t *)0xAA00A464u)  /* 0x05 = raw page read */
#define STREAM_DATA  (*(volatile uint32_t *)0xAA00B000u)  /* 4-byte stream port */

/* VRC4173 SIU (UART) at 0xAA008680, addr_mult=4. Used for early debug. */
#define SIU_THR      (*(volatile uint8_t *)0xAA008680u)        /* base + 0  */
#define SIU_LSR      (*(volatile uint8_t *)(0xAA008680u + 5*4)) /* base + 5*4 */

/*
 * After a power-on the companion SIU's clock gate is off, and touching a
 * gated companion unit stalls the bus for good, which no poll bound can
 * catch (glaze-os docs/NAND_BOOT_AUDIT.md, "Power-on findings"). Which of
 * the gates Windows CE leaves on clocks the SIU is still open, so stay silent
 * unless one is on; the kernel powers the units on itself
 * (hardware.c be300_console_ready).
 */
static int siu_clocked(void)
{
    return (*(volatile uint32_t *)0xAA001108u & *(volatile uint32_t *)0xAA00112Cu &
            *(volatile uint32_t *)0xAA001138u & *(volatile uint32_t *)0xAA00113Cu) & 1u;
}

static void uart_putc(char c)
{
    unsigned int timeout = 1000000;
    if (!siu_clocked())
        return;
    while (!(SIU_LSR & 0x20u))
        if (!--timeout)
            return;
    SIU_THR = (uint8_t)c;
}

static void uart_puts(const char *s)
{
    while (*s) {
        if (*s == '\n')
            uart_putc('\r');
        uart_putc(*s);
        s++;
    }
}

static void uart_puthex32(uint32_t v)
{
    static const char hex[] = "0123456789ABCDEF";
    for (int i = 28; i >= 0; i -= 4)
        uart_putc(hex[(v >> i) & 0xFu]);
}

static void nand_wait_ready(void)
{
    unsigned int timeout = 1000000;
    while (!(XFER_STATUS & 1u))
        if (!--timeout) {
            uart_puts("SPL: NAND transfer timed out\n");
            for (;;)
                ; /* Do not jump into a partly loaded kernel. */
        }
}

/*
 * Read one 512-byte NAND page into `dest` (4-byte aligned). The 16 trailing
 * OOB bytes from the raw page stream are discarded. `page` is the
 * absolute page index (0-based, 32 pages/block, 1024 blocks total).
 */
static void nand_read_page(uint32_t page, uint32_t *dest)
{
    /* WinCE SPL 80F0A654..64: select clock/unit and PIO explicitly. */
    *(volatile uint32_t *)0xAA001134u = 1;
    *(volatile uint32_t *)0xAA00A400u = 1;
    *(volatile uint32_t *)0xAA00A408u = 1;
    *(volatile uint32_t *)0xAA00A40Cu = 1;
    *(volatile uint32_t *)0xAA00A410u = 1;
    /* Command phase: close, READ0, commit, close (80F0AD34..4C). */
    XFER_CMD = 0x02u;
    XFER_CMD = 0x03u;
    XFER_ADDR8 = 0x00u;
    (void)XFER_ACK;
    XFER_CMD = 0x02u;
    nand_wait_ready();

    /* Small-page NAND address: column, page low, page high. */
    XFER_CMD = 0x06u;
    XFER_ADDR8 = 0x00u;                              /* col_lo = 0 (start of page) */
    XFER_ADDR8 = (uint8_t)(page & 0xFFu);            /* row byte 0 (page lo) */
    XFER_ADDR8 = (uint8_t)((page >> 8) & 0xFFu);     /* row byte 1 (page hi) */
    (void)XFER_ACK;
    XFER_CMD = 0x02u;
    nand_wait_ready();

    /* Start the recovered PIO raw-page read transaction. */
    XFER_KICK = 1u;
    XFER_MODE = 0x05u;

    nand_wait_ready();

    /* 128 4-byte reads = 512 data bytes. */
    for (int i = 0; i < 128; i++)
        dest[i] = STREAM_DATA;
    /* Drain the whole spare area as the ROM (9FC01A98-1AAE) and Casio's SPL
     * do: after the ROM's NAND boot a MODE-5 burst ends at 520 bytes, and
     * on a real BE-300 a further read hangs the bus for good (glaze-os
     * docs/NAND_BOOT_AUDIT.md). MODE 4 streams the last 8 spare bytes. */
    dest[128] = STREAM_DATA;
    dest[129] = STREAM_DATA;
    XFER_MODE = 0x04u;
    nand_wait_ready();
    dest[130] = STREAM_DATA;
    dest[131] = STREAM_DATA;
    XFER_MODE = 0;
    XFER_CMD = 0;
    *(volatile uint32_t *)0xAA00A410u = 0;
}

static struct nand_boot_map boot_map;

static int read_raw(void *ctx, uint32_t page, uint8_t raw[528])
{
    (void)ctx;
    nand_read_page(page, (uint32_t *)raw);
    return 0;
}

static void __attribute__((noreturn)) boot_fail(const char *reason)
{
    uart_puts(reason);
    for (;;) ;
}

/* Match the stock SPL's cold NAND handoff before touching DMA state. */
static void nand_cold_init(void)
{
    static const uint16_t gates[] = {
        0x1128, 0x1100, 0x110c, 0x1104, 0x1108,
        0x1120, 0x112c, 0x1138, 0x113c
    };
    for (unsigned i = 0; i < sizeof(gates) / sizeof(gates[0]); i++)
        *(volatile uint32_t *)(0xaa000000u + gates[i]) = 1;
    *(volatile uint32_t *)0xaa00a0dcu = 0xff;
    *(volatile uint32_t *)0xaa001134u = 1;
    *(volatile uint32_t *)0xaa00a400u = 0;
    *(volatile uint32_t *)0xaa001cc0u = 0;
    *(volatile uint32_t *)0xaa00a400u = 1;
    *(volatile uint32_t *)0xaa00a408u = 1;
    *(volatile uint32_t *)0xaa00a40cu = 1;
    *(volatile uint32_t *)0xaa00a410u = 1;
    XFER_MODE = 0;
    XFER_CMD = 2;
    XFER_CMD = 3;
    XFER_ADDR8 = 0xff; /* RESET */
    (void)XFER_ACK;
    XFER_CMD = 2;
    nand_wait_ready();
}

#ifdef BE300_SPL_DIAG
/* DIAGNOSTIC: light the panel from the SPL and paint numbered bands so a
 * hang before the kernel's own LCD init is visible (see docs/HARDWARE.md). */
typedef uint32_t u32;
#define BE300_R32(pa) (*(volatile uint32_t *)(0xa0000000u | (pa)))
#define BE300_W32(pa, v) (*(volatile uint32_t *)(0xa0000000u | (pa)) = (v))
#define BE300_R16(pa) (*(volatile uint16_t *)(0xa0000000u | (pa)))
#define BE300_W16(pa, v) (*(volatile uint16_t *)(0xa0000000u | (pa)) = (v))
static void spl_delay(unsigned int us)
{
    for (volatile unsigned int i = 0; i < us * 40u; i++) ;
}
#define BE300_DELAY(us) spl_delay(us)
#include "hardware-regs.h"
static void diag_mark(unsigned int n)
{
    static const uint16_t colors[] = {
        0xf800, 0xffe0, 0x07e0, 0x07ff, 0x001f, 0xf81f, 0xffff, 0xfc00
    };
    volatile uint16_t *fb = (volatile uint16_t *)0xaa200000u;
    for (unsigned int y = n * 12; y < n * 12 + 10; y++)
        for (unsigned int x = 0; x < 240; x++)
            fb[y * 256 + x] = x < 8 * (n + 1) ? 0xffff : colors[n % 8];
}
static void diag_lcd_on(void)
{
    be300_regs_power_on();
    BE300_W32(0x0a001100, 1);
    BE300_W32(0x0a00110c, 1);
    be300_regs_lcd_init();
    be300_regs_brightness(5);
    volatile uint16_t *fb = (volatile uint16_t *)0xaa200000u;
    for (unsigned int i = 0; i < 320 * 256; i++) fb[i] = 0;
    diag_mark(0);
}
#else
#define diag_lcd_on() do { } while (0)
#define diag_mark(n) do { } while (0)
#endif

uint32_t spl_main(void)
{
    uart_puts("\nBE-300 stage-1 SPL\n");
    uart_puts("kernel load = 0x");
    uart_puthex32(KERNEL_LOAD_VA);
    uart_puts(", entry = 0x");
    uart_puthex32(KERNEL_ENTRY_VA);
    uart_puts(", size = 0x");
    uart_puthex32(KERNEL_SIZE);
    uart_puts("\n");

    uint32_t pages = (KERNEL_SIZE + NAND_PAGE_DATA - 1u) / NAND_PAGE_DATA;
    uint32_t start_page = KERNEL_NAND_OFFSET / NAND_PAGE_DATA;

    /* Write through the uncached KSEG1 alias so the data is visible to the
     * cached kernel-entry fetch without an explicit cache flush. */
    uint32_t *dst = (uint32_t *)((KERNEL_LOAD_VA & 0x1FFFFFFFu) | 0xA0000000u);

    nand_cold_init();
    diag_lcd_on();
    if (nand_boot_scan(&boot_map, read_raw, 0, true))
        boot_fail("SPL: ambiguous NAND boot map\n");
    if (boot_map.protected) {
        uint8_t manifest[512] __attribute__((aligned(4)));
        if (nand_boot_read(&boot_map, read_raw, 0, 1, manifest, false) ||
            nand_boot_manifest_valid(manifest))
            boot_fail("SPL: invalid physical NAND manifest\n");
    }
    diag_mark(1);
    for (uint32_t i = 0; i < pages; i++) {
        if (nand_boot_read(&boot_map, read_raw, 0, start_page + i, dst, true))
            boot_fail("SPL: missing or corrupt kernel page\n");
        dst += NAND_PAGE_DATA / 4;
    }

    diag_mark(2);
    uart_puts("kernel loaded; jumping\n");
    return KERNEL_ENTRY_VA;
}
