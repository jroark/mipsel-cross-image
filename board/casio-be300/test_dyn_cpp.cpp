/*
 * test_dyn_cpp.cpp — minimal dynamic-link C++ test with global
 * constructors.  Bisects whether qpe's pre-main SIGSEGV is general
 * to C++ static-init on 2.4.18 + BE-300, or specific to Qt/Opie
 * code paths.
 *
 * Three global constructors of increasing complexity:
 *   - A POD: just a value
 *   - A class with constructor that prints via stdio
 *   - A class with constructor that does string operations + fprintf
 */
#include <stdio.h>
#include <string.h>
#include <unistd.h>

class CtorPrint {
public:
	CtorPrint(const char *name) {
		const char *prefix = "[ctor-print] ";
		::write(2, prefix, 13);
		::write(2, name, strlen(name));
		::write(2, "\n", 1);
	}
};

class CtorFprintf {
public:
	CtorFprintf(const char *name) {
		fprintf(stderr, "[ctor-fprintf] %s\n", name);
		fflush(stderr);
	}
};

class CtorComplex {
public:
	CtorComplex() {
		char buf[64];
		snprintf(buf, sizeof(buf), "complex-init pid=%d", (int)getpid());
		fprintf(stderr, "[ctor-complex] %s\n", buf);
		fflush(stderr);
	}
};

/* Three global objects with constructors that run BEFORE main(). */
static CtorPrint    g_a("global-A direct-write");
static CtorFprintf  g_b("global-B fprintf");
static CtorComplex  g_c;

int main(int argc, char **argv)
{
	fprintf(stderr, "[test_dyn_cpp] main entered argc=%d\n", argc);
	fflush(stderr);
	return 0;
}
