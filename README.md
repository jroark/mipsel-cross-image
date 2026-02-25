# MIPS/MIPS64 Cross-Compiler Environment

This container provides a development environment for cross-compiling the Linux kernel and BusyBox for `mipsel` (MIPS 32-bit little-endian) and `mips64el` (MIPS 64-bit little-endian).

## Getting Started

### 1. Build the Container
```bash
docker-compose build
```

### 2. Run the Container
```bash
docker-compose run mips-dev
```

## Automating the Tiny Core MIPS Build

The following scripts are included to automate the creation of a minimal Tiny Core style system:

1.  **`./build_tcl_kernel.sh`**: Downloads the Tiny Core 7.x patched Linux 4.2.9 source, applies modern GCC compatibility fixes, and builds `vmlinux`.
2.  **`./build_busybox.sh`**: Downloads BusyBox 1.24.2, configures it for MIPS with internal crypt support, and performs a static build.
3.  **`./create_initramfs.sh`**: Packages the BusyBox `_install` directory into a bootable `rootfs.gz` with a custom `/init` script.

To run them all sequentially inside the container:
```bash
docker-compose run mips-dev bash -c "./build_tcl_kernel.sh && ./build_busybox.sh && ./create_initramfs.sh"
```

## Modern Toolchain Compatibility
Building legacy kernels (like 4.2.9) on modern systems (Ubuntu 22.04 / GCC 10+) requires specific fixes included in the scripts:
- **yylloc fix**: Handled via `extern` in lexer files.
- **log2.h fix**: Resolved `noreturn`/`const` attribute conflicts.
- **Werror**: Recursively stripped from Makefiles to prevent build stops on modern compiler warnings.
- **Static Crypt**: BusyBox is configured with `CONFIG_USE_BB_CRYPT` because modern glibc requires external `libcrypt` for static linking.

## Testing the Build
You can test the resulting kernel and initramfs using QEMU:
```bash
qemu-system-mipsel -M malta \
    -kernel linux-4.2.9/vmlinux \
    -initrd rootfs.gz \
    -append "console=ttyS0" \
    -nographic
```

## Tools Included
- `mipsel-linux-gnu-gcc` (32-bit Little Endian)
- `mips64el-linux-gnuabi64-gcc` (64-bit Little Endian)
- `make`, `bc`, `bison`, `flex`, `libssl-dev`, `libelf-dev`, `libncurses-dev`
- `cpio`, `xz-utils`, `zstd`, `zlib1g-dev`
- `rsync`, `wget`, `curl`
