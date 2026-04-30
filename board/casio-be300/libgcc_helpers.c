/*
 * libgcc helper replacements for VR4131 (MIPS II / III).
 *
 * GCC's libgcc.a is built with -march=mips32r2 and uses the SPECIAL2
 * `mul rd, rs, rt` instruction, which does not exist in MIPS III.
 * VR4131 raises Reserved Instruction on encountering it.
 *
 * These are C reimplementations of the 64-bit division helpers. When
 * compiled with -march=mips2, GCC uses mult/mflo/mfhi only, which run
 * correctly on VR4131.
 *
 * Linked into BusyBox via EXTRA_CFLAGS / extra object to shadow the
 * libgcc versions. (The .c file is appended to libbb/lib.a at build
 * time, so the linker prefers these over libgcc's.)
 */

typedef long long          DI;
typedef unsigned long long UDI;
typedef int                SI;
typedef unsigned int       USI;

/* Compute unsigned 64-bit division and remainder via schoolbook shift/sub. */
static UDI __udivmoddi4(UDI num, UDI den, UDI *rem)
{
	UDI quot = 0;
	UDI qbit = 1;

	if (den == 0) {
		/* divide-by-zero: return 0 (like libgcc's behavior on MIPS) */
		if (rem) *rem = 0;
		return 0;
	}

	/* Left-justify den vs num */
	while ((SI) den >= 0) {
		den <<= 1;
		qbit <<= 1;
		if (qbit == 0)
			break;
	}

	while (qbit) {
		if (den <= num) {
			num -= den;
			quot += qbit;
		}
		den >>= 1;
		qbit >>= 1;
	}

	if (rem) *rem = num;
	return quot;
}

UDI __udivdi3(UDI a, UDI b)
{
	return __udivmoddi4(a, b, 0);
}

UDI __umoddi3(UDI a, UDI b)
{
	UDI r;
	__udivmoddi4(a, b, &r);
	return r;
}

DI __divdi3(DI a, DI b)
{
	int neg = 0;
	UDI r;
	if (a < 0) { a = -a; neg ^= 1; }
	if (b < 0) { b = -b; neg ^= 1; }
	r = __udivmoddi4((UDI)a, (UDI)b, 0);
	return neg ? -(DI)r : (DI)r;
}

DI __moddi3(DI a, DI b)
{
	int neg = 0;
	UDI r;
	if (a < 0) { a = -a; neg = 1; }
	if (b < 0) { b = -b; }
	__udivmoddi4((UDI)a, (UDI)b, &r);
	return neg ? -(DI)r : (DI)r;
}

/* 64-bit shifts — GCC with -march=mips2 compiles these to mips2-only ops */
UDI __ashldi3(UDI a, int b) { return a << b; }
UDI __lshrdi3(UDI a, int b) { return a >> b; }
DI  __ashrdi3(DI a, int b)  { return a >> b; }
DI  __negdi2(DI a)          { return -a; }

/* float<->int conversions pull in mul on mips32r2; provide C versions */
DI __fixdfdi(double d)              { return (DI)d; }
UDI __fixunsdfdi(double d)          { return (UDI)d; }
double __floatdidf(DI i)            { return (double)i; }
double __floatundidf(UDI i)         { return (double)i; }

SI __clzsi2(USI x)
{
	SI n = 0;
	USI bit = 0x80000000u;

	if (!x)
		return 32;
	while (!(x & bit)) {
		n++;
		bit >>= 1;
	}
	return n;
}

SI __ctzsi2(USI x)
{
	SI n = 0;

	if (!x)
		return 32;
	while (!(x & 1u)) {
		n++;
		x >>= 1;
	}
	return n;
}

SI __popcountsi2(USI x)
{
	SI n = 0;

	while (x) {
		n += x & 1u;
		x >>= 1;
	}
	return n;
}

SI __paritysi2(USI x)
{
	return __popcountsi2(x) & 1;
}

SI __ffssi2(USI x)
{
	SI n = 1;

	if (!x)
		return 0;
	while (!(x & 1u)) {
		n++;
		x >>= 1;
	}
	return n;
}

SI __clzdi2(UDI x)
{
	SI n = 0;
	UDI bit = (UDI)1 << 63;

	if (!x)
		return 64;
	while (!(x & bit)) {
		n++;
		bit >>= 1;
	}
	return n;
}

SI __ctzdi2(UDI x)
{
	SI n = 0;

	if (!x)
		return 64;
	while (!(x & 1u)) {
		n++;
		x >>= 1;
	}
	return n;
}

SI __popcountdi2(UDI x)
{
	SI n = 0;

	while (x) {
		n += x & 1u;
		x >>= 1;
	}
	return n;
}

SI __paritydi2(UDI x)
{
	return __popcountdi2(x) & 1;
}

SI __ffsdi2(UDI x)
{
	SI n = 1;

	if (!x)
		return 0;
	while (!(x & 1u)) {
		n++;
		x >>= 1;
	}
	return n;
}
