/*
 * test_dyn_qte.cpp — minimal C++ program linked against libqte.so.
 *
 * libqte has Qt/Embedded global static objects that run constructors
 * at .init time.  If qpe's pre-main SIGSEGV is in libqte's static
 * init, this minimal binary linked against libqte will crash exactly
 * the same way before reaching main().
 *
 * Build wires this against $QPEDIR/lib/libqte.so.2 with -ldl so we
 * pull in libqte's global ctors.  Empty main() — the crash (if any)
 * happens before we get here.
 */
#include <stdio.h>
#include <string.h>
#include <unistd.h>

/* Pull in libqte by referencing an exported symbol via extern "C".
 * The symbol exists in libqte.so.2 (we just need a single relocation
 * to force libqte to load). */
extern "C" int qDebug(const char *, ...);

int main(int argc, char **argv)
{
	const char *msg = "[test_dyn_qte] main entered\n";
	write(2, msg, strlen(msg));
	return 0;
}
