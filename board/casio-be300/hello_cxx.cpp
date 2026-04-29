/*
 * Phase C smoke test: C++ stdio + std::string against the existing Debian
 * libstdc++.a / libc.a (glibc) on a BE-300 emulator boot. If this runs, we
 * have a viable C++ runtime path without rebuilding GCC or uClibc-ng. If
 * it SIGILLs (SPECIAL3), we need to switch the libc story.
 *
 * Build:
 *   mipsel-linux-gnu-g++ -march=mips2 -static -O2 \
 *     -B/tmp/libgcc_patched \
 *     hello_cxx.cpp -o hello_cxx
 */

#include <iostream>
#include <string>
#include <vector>

int main()
{
	std::cout << "hello_cxx: starting" << std::endl;

	std::string s = "hello from C++ on the BE-300";
	std::cout << "hello_cxx: string=" << s << " len=" << s.size() << std::endl;

	std::vector<int> v;
	for (int i = 0; i < 8; ++i)
		v.push_back(i * i);
	std::cout << "hello_cxx: vector=";
	for (int x : v)
		std::cout << x << ' ';
	std::cout << std::endl;

	std::cout << "hello_cxx: done" << std::endl;
	return 0;
}
