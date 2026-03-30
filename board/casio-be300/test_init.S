/*
 * Minimal /init for BE300 — pure MIPS-I assembly, no libc.
 * Mounts proc/sys/devtmpfs, prints a welcome message, then loops.
 *
 * Build: mipsel-linux-gnu-gcc -nostdlib -static -march=mips1 -mfp32
 *        -mabi=32 -mno-abicalls -fno-pic -o init test_init.S
 */
	.set	noreorder
	.text
	.globl	__start
	.type	__start, @function

/* Linux o32 syscall numbers */
#define __NR_write	4004
#define __NR_mount	4021
#define __NR_pause	4029
#define __NR_mkdir	4039

__start:
	/* mkdir /proc */
	li	$v0, __NR_mkdir
	la	$a0, str_proc
	li	$a1, 0755
	syscall
	nop

	/* mount -t proc proc /proc */
	li	$v0, __NR_mount
	la	$a0, str_proc
	la	$a1, str_proc
	la	$a2, str_procfs
	li	$a3, 0
	/* 5th arg on stack: NULL */
	addiu	$sp, $sp, -16
	sw	$zero, 16($sp)
	syscall
	nop
	addiu	$sp, $sp, 16

	/* mkdir /sys */
	li	$v0, __NR_mkdir
	la	$a0, str_sys
	li	$a1, 0755
	syscall
	nop

	/* mount -t sysfs sysfs /sys */
	li	$v0, __NR_mount
	la	$a0, str_sysfs
	la	$a1, str_sys
	la	$a2, str_sysfs
	li	$a3, 0
	addiu	$sp, $sp, -16
	sw	$zero, 16($sp)
	syscall
	nop
	addiu	$sp, $sp, 16

	/* mount -t devtmpfs devtmpfs /dev */
	li	$v0, __NR_mount
	la	$a0, str_devtmpfs
	la	$a1, str_dev
	la	$a2, str_devtmpfs
	li	$a3, 0
	addiu	$sp, $sp, -16
	sw	$zero, 16($sp)
	syscall
	nop
	addiu	$sp, $sp, 16

	/* write(1, welcome_msg, len) */
	li	$v0, __NR_write
	li	$a0, 1
	la	$a1, welcome_msg
	li	$a2, welcome_len
	syscall
	nop

	/* Loop: pause() forever */
1:	li	$v0, __NR_pause
	syscall
	nop
	b	1b
	nop

	.data
str_proc:	.asciz	"/proc"
str_procfs:	.asciz	"proc"
str_sys:	.asciz	"/sys"
str_sysfs:	.asciz	"sysfs"
str_dev:	.asciz	"/dev"
str_devtmpfs:	.asciz	"devtmpfs"
welcome_msg:	.ascii	"\n=== Casio BE-300 Linux 4.2.9 ===\n"
		.ascii	"Userspace reached! No libc.\n"
welcome_len = . - welcome_msg
