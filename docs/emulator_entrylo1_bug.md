# BE-300 Emulator Bug: Context Register BadVPN2 Computation (FIXED)

## Root Cause (confirmed by emulator developer)

The bug was NOT in EntryLo1 selection (that code was correct). It was in the **Context register's BadVPN2 field** computed on TLB miss.

GXemul derived BadVPN2 from the last-scanned TLB entry's PageMask, but real VR4131 hardware always uses the CPU's minimum page size (1KB). When 4KB TLB entries existed, BadVPN2 was `vaddr>>13` instead of the correct `vaddr>>11`, causing the Linux TLB refill handler (`srl Context, 3`) to index the page table at **4x the wrong offset** and load garbage PTEs.

## Fix

One new variable `exception_vpn2` computed from `pagemask_shift` before the TLB scan loop, used instead of `vaddr_vpn2` for the exception handler. 22 lines changed in `memory_mips_v2p.c`.

## Remaining Issue

test3-uclibc still fails on both emulator and real hardware — that's a separate D-cache aliasing kernel bug, not an emulator issue.
