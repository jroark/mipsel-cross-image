# MIPS/MIPS64 Cross-Compiler Environment

This container provides a development environment for cross-compiling the Linux kernel and BusyBox for `mipsel` (MIPS 32-bit little-endian) and `mips64el` (MIPS 64-bit little-endian).

## Getting Started

### 1. Build the Container
```bash
docker build -t mipsel-cross-dev .
# OR using docker-compose
docker-compose build
```

### 2. Run the Container
```bash
docker run -it --rm -v $(pwd):/work mipsel-cross-dev
# OR using docker-compose
docker-compose run mips-dev
```

## Cross-Compiling Examples

### Building BusyBox
Inside the container:
```bash
wget https://busybox.net/downloads/busybox-1.36.1.tar.bz2
tar xjf busybox-1.36.1.tar.bz2
cd busybox-1.36.1

# Configure for mipsel
make ARCH=mips CROSS_COMPILE=mipsel-linux-gnu- defconfig
# (Optional) Customize with: make ARCH=mips CROSS_COMPILE=mipsel-linux-gnu- menuconfig

# Build
make ARCH=mips CROSS_COMPILE=mipsel-linux-gnu- -j$(nproc)
make ARCH=mips CROSS_COMPILE=mipsel-linux-gnu- install
```

### Building the Linux Kernel
Inside the container:
```bash
wget https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.6.tar.xz
tar xf linux-6.6.tar.xz
cd linux-6.6

# Configure for mipsel (example for generic malta board)
make ARCH=mips CROSS_COMPILE=mipsel-linux-gnu- malta_defconfig

# Build
make ARCH=mips CROSS_COMPILE=mipsel-linux-gnu- -j$(nproc) vmlinux
```

## Tiny Core / MicroCore Specifics

The official Tiny Core MIPS port targets 32-bit little-endian (`mipsel`). Official support for `mips64el` is limited in older releases, but you can build custom kernels using the provided tools.

Resources for Tiny Core MIPS (7.x):
- **Kernel Config:** [http://tinycorelinux.net/7.x/mips/release/src/kernel/](http://tinycorelinux.net/7.x/mips/release/src/kernel/)
- **Repository Mirror:** [http://distro.ibiblio.org/tinycorelinux/7.x/mips/](http://distro.ibiblio.org/tinycorelinux/7.x/mips/)

For MIPS:
-   **Config:** Look for `config-3.16.6-tinycore` files.
-   **Patches:** TCL often applies patches for size optimization (like SquashFS patches).
-   **Rootfs:** The `rootfs.gz` is a standard cpio archive. You can unpack it, add your BusyBox build, and repack it:
    ```bash
    # Unpack
    zcat rootfs.gz | cpio -id
    # Repack
    find . | cpio -o -H newc | gzip > ../rootfs_new.gz
    ```

## Tools Included
- `mipsel-linux-gnu-gcc` (32-bit Little Endian)
- `mips64el-linux-gnuabi64-gcc` (64-bit Little Endian)
- `make`, `bc`, `bison`, `flex`, `libssl-dev`, `libelf-dev`
- `cpio` (for creating initramfs)
- `xz-utils`, `rsync`
