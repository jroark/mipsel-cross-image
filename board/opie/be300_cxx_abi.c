/*
 * Minimal C++ ABI support for BE-300 Qt/Embedded and OPIE builds.
 *
 * The distro MIPS libstdc++/libsupc++ archives are built for mips32r2 and
 * contain SPECIAL2 instructions that trap on the VR4131.  Qt 2/OPIE are built
 * without exceptions, RTTI, or the C++ standard library, so the remaining ABI
 * surface is small enough to provide locally.
 */
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

void *__dso_handle __attribute__((weak));

static void *be300_alloc(size_t size)
{
	void *p;

	if (!size)
		size = 1;
	p = malloc(size);
	if (!p)
		abort();
	return p;
}

void *be300_operator_new(size_t size) __asm__("_Znwj") __attribute__((weak));
void *be300_operator_new(size_t size)
{
	return be300_alloc(size);
}

void *be300_operator_new_array(size_t size) __asm__("_Znaj") __attribute__((weak));
void *be300_operator_new_array(size_t size)
{
	return be300_alloc(size);
}

void be300_operator_delete(void *p) __asm__("_ZdlPv") __attribute__((weak));
void be300_operator_delete(void *p)
{
	free(p);
}

void be300_operator_delete_array(void *p) __asm__("_ZdaPv") __attribute__((weak));
void be300_operator_delete_array(void *p)
{
	free(p);
}

void be300_operator_delete_sized(void *p, size_t size) __asm__("_ZdlPvj") __attribute__((weak));
void be300_operator_delete_sized(void *p, size_t size)
{
	(void)size;
	free(p);
}

void be300_operator_delete_array_sized(void *p, size_t size) __asm__("_ZdaPvj") __attribute__((weak));
void be300_operator_delete_array_sized(void *p, size_t size)
{
	(void)size;
	free(p);
}

int __cxa_atexit(void (*func)(void *), void *arg, void *dso)
{
	(void)func;
	(void)arg;
	(void)dso;
	return 0;
}

void __cxa_finalize(void *dso)
{
	(void)dso;
}

int __cxa_guard_acquire(uint64_t *guard)
{
	return !(*(volatile unsigned char *)guard);
}

void __cxa_guard_release(uint64_t *guard)
{
	*(volatile unsigned char *)guard = 1;
}

void __cxa_guard_abort(uint64_t *guard)
{
	(void)guard;
}

void __cxa_pure_virtual(void) __attribute__((weak));
void __cxa_pure_virtual(void)
{
	abort();
}

void __cxa_deleted_virtual(void) __attribute__((weak));
void __cxa_deleted_virtual(void)
{
	abort();
}

void __gxx_personality_v0(void) __attribute__((weak));
void __gxx_personality_v0(void)
{
}
