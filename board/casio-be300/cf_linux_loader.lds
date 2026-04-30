OUTPUT_ARCH(mips)
ENTRY(_start)

SECTIONS
{
	. = 0x80E00000;

	.text : {
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

	. = ALIGN(16);
	.bss : {
		__bss_start = .;
		*(.bss)
		*(.bss.*)
		*(COMMON)
		__bss_end = .;
	}
}
