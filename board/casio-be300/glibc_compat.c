/*
 * Glibc compatibility shims for static-linking Debian's libstdc++.a (built
 * against glibc) on top of uClibc-ng.
 *
 * Glibc exports many internal symbols with `__name` aliases that libstdc++
 * uses to bypass libc wrappers. uClibc-ng only exports the public names.
 * This file maps the missing aliases through to the public uClibc-ng
 * implementations (or no-ops where the feature isn't supported, e.g.
 * gettext message catalogs).
 *
 * Compile with `-fno-stack-protector` and link statically before
 * libstdc++.a so the linker resolves these references.
 */

#include <stddef.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <locale.h>
#include <wchar.h>
#include <wctype.h>

/* uselocale alias */
locale_t uselocale(locale_t newloc);
locale_t __uselocale(locale_t newloc) { return uselocale(newloc); }

/* gettext stubs — return msgid unchanged, no message catalogs available */
const char *dgettext(const char *domain, const char *msgid)
{
	(void)domain;
	return msgid;
}

const char *gettext(const char *msgid) { return msgid; }

const char *dcgettext(const char *domain, const char *msgid, int category)
{
	(void)domain;
	(void)category;
	return msgid;
}

const char *bind_textdomain_codeset(const char *domain, const char *codeset)
{
	(void)domain;
	(void)codeset;
	return NULL;
}

const char *bindtextdomain(const char *domain, const char *dirname)
{
	(void)domain;
	(void)dirname;
	return NULL;
}

const char *textdomain(const char *domain)
{
	(void)domain;
	return NULL;
}

/* Locale-aware time/info functions: alias glibc-internal names to uClibc-ng */
struct tm;
size_t strftime_l(char *s, size_t maxsize, const char *format,
		  const struct tm *timeptr, locale_t loc);
size_t __strftime_l(char *s, size_t maxsize, const char *format,
		    const struct tm *timeptr, locale_t loc)
{
	return strftime_l(s, maxsize, format, timeptr, loc);
}

size_t wcsftime_l(wchar_t *s, size_t maxsize, const wchar_t *format,
		  const struct tm *timeptr, locale_t loc);
size_t __wcsftime_l(wchar_t *s, size_t maxsize, const wchar_t *format,
		    const struct tm *timeptr, locale_t loc)
{
	return wcsftime_l(s, maxsize, format, timeptr, loc);
}

char *nl_langinfo_l(int item, locale_t loc);
char *__nl_langinfo_l(int item, locale_t loc)
{
	return nl_langinfo_l(item, loc);
}

/* Locale-aware string compare/transform aliases */
int strcoll_l(const char *s1, const char *s2, locale_t loc);
int __strcoll_l(const char *s1, const char *s2, locale_t loc)
{
	return strcoll_l(s1, s2, loc);
}

size_t strxfrm_l(char *dest, const char *src, size_t n, locale_t loc);
size_t __strxfrm_l(char *dest, const char *src, size_t n, locale_t loc)
{
	return strxfrm_l(dest, src, n, loc);
}

int wcscoll_l(const wchar_t *s1, const wchar_t *s2, locale_t loc);
int __wcscoll_l(const wchar_t *s1, const wchar_t *s2, locale_t loc)
{
	return wcscoll_l(s1, s2, loc);
}

size_t wcsxfrm_l(wchar_t *dest, const wchar_t *src, size_t n, locale_t loc);
size_t __wcsxfrm_l(wchar_t *dest, const wchar_t *src, size_t n, locale_t loc)
{
	return wcsxfrm_l(dest, src, n, loc);
}

/* Locale-aware ctype/wctype */
int iswctype_l(wint_t wc, wctype_t desc, locale_t loc);
int __iswctype_l(wint_t wc, wctype_t desc, locale_t loc)
{
	return iswctype_l(wc, desc, loc);
}

wctype_t wctype_l(const char *property, locale_t loc);
wctype_t __wctype_l(const char *property, locale_t loc)
{
	return wctype_l(property, loc);
}

wint_t towlower_l(wint_t wc, locale_t loc);
wint_t __towlower_l(wint_t wc, locale_t loc)
{
	return towlower_l(wc, loc);
}

wint_t towupper_l(wint_t wc, locale_t loc);
wint_t __towupper_l(wint_t wc, locale_t loc)
{
	return towupper_l(wc, loc);
}

/* Locale-aware numeric parsing — uClibc-ng exposes only base names */
double strtod(const char *nptr, char **endptr);
float strtof(const char *nptr, char **endptr);
double __strtod_l(const char *nptr, char **endptr, locale_t loc)
{
	(void)loc;
	return strtod(nptr, endptr);
}
float __strtof_l(const char *nptr, char **endptr, locale_t loc)
{
	(void)loc;
	return strtof(nptr, endptr);
}

/* Locale lifecycle: pass through to public uClibc-ng names */
locale_t newlocale(int category_mask, const char *locale, locale_t base);
locale_t __newlocale(int category_mask, const char *locale, locale_t base)
{
	return newlocale(category_mask, locale, base);
}

locale_t duplocale(locale_t loc);
locale_t __duplocale(locale_t loc) { return duplocale(loc); }

void freelocale(locale_t loc);
void __freelocale(locale_t loc) { freelocale(loc); }

/* glibc's _FORTIFY_SOURCE wrappers — fall through to plain printf/sprintf */
int __fprintf_chk(FILE *stream, int flag, const char *fmt, ...)
{
	va_list ap;
	int ret;
	(void)flag;
	va_start(ap, fmt);
	ret = vfprintf(stream, fmt, ap);
	va_end(ap);
	return ret;
}

int __sprintf_chk(char *str, int flag, size_t slen, const char *fmt, ...)
{
	va_list ap;
	int ret;
	(void)flag;
	(void)slen;
	va_start(ap, fmt);
	ret = vsprintf(str, fmt, ap);
	va_end(ap);
	return ret;
}

/* libstdc++ pulls in __ctype_get_mb_cur_max but uClibc-ng exports it as
 * an inline; map to MB_CUR_MAX (always 6 in worst case for UTF-8). */
size_t __ctype_get_mb_cur_max(void) { return 6; }

/* TLS slot for shared libstdc++ — we're statically linked single-threaded,
 * so a no-op stub is fine. The void* parameter is the GOT entry. */
void *__tls_get_addr(void *gp) { (void)gp; return NULL; }

/* Required by C++ static destructors */
void *__dso_handle = NULL;
