/*
 * libgcc helper replacements for VR4131 (MIPS II / III).
 *
 * GCC's libgcc.a is built with -march=mips32r2 and uses the SPECIAL2
 * `mul rd, rs, rt` instruction, which does not exist in MIPS III.
 * VR4131 raises Reserved Instruction on encountering it.
 *
 * These are C reimplementations of the 64-bit integer helpers and libgcc
 * float/double comparison helpers. The stock comparison helpers use MIPS32
 * conditional moves (`movf`/`movt`), which also trap on this target.
 * When compiled with -march=mips2, GCC uses instructions that run correctly
 * on VR4131.
 *
 * Linked into BusyBox via EXTRA_CFLAGS / extra object to shadow the
 * libgcc versions. (The .c file is appended to libbb/lib.a at build
 * time, so the linker prefers these over libgcc's.)
 */

typedef long long          DI;
typedef unsigned long long UDI;
typedef int                SI;
typedef unsigned int       USI;

#define SF_SIGN 0x80000000u
#define SF_EXP  0x7f800000u
#define SF_FRAC 0x007fffffu
#define DF_SIGN ((UDI)1 << 63)
#define DF_EXP  ((UDI)0x7ff << 52)
#define DF_FRAC ((((UDI)1) << 52) - 1)

static USI sf_bits(float f)
{
	union {
		float f;
		USI u;
	} v;

	v.f = f;
	return v.u;
}

static UDI df_bits(double d)
{
	union {
		double d;
		UDI u;
	} v;

	v.d = d;
	return v.u;
}

static int sf_unordered_bits(USI a, USI b)
{
	return ((a & SF_EXP) == SF_EXP && (a & SF_FRAC)) ||
	       ((b & SF_EXP) == SF_EXP && (b & SF_FRAC));
}

static int df_unordered_bits(UDI a, UDI b)
{
	return ((a & DF_EXP) == DF_EXP && (a & DF_FRAC)) ||
	       ((b & DF_EXP) == DF_EXP && (b & DF_FRAC));
}

static int sf_equal_bits(USI a, USI b)
{
	if (sf_unordered_bits(a, b))
		return 0;
	if ((a & ~SF_SIGN) == 0 && (b & ~SF_SIGN) == 0)
		return 1;
	return a == b;
}

static int df_equal_bits(UDI a, UDI b)
{
	if (df_unordered_bits(a, b))
		return 0;
	if ((a & ~DF_SIGN) == 0 && (b & ~DF_SIGN) == 0)
		return 1;
	return a == b;
}

static int sf_less_bits(USI a, USI b)
{
	int sa, sb;

	if (sf_unordered_bits(a, b) || sf_equal_bits(a, b))
		return 0;
	sa = (a & SF_SIGN) != 0;
	sb = (b & SF_SIGN) != 0;
	if (sa != sb)
		return sa;
	if (!sa)
		return (a & ~SF_SIGN) < (b & ~SF_SIGN);
	return (a & ~SF_SIGN) > (b & ~SF_SIGN);
}

static int df_less_bits(UDI a, UDI b)
{
	int sa, sb;

	if (df_unordered_bits(a, b) || df_equal_bits(a, b))
		return 0;
	sa = (a & DF_SIGN) != 0;
	sb = (b & DF_SIGN) != 0;
	if (sa != sb)
		return sa;
	if (!sa)
		return (a & ~DF_SIGN) < (b & ~DF_SIGN);
	return (a & ~DF_SIGN) > (b & ~DF_SIGN);
}

SI __eqsf2(float a, float b)
{
	return sf_equal_bits(sf_bits(a), sf_bits(b)) ? 0 : 1;
}

SI __nesf2(float a, float b)
{
	return __eqsf2(a, b);
}

SI __gtsf2(float a, float b)
{
	USI ua = sf_bits(a);
	USI ub = sf_bits(b);

	return sf_less_bits(ub, ua) ? 1 : 0;
}

SI __gesf2(float a, float b)
{
	USI ua = sf_bits(a);
	USI ub = sf_bits(b);

	return sf_less_bits(ua, ub) || sf_unordered_bits(ua, ub) ? -1 : 0;
}

SI __ltsf2(float a, float b)
{
	return sf_less_bits(sf_bits(a), sf_bits(b)) ? -1 : 0;
}

SI __lesf2(float a, float b)
{
	USI ua = sf_bits(a);
	USI ub = sf_bits(b);

	return sf_less_bits(ub, ua) || sf_unordered_bits(ua, ub) ? 1 : 0;
}

SI __unordsf2(float a, float b)
{
	return sf_unordered_bits(sf_bits(a), sf_bits(b)) ? 1 : 0;
}

SI __eqdf2(double a, double b)
{
	return df_equal_bits(df_bits(a), df_bits(b)) ? 0 : 1;
}

SI __nedf2(double a, double b)
{
	return __eqdf2(a, b);
}

SI __gtdf2(double a, double b)
{
	UDI ua = df_bits(a);
	UDI ub = df_bits(b);

	return df_less_bits(ub, ua) ? 1 : 0;
}

SI __gedf2(double a, double b)
{
	UDI ua = df_bits(a);
	UDI ub = df_bits(b);

	return df_less_bits(ua, ub) || df_unordered_bits(ua, ub) ? -1 : 0;
}

SI __ltdf2(double a, double b)
{
	return df_less_bits(df_bits(a), df_bits(b)) ? -1 : 0;
}

SI __ledf2(double a, double b)
{
	UDI ua = df_bits(a);
	UDI ub = df_bits(b);

	return df_less_bits(ub, ua) || df_unordered_bits(ua, ub) ? 1 : 0;
}

SI __unorddf2(double a, double b)
{
	return df_unordered_bits(df_bits(a), df_bits(b)) ? 1 : 0;
}

/*
 * libgcc's complex multiply helpers are also built for the host toolchain's
 * MIPS32 target and use MIPS32 bitfield instructions.  Musl pulls these into
 * libc.so for complex math, so provide simple MIPS2-built replacements.
 */
_Complex float __mulsc3(float a, float b, float c, float d)
{
	_Complex float r;

	__real__ r = a * c - b * d;
	__imag__ r = a * d + b * c;
	return r;
}

_Complex double __muldc3(double a, double b, double c, double d)
{
	_Complex double r;

	__real__ r = a * c - b * d;
	__imag__ r = a * d + b * c;
	return r;
}

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

USI __bswapsi2(USI x)
{
	return ((x & 0x000000ffu) << 24) |
	       ((x & 0x0000ff00u) << 8) |
	       ((x & 0x00ff0000u) >> 8) |
	       ((x & 0xff000000u) >> 24);
}

UDI __bswapdi2(UDI x)
{
	return ((UDI)__bswapsi2((USI)x) << 32) |
	       (UDI)__bswapsi2((USI)(x >> 32));
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
