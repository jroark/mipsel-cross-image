/*
 * Test reading data from the second page of a binary.
 * Uses -Wl,-N (OMAGIC) to ensure single segment.
 * Text starts at 0x400000 (page 0), data is placed at offset 0x1000+
 * (page 1) via .org directive.
 *
 * Build:
 *   mipsel-linux-gnu-gcc -nostdlib -static -march=mips1 -mfp32 \
 *       -mabi=32 -mno-abicalls -fno-pic -Wl,-N \
 *       -o init test_page2.S
 */
	.set	noreorder
	.text
	.globl	__start
	.type	__start, @function

#define __NR_exit	4001
#define __NR_write	4004
#define __NR_pause	4029

__start:
	/* Print "A" = starting */
	li	$v0, __NR_write
	li	$a0, 1
	la	$a1, msg_a
	li	$a2, 2
	syscall
	nop

	/* Read from page 2 data (at .text + 0x1000) */
	la	$t0, page2_magic
	lw	$t1, 0($t0)		/* THIS is the critical test */

	/* Did we get 0xDEADBEEF? */
	lui	$t2, 0xDEAD
	ori	$t2, $t2, 0xBEEF
	bne	$t1, $t2, bad_data
	nop

	/* Success! Print banner then exit 0 */
	li	$v0, __NR_write
	li	$a0, 1
	la	$a1, msg_ok
	li	$a2, msg_ok_len
	syscall
	nop

	/* Exit 0 = success */
	li	$v0, __NR_exit
	li	$a0, 0
	syscall
	nop

bad_data:
	/* Print failure message */
	li	$v0, __NR_write
	li	$a0, 1
	la	$a1, msg_fail
	li	$a2, msg_fail_len
	syscall
	nop

	/* Print the value we actually got, as hex */
	/* t1 still has the value */
	la	$t3, hexbuf
	li	$t4, 7		/* digit counter */
hex_loop:
	srl	$t5, $t1, 28	/* top nibble */
	andi	$t5, $t5, 0xf
	slti	$t6, $t5, 10
	bnez	$t6, hex_digit
	nop
	addiu	$t5, $t5, 0x57	/* 'a' - 10 */
	b	hex_store
	nop
hex_digit:
	addiu	$t5, $t5, 0x30	/* '0' */
hex_store:
	sb	$t5, 0($t3)
	addiu	$t3, $t3, 1
	sll	$t1, $t1, 4
	addiu	$t4, $t4, -1
	bgez	$t4, hex_loop
	nop

	li	$v0, __NR_write
	li	$a0, 1
	la	$a1, msg_val
	li	$a2, msg_val_len
	syscall
	nop

	/* Exit 42 = failure */
	li	$v0, __NR_exit
	li	$a0, 42
	syscall
	nop

hang:
1:	li	$v0, __NR_pause
	syscall
	nop
	b	1b
	nop

	/* Data on page 1 (same as code page) */
msg_a:		.ascii	"A "
msg_ok:		.ascii	"\nPAGE2 READ OK (0xDEADBEEF)\n"
msg_ok_len = . - msg_ok
msg_fail:	.ascii	"\nPAGE2 READ FAILED! Got: 0x"
msg_fail_len = . - msg_fail
msg_val:
hexbuf:		.ascii	"00000000"
		.ascii	"\n"
msg_val_len = . - msg_val

	/* Force data onto the SECOND page */
	.org	0x1000
page2_magic:
	.word	0xDEADBEEF
	.word	0xCAFEBABE
page2_msg:
	.ascii	"This data is on page 2\n"
