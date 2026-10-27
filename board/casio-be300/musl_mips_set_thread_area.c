#include "pthread_impl.h"
#include <errno.h>

uintptr_t __be300_mips_tp;

int __set_thread_area(void *p)
{
	__be300_mips_tp = (uintptr_t)p;
#ifdef SYS_set_thread_area
	/* Older kernels lack this syscall. The BE-300 single-threaded libc
	 * already reads the process-local pointer above instead of RDHWR.
	 */
	long ret = __syscall(SYS_set_thread_area, p);
	return ret == -ENOSYS ? 0 : ret;
#else
	return 0;
#endif
}
