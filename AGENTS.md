# Repository Guidelines

## Project Structure & Module Organization

This repository builds a Linux 4.2.9 + BusyBox image for the Casio Cassiopeia BE-300. The main entry point is `build_be300_kernel.sh`, which prepares musl, BusyBox, kernel patches, rootfs contents, SPL, and a NAND image. Board-specific source lives in `board/casio-be300/` and is injected into the kernel tree during the build. Kernel configuration belongs in `configs/be300_defconfig`. NAND/image utilities live in `tools/`. Hardware references and porting notes are in `docs/`, `README.md`, and `CLAUDE.md`. Treat `linux-4.2.9/`, `rootfs_be300/`, `musl-*`, and `busybox-1.24.2/` as generated or vendored build trees unless a task explicitly requires changing them.

## Build, Test, and Development Commands

- `docker-compose build` builds the `mips-dev` container with the required MIPS cross toolchains.
- `docker-compose run --rm mips-dev bash -c "./build_be300_kernel.sh"` runs the full BE-300 kernel, rootfs, SPL, and NAND build.
- `./bin/be300 --nand linux-4.2.9/be300.nand --speed 0` boots the produced image on the macOS host emulator.
- `docker-compose run --rm mips-dev bash -c "./build_test_kernels.sh"` builds diagnostic kernels used to isolate low-level boot and userspace faults.
- `python3 tools/mk_be300_nand.py --vmlinux linux-4.2.9/vmlinux --out linux-4.2.9/be300.nand` repacks a NAND image when inputs are already built.

## Coding Style & Naming Conventions

Follow Linux kernel C style in board and kernel-facing code: tabs for indentation, K&R braces, lower_snake_case symbols, and concise comments for hardware assumptions. Shell scripts are Bash; quote variables, keep phase comments current, and preserve required MIPS constraints such as `-march=mips2` and 32-bit emulator compatibility. Python utilities use standard-library code, `argparse`, and clear offset/size constants.

## Testing Guidelines

There is no standalone unit-test suite. Validate changes with a full Docker build and an emulator boot. For boot-path, MMU, cache, SPL, NAND, framebuffer, or rootfs changes, include the exact emulator command and observed result. Use `build_test_kernels.sh` for regressions involving page handling, COW, init startup, or userspace instruction compatibility.

## Commit & Pull Request Guidelines

Recent commits use concise imperative subjects, often with a subsystem prefix, for example `BE-300: ...` or `keys: ...`. Keep subjects specific and under about 72 characters when practical. Pull requests should describe the hardware or emulator behavior changed, list build and boot evidence, mention any untested real-hardware risk, and link relevant notes in `CLAUDE.md` or `docs/`.

## Agent-Specific Instructions

Prefer editing source inputs over generated outputs. Do not remove large archives, screenshots, rootfs contents, or dirty worktree files unless the user explicitly asks; many are useful local test artifacts.
