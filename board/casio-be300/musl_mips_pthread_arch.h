static inline uintptr_t __get_tp()
{
	extern uintptr_t __be300_mips_tp;

	return __be300_mips_tp;
}

#define TLS_ABOVE_TP
#define GAP_ABOVE_TP 0

#define TP_OFFSET 0x7000
#define DTP_OFFSET 0x8000

#define MC_PC pc
