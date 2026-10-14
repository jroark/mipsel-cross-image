/*
 * Soft-float ABI entry points for the uClibc-ng (-msoft-float) profile.
 *
 * The Debian mipsel cross toolchain only ships a hard-float libgcc.  Its
 * __adddf3, __floatsidf, __fixdfsi, ... members are one-instruction
 * hard-float wrappers (e.g. `add.d $f0,$f12,$f14`) that take and return
 * values in FPU registers.  Soft-float code passes doubles in a0..a3 and
 * expects results in v0/v1, so every double/float operation in a
 * soft-float binary returned garbage: QImageSmoothScaler computed a zero
 * row step and spun forever, and uClibc's printf/strtod paths were wrong.
 *
 * These replacements keep the soft-float calling convention by taking and
 * returning the raw IEEE bits as integers, and do the arithmetic with FPU
 * instructions.  VR4131 has no FPU, so the kernel's FPU emulator executes
 * them -- the same path the -mfpxx musl profile already depends on.
 *
 * Build with -mhard-float -mfp32; integer-typed signatures mean the
 * hard-float compile still uses the integer argument/return registers.
 * Double <-> 64-bit integer conversions stay in libgcc_helpers.c (built
 * soft-float), so nothing here may cast between double and long long.
 */

typedef unsigned long long U64;
typedef unsigned int       U32;
typedef int                S32;

static inline double d_of(U64 x)
{
	union { U64 u; double d; } v;

	v.u = x;
	return v.d;
}

static inline U64 u_of_d(double x)
{
	union { U64 u; double d; } v;

	v.d = x;
	return v.u;
}

static inline float f_of(U32 x)
{
	union { U32 u; float f; } v;

	v.u = x;
	return v.f;
}

static inline U32 u_of_f(float x)
{
	union { U32 u; float f; } v;

	v.f = x;
	return v.u;
}

U64 __adddf3(U64 a, U64 b) { return u_of_d(d_of(a) + d_of(b)); }
U64 __subdf3(U64 a, U64 b) { return u_of_d(d_of(a) - d_of(b)); }
U64 __muldf3(U64 a, U64 b) { return u_of_d(d_of(a) * d_of(b)); }
U64 __divdf3(U64 a, U64 b) { return u_of_d(d_of(a) / d_of(b)); }
U64 __negdf2(U64 a)        { return a ^ ((U64)1 << 63); }

U32 __addsf3(U32 a, U32 b) { return u_of_f(f_of(a) + f_of(b)); }
U32 __subsf3(U32 a, U32 b) { return u_of_f(f_of(a) - f_of(b)); }
U32 __mulsf3(U32 a, U32 b) { return u_of_f(f_of(a) * f_of(b)); }
U32 __divsf3(U32 a, U32 b) { return u_of_f(f_of(a) / f_of(b)); }
U32 __negsf2(U32 a)        { return a ^ 0x80000000u; }

U64 __extendsfdf2(U32 a) { return u_of_d((double)f_of(a)); }
U32 __truncdfsf2(U64 a)  { return u_of_f((float)d_of(a)); }

S32 __fixdfsi(U64 a) { return (S32)d_of(a); }
S32 __fixsfsi(U32 a) { return (S32)f_of(a); }

/*
 * Compare on the IEEE bits, not with c.cond/bc1f: Linux 2.4.18's FPU
 * emulator mishandles FP branches (it runs their delay slot from a stack
 * trampoline), which returned garbage or raised SIGILL.  Keep every shim
 * free of FP-conditional branches.  0x41e00000_00000000 is 2^31 as a
 * double and 0x4f000000 is 2^31 as a float; positive values order like
 * their bit patterns.
 */
U32 __fixunsdfsi(U64 a)
{
	if ((a >> 63) || a < 0x41e0000000000000ULL)
		return (U32)(S32)d_of(a);
	return (U32)(S32)(d_of(a) - 2147483648.0) + 0x80000000u;
}

U32 __fixunssfsi(U32 a)
{
	if ((a >> 31) || a < 0x4f000000u)
		return (U32)(S32)f_of(a);
	return (U32)(S32)(f_of(a) - 2147483648.0f) + 0x80000000u;
}

U64 __floatsidf(S32 i) { return u_of_d((double)i); }
U32 __floatsisf(S32 i) { return u_of_f((float)i); }

U64 __floatunsidf(U32 i)
{
	double d = (double)(S32)(i & 0x7fffffffu);

	if (i & 0x80000000u)
		d += 2147483648.0;
	return u_of_d(d);
}

U32 __floatunsisf(U32 i)
{
	/* Round once, through double. */
	double d = (double)(S32)(i & 0x7fffffffu);

	if (i & 0x80000000u)
		d += 2147483648.0;
	return u_of_f((float)d);
}

U64 __powidf2(U64 a, S32 m)
{
	double x = d_of(a);
	double r = (m % 2) ? x : 1.0;
	U32 n = m < 0 ? -(U32)m : (U32)m;

	while (n >>= 1) {
		x = x * x;
		if (n % 2)
			r = r * x;
	}
	return u_of_d(m < 0 ? 1.0 / r : r);
}

U32 __powisf2(U32 a, S32 m)
{
	float x = f_of(a);
	float r = (m % 2) ? x : 1.0f;
	U32 n = m < 0 ? -(U32)m : (U32)m;

	while (n >>= 1) {
		x = x * x;
		if (n % 2)
			r = r * x;
	}
	return u_of_f(m < 0 ? 1.0f / r : r);
}
