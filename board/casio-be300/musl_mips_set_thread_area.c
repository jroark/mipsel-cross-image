#include "pthread_impl.h"

uintptr_t __be300_mips_tp;

int __set_thread_area(void *p)
{
	__be300_mips_tp = (uintptr_t)p;
#ifdef SYS_set_thread_area
	return __syscall(SYS_set_thread_area, p);
#else
	return 0;
#endif
}
