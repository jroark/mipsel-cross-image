/*
 * test_dyn_full.cpp — link against EVERY library qpe links against,
 * but with an empty main().  If qpe's pre-main SIGSEGV is in one
 * of the Opie libraries' .init / global constructors, this binary
 * will reproduce the crash before main() is reached.
 *
 * NEEDED chain mirrors qpe:
 *   libqpe.so.1
 *   libopiecore2.so.1
 *   libopieui2.so.1
 *   libopiesecurity2.so.0
 *   libopiepim2.so.1
 *   libqte.so.2
 *   libc.so.0
 */
#include <stdio.h>
#include <string.h>
#include <unistd.h>

/* Linker -Wl,--no-as-needed forces each -l into NEEDED even if no
 * symbol is referenced.  That makes the dynamic loader run each
 * library's .init / global ctors at process startup, exactly as
 * for qpe.  No explicit symbol references required. */

int main(int argc, char **argv)
{
	const char *msg = "[test_dyn_full] main entered\n";
	write(2, msg, strlen(msg));
	return 0;
}
