/* Linker script for the BE-300 stage-1 SPL.
 * The boot ROM places the SPL at SDRAM 0x80F00000 and `jr`s to 0x80F00004.
 */

OUTPUT_FORMAT("elf32-tradlittlemips")
OUTPUT_ARCH(mips)
ENTRY(_start)

SECTIONS {
    . = 0x80F00000;
    .text : {
        *(.text._start)
        *(.text)
        *(.text.*)
    }
    .rodata : {
        *(.rodata)
        *(.rodata.*)
    }
    .data : {
        *(.data)
        *(.data.*)
    }
    /* The B000FF container carries file-backed bytes only, so spl_start.S
     * zeroes this range itself (RAM still holds the previous OS's data). */
    .bss : {
        . = ALIGN(4);
        __bss_start = .;
        *(.bss)
        *(.bss.*)
        *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    }
    /DISCARD/ : {
        *(.reginfo)
        *(.MIPS.abiflags)
        *(.gnu.attributes)
        *(.note.gnu.build-id)
        *(.note.GNU-stack)
        *(.eh_frame)
        *(.pdr)
        *(.mdebug.abi32)
    }
}
