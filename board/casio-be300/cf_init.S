	.set	noreorder
	.set	noat
	.text
	.globl	_start
	.ent	_start

/*
 * Minimal CF-root init for the BE-300 recovery bootstrap.
 *
 * BusyBox init can block before a visible prompt on the emulator's serial
 * console path. This PID 1 keeps the CF boot path simple: mount the basic
 * pseudo-filesystems, print a banner, then exec BusyBox ash interactively.
 */

#define __NR_exit	4001
#define __NR_write	4004
#define __NR_open	4005
#define __NR_execve	4011
#define __NR_mount	4021
#define __NR_pause	4029
#define __NR_mkdir	4039
#define __NR_dup2	4063

_start:
	addiu	$sp, $sp, -64

	/*
	 * Kernel-provided init fds are not consistently visible through the
	 * emulator console. Open the framebuffer VT directly so the BusyBox
	 * prompt appears on the BE-300 LCD path used by Microwindows.
	 */
	li	$v0, __NR_open
	la	$a0, s_tty0
	li	$a1, 0x882		/* O_RDWR | O_NONBLOCK | O_NOCTTY */
	li	$a2, 0
	syscall
	nop
	bnez	$a3, 1f
	nop
	move	$s0, $v0
	li	$v0, __NR_dup2
	move	$a0, $s0
	li	$a1, 0
	syscall
	nop
	li	$v0, __NR_dup2
	move	$a0, $s0
	li	$a1, 1
	syscall
	nop
	li	$v0, __NR_dup2
	move	$a0, $s0
	li	$a1, 2
	syscall
	nop
1:

	li	$v0, __NR_write
	li	$a0, 1
	la	$a1, msg_banner
	li	$a2, msg_banner_len
	syscall
	nop

	li	$v0, __NR_mkdir
	la	$a0, s_proc
	li	$a1, 493		/* 0755 */
	syscall
	nop
	li	$v0, __NR_mkdir
	la	$a0, s_sys
	li	$a1, 493		/* 0755 */
	syscall
	nop
	li	$v0, __NR_mkdir
	la	$a0, s_tmp
	li	$a1, 511		/* 0777 */
	syscall
	nop

	/* mount(source, target, fstype, flags, data). 5th arg is on stack. */
	sw	$zero, 16($sp)
	li	$v0, __NR_mount
	la	$a0, s_procfs
	la	$a1, s_proc
	la	$a2, s_procfs
	move	$a3, $zero
	syscall
	nop

	sw	$zero, 16($sp)
	li	$v0, __NR_mount
	la	$a0, s_sysfs
	la	$a1, s_sys
	la	$a2, s_sysfs
	move	$a3, $zero
	syscall
	nop

	sw	$zero, 16($sp)
	li	$v0, __NR_mount
	la	$a0, s_tmpfs
	la	$a1, s_tmp
	la	$a2, s_tmpfs
	move	$a3, $zero
	syscall
	nop

	li	$v0, __NR_write
	li	$a0, 1
	la	$a1, msg_ready
	li	$a2, msg_ready_len
	syscall
	nop

	li	$v0, __NR_execve
	la	$a0, s_sh
	la	$a1, argv_sh
	la	$a2, envp
	syscall
	nop

	li	$v0, __NR_write
	li	$a0, 1
	la	$a1, msg_exec_fail
	li	$a2, msg_exec_fail_len
	syscall
	nop

hang:
	li	$v0, __NR_pause
	syscall
	nop
	b	hang
	nop

	.end	_start

	.data
	.align	2
msg_banner:
	.ascii	"\n=== Casio BE-300 CF Linux 4.2.9 ===\n"
	.ascii	"rootfs: /dev/sda2 ext2\n"
msg_banner_len = . - msg_banner

msg_ready:
	.ascii	"BusyBox shell ready. Run /bin/start-microwindows for Nano-X.\n\n"
msg_ready_len = . - msg_ready

msg_exec_fail:
	.ascii	"ERROR: exec /bin/sh failed\n"
msg_exec_fail_len = . - msg_exec_fail

s_tty0:		.asciz	"/dev/tty0"
s_proc:		.asciz	"/proc"
s_sys:		.asciz	"/sys"
s_tmp:		.asciz	"/tmp"
s_procfs:	.asciz	"proc"
s_sysfs:	.asciz	"sysfs"
s_tmpfs:	.asciz	"tmpfs"
s_sh:		.asciz	"/bin/sh"
s_arg0:		.asciz	"sh"
s_arg_i:	.asciz	"-i"
s_env_home:	.asciz	"HOME=/"
s_env_path:	.asciz	"PATH=/bin:/sbin:/usr/bin:/usr/sbin"
s_env_shell:	.asciz	"SHELL=/bin/sh"
s_env_term:	.asciz	"TERM=vt102"
s_env_ps1:	.asciz	"PS1=be300-cf# "

	.align	2
argv_sh:	.word	s_arg0, s_arg_i, 0
envp:		.word	s_env_home, s_env_path, s_env_shell, s_env_term, s_env_ps1, 0
