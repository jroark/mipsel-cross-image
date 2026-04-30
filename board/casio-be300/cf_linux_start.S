/*
 * CF-resident Linux bootstrap entry for the Casio BE-300 restore path.
 *
 * Linked at 0x80E00000 and packed as /NANDWRITER.bin in B000FF format.
 * The boot ROM's CF recovery loader jumps to 0x80E00004, matching the
 * stock NANDWRITER.bin layout and the NAND SPL's one-instruction veneer.
 */

	.set	noreorder
	.set	noat
	.set	mips2

	.text
	.globl	_start
_start:
	nop
	mtc0	$zero, $12
	mtc0	$zero, $13
	li	$sp, 0x80FF0000
	move	$gp, $zero
	jal	cf_linux_main
	nop
	move	$t0, $v0
	move	$a0, $zero
	move	$a1, $zero
	move	$a2, $zero
	move	$a3, $zero
	jr	$t0
	nop
