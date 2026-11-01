/*
 * Stage-1 SPL entry stub for the BE-300.
 *
 * Linked at 0x80F00000. The boot ROM's record walker loads this binary into
 * SDRAM via the partition-1 B000FF container and `jr`s to 0x80F00004 (the
 * record terminator's entry value). The first 4 bytes are a NOP veneer to
 * mirror the WinCE SPL's record-6 layout.
 */

	.set	noreorder
	.set	noat
	.set	mips2

	.text
	.globl	_start
_start:
	/* 0x80F00000: alignment NOP (boot ROM jumps to +4) */
	nop
	/* 0x80F00004: entry — disable interrupts, set up sp, call C main, jump
	 * to the value spl_main returns. */
	mtc0	$zero, $12        /* CP0 Status: clear all (ERL=0, BEV=stays, IE=0) */
	mtc0	$zero, $13        /* CP0 Cause: clear pending */
	/*
	 * Do not inherit cache state. The boot ROM's I-cache tag loop at
	 * 0xBFC00700 indexes with t0 while it increments a0, so it clears one
	 * line and every other I-cache line survives a reset. After a Glaze RAM
	 * recovery those lines hold its code at the same physical addresses the
	 * kernel is loaded to (0x20000+), and the ROM wrote this SPL through
	 * KSEG1. Flush from the uncached alias, as Glaze's own SPL does
	 * (glaze-os boot/spl_start.S), then return to KSEG0 with clean caches.
	 */
	la	$t0, 1f
	lui	$t1, 0x2000
	or	$t0, $t0, $t1
	jr	$t0
	nop
1:	nop
	nop
	nop
	.set	push
	.set	mips3
	lui	$t0, 0x8000
	ori	$t1, $t0, 0x8000   /* 32 KiB of indexes covers both 16 KiB caches */
2:	cache	0x01, 0($t0)       /* Index_Writeback_Invalidate_D */
	cache	0x00, 0($t0)       /* Index_Invalidate_I */
	addiu	$t0, $t0, 16       /* real VR4131 lines are 16 bytes */
	bne	$t0, $t1, 2b
	nop
	sync
	.set	pop
	/* BSS is not in the container's file-backed segments; RAM still holds
	 * the previous OS's data. nand_ecc.c builds its RS tables only when
	 * exp_t[0] reads zero. Clear it through KSEG1 before any C runs. */
	la	$t0, __bss_start
	la	$t1, __bss_end
	lui	$t2, 0x2000
	or	$t0, $t0, $t2
	or	$t1, $t1, $t2
3:	beq	$t0, $t1, 4f
	nop
	sw	$zero, 0($t0)
	b	3b
	addiu	$t0, $t0, 4
4:	li	$sp, 0x80FF0000   /* stack high in SDRAM, 64 KiB below 16 MiB */
	move	$gp, $zero
	la	$t0, spl_main      /* back to cached KSEG0: RS-checks every page */
	jalr	$t0
	nop
	move	$t0, $v0          /* spl_main returns the kernel entry VA */
	/* MIPS Linux head.S stores a0..a3 to fw_arg0..3 (cmdline argc/argv
	 * etc). The kernel's prom_init then dereferences these. Pass zeros
	 * so the kernel sees "no boot arguments" rather than random pointers
	 * left in the registers by spl_main. */
	move	$a0, $zero
	move	$a1, $zero
	move	$a2, $zero
	move	$a3, $zero
	jr	$t0
	nop
