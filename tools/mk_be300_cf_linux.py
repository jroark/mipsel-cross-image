#!/usr/bin/env python3
"""Build a BE-300 CF recovery image that boots Linux from CF.

The image intentionally preserves the stock recovery filenames:

  /NANDWRITER.bin  B000FF-packed custom CF Linux loader
  /KLOADER.bin     B000FF-packed duplicate placeholder
  /All_nand.bin    Flat Linux kernel payload, not a NAND image

By default this still can build the original FAT16 superfloppy image. When
--rootfs-ext2 is supplied it builds a real CF disk image with an MBR, FAT16
partition 1 for the recovery bootstrap, and ext2 partition 2 for Linux root.
"""

import argparse
import math
import os
import pathlib
import struct
import sys
from dataclasses import dataclass


BYTES_PER_SECTOR = 512
ROOT_ENTRY_COUNT = 512
NUM_FATS = 2
RESERVED_SECTORS = 1
MEDIA_DESCRIPTOR = 0xF8
DEFAULT_SIZE_MIB = 64
DEFAULT_FAT_SIZE_MIB = 16
DEFAULT_FAT_START_LBA = 2048
DEFAULT_ROOTFS_ALIGN_LBA = 2048
DEFAULT_LABEL = "BE300CF"
DEFAULT_VOLUME_ID = 0xBE300CF1
MBR_SIGNATURE_OFFSET = 510
MBR_PARTITION_OFFSET = 0x1BE
PARTITION_FAT16_LBA = 0x0E
PARTITION_LINUX = 0x83
FIXED_FAT_TIME = 0
FIXED_FAT_DATE = ((1980 - 1980) << 9) | (1 << 5) | 1
FAT16_MIN_CLUSTERS = 4085
FAT16_MAX_CLUSTERS = 65524

B000FF_SIG = b"B000FF\n"
RECORD_CKSUM = 0xFFFFFFFF
ELF_MAGIC = b"\x7fELF"
ELFCLASS32 = 1
ELFDATA2LSB = 1
EM_MIPS = 8
PT_LOAD = 1
DEFAULT_CHUNK = 0x8000


@dataclass
class ImageFile:
    dest_name: str
    data: bytes
    short_name: bytes = b""
    start_cluster: int = 0


@dataclass
class Partition:
    bootable: bool
    part_type: int
    start_lba: int
    sectors: int


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, help="Output CF image path.")
    parser.add_argument("--loader", required=True, help="CF Linux loader ELF.")
    parser.add_argument("--vmlinux", required=True, help="Linux vmlinux ELF.")
    parser.add_argument("--size-mib", type=int, default=DEFAULT_SIZE_MIB)
    parser.add_argument(
        "--rootfs-ext2",
        help="Optional ext2 root filesystem image to place in MBR partition 2.",
    )
    parser.add_argument(
        "--fat-size-mib",
        type=int,
        default=DEFAULT_FAT_SIZE_MIB,
        help="FAT16 recovery partition size when --rootfs-ext2 is used.",
    )
    parser.add_argument(
        "--fat-start-lba",
        type=int,
        default=DEFAULT_FAT_START_LBA,
        help="Start LBA for the FAT16 recovery partition in MBR mode.",
    )
    parser.add_argument(
        "--rootfs-align-lba",
        type=int,
        default=DEFAULT_ROOTFS_ALIGN_LBA,
        help="LBA alignment for the ext2 root partition in MBR mode.",
    )
    parser.add_argument("--volume-label", default=DEFAULT_LABEL)
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--chunk", type=lambda s: int(s, 0), default=DEFAULT_CHUNK)
    parser.add_argument(
        "--file",
        action="append",
        default=[],
        metavar="DEST=SRC",
        help="Add an extra root-directory file.",
    )
    return parser.parse_args()


def parse_elf32_le(data: bytes):
    if len(data) < 52 or data[:4] != ELF_MAGIC:
        raise ValueError("not an ELF file")
    if data[4] != ELFCLASS32 or data[5] != ELFDATA2LSB:
        raise ValueError("must be ELF32 little-endian")
    if struct.unpack_from("<H", data, 18)[0] != EM_MIPS:
        raise ValueError("ELF is not MIPS")

    e_entry = struct.unpack_from("<I", data, 24)[0]
    e_phoff = struct.unpack_from("<I", data, 28)[0]
    e_phentsize = struct.unpack_from("<H", data, 42)[0]
    e_phnum = struct.unpack_from("<H", data, 44)[0]
    if e_phentsize != 32:
        raise ValueError(f"unexpected e_phentsize={e_phentsize}")

    loads = []
    for i in range(e_phnum):
        off = e_phoff + i * 32
        p_type, p_offset, p_vaddr, _p_paddr, p_filesz, p_memsz, _p_flags, _p_align = (
            struct.unpack_from("<IIIIIIII", data, off)
        )
        if p_type == PT_LOAD and p_filesz:
            loads.append((p_vaddr, p_filesz, p_memsz, p_offset))
    if not loads:
        raise ValueError("ELF has no loadable file segments")
    return e_entry, loads


def is_kseg(addr: int) -> bool:
    return (addr & 0xE0000000) in (0x80000000, 0xA0000000)


def build_b000ff(elf_data: bytes, chunk: int) -> tuple[bytes, dict]:
    e_entry, loads = parse_elf32_le(elf_data)
    if chunk <= 0:
        raise ValueError("chunk must be positive")
    if not is_kseg(e_entry):
        raise ValueError(f"entry 0x{e_entry:08X} is not KSEG")

    image_start = min(addr for addr, _filesz, _memsz, _off in loads)
    if not is_kseg(image_start):
        raise ValueError(f"image start 0x{image_start:08X} is not KSEG")

    records = bytearray()
    n_records = 0
    for addr, filesz, _memsz, offset in loads:
        if not is_kseg(addr):
            raise ValueError(f"segment 0x{addr:08X} is not KSEG")
        pos = 0
        while pos < filesz:
            take = min(chunk, filesz - pos)
            records += struct.pack("<III", addr + pos, take, RECORD_CKSUM)
            records += elf_data[offset + pos : offset + pos + take]
            pos += take
            n_records += 1

    records += b"\x00\x00\x00\x00"
    records += struct.pack("<III", e_entry, 0, RECORD_CKSUM)

    container = B000FF_SIG + struct.pack("<II", image_start, len(records)) + records
    return container, {
        "entry": e_entry,
        "image_start": image_start,
        "image_length": len(records),
        "records": n_records,
    }


def kernel_flat_bytes(kernel_data: bytes) -> tuple[bytes, dict]:
    e_entry, loads = parse_elf32_le(kernel_data)
    base = min(addr for addr, _filesz, _memsz, _off in loads)
    end = max(addr + filesz for addr, filesz, _memsz, _off in loads)
    flat = bytearray(end - base)
    for vaddr, filesz, _memsz, offset in loads:
        rel = vaddr - base
        flat[rel : rel + filesz] = kernel_data[offset : offset + filesz]
    return bytes(flat), {"load": base, "entry": e_entry, "size": len(flat)}


def parse_extra_file(spec: str) -> ImageFile:
    if "=" not in spec:
        raise ValueError(f"invalid --file {spec!r}; expected DEST=SRC")
    dest, src = spec.split("=", 1)
    if not dest or not src:
        raise ValueError(f"invalid --file {spec!r}; expected DEST=SRC")
    return ImageFile(dest, pathlib.Path(src).read_bytes())


def fat_pad(text: str, length: int) -> bytes:
    return text.encode("ascii", "replace")[:length].ljust(length, b" ")


def dirent_pad(text: str, length: int, pad_byte: bytes) -> bytes:
    return text.encode("ascii", "replace")[:length].ljust(length, pad_byte)


def root_dir_sectors() -> int:
    return (ROOT_ENTRY_COUNT * 32 + BYTES_PER_SECTOR - 1) // BYTES_PER_SECTOR


def choose_fat_layout(total_sectors: int) -> tuple[int, int, int]:
    root_sectors = root_dir_sectors()
    for sectors_per_cluster in (1, 2, 4, 8, 16, 32, 64, 128):
        fat_sectors = 1
        while True:
            data_sectors = (
                total_sectors
                - RESERVED_SECTORS
                - NUM_FATS * fat_sectors
                - root_sectors
            )
            if data_sectors <= 0:
                break
            clusters = data_sectors // sectors_per_cluster
            needed = math.ceil(((clusters + 2) * 2) / BYTES_PER_SECTOR)
            if needed == fat_sectors:
                break
            fat_sectors = needed
        if data_sectors <= 0:
            continue
        clusters = data_sectors // sectors_per_cluster
        if FAT16_MIN_CLUSTERS <= clusters <= FAT16_MAX_CLUSTERS:
            return sectors_per_cluster, fat_sectors, clusters
    raise ValueError("cannot choose a FAT16 layout for this image size")


def is_valid_short_char(ch: str) -> bool:
    return ch.isalnum() or ch in "$%'-_@~`!(){}^#&"


def sanitize_short_component(text: str) -> str:
    return "".join(ch if is_valid_short_char(ch) else "_" for ch in text.upper())


def split_name(name: str) -> tuple[str, str]:
    if "/" in name or "\\" in name:
        raise ValueError(f"destination must be in the root directory: {name!r}")
    stem, ext = os.path.splitext(name)
    if not stem:
        raise ValueError(f"destination has no basename: {name!r}")
    return stem, ext[1:] if ext.startswith(".") else ext


def short_name_checksum(short_name: bytes) -> int:
    checksum = 0
    for byte in short_name:
        checksum = (((checksum & 1) << 7) | (checksum >> 1)) + byte
        checksum &= 0xFF
    return checksum


def make_short_name(name: str, used: set[bytes]) -> bytes:
    stem, ext = split_name(name)
    stem_short = sanitize_short_component(stem)
    ext_short = sanitize_short_component(ext)
    candidate = (
        fat_pad(stem_short[:8], 8)
        + fat_pad(ext_short[:3], 3)
    )
    exact_short = (
        stem_short == stem.upper()
        and ext_short == ext.upper()
        and 1 <= len(stem_short) <= 8
        and len(ext_short) <= 3
        and "." not in stem
    )
    if exact_short and candidate not in used:
        used.add(candidate)
        return candidate

    base = stem_short[:6] or "FILE"
    for index in range(1, 100000):
        tail = f"~{index}"
        short_base = (base[: max(0, 8 - len(tail))] + tail)[:8]
        candidate = (
            fat_pad(short_base, 8)
            + fat_pad(ext_short[:3], 3)
        )
        if candidate not in used:
            used.add(candidate)
            return candidate
    raise ValueError(f"could not derive a short name for {name!r}")


def lfn_chunks(name: str) -> list[list[int]]:
    utf16 = name.encode("utf-16le")
    code_units = list(struct.unpack("<" + "H" * (len(utf16) // 2), utf16))
    code_units.append(0)
    while len(code_units) % 13:
        code_units.append(0xFFFF)
    return [code_units[i : i + 13] for i in range(0, len(code_units), 13)]


def encode_lfn_entry(order: int, chunk: list[int], checksum: int) -> bytes:
    entry = bytearray(32)
    entry[0] = order
    entry[11] = 0x0F
    entry[13] = checksum
    positions = ((1, 5), (14, 6), (28, 2))
    chunk_offset = 0
    for start, count in positions:
        for i in range(count):
            struct.pack_into("<H", entry, start + i * 2, chunk[chunk_offset + i])
        chunk_offset += count
    return bytes(entry)


def encode_short_dirent(
    short_name: bytes,
    size_bytes: int,
    start_cluster: int,
    attr: int = 0x20,
) -> bytes:
    entry = bytearray(32)
    entry[0:11] = short_name
    entry[11] = attr
    struct.pack_into("<H", entry, 14, FIXED_FAT_TIME)
    struct.pack_into("<H", entry, 16, FIXED_FAT_DATE)
    struct.pack_into("<H", entry, 18, FIXED_FAT_DATE)
    struct.pack_into("<H", entry, 22, FIXED_FAT_TIME)
    struct.pack_into("<H", entry, 24, FIXED_FAT_DATE)
    struct.pack_into("<H", entry, 26, start_cluster & 0xFFFF)
    struct.pack_into("<I", entry, 28, size_bytes)
    return bytes(entry)


def decode_short_name(short_name: bytes) -> str:
    stem = short_name[:8].decode("ascii", "replace").rstrip(" \x00")
    ext = short_name[8:11].decode("ascii", "replace").rstrip(" \x00")
    return stem + (("." + ext) if ext else "")


def append_directory_entries(root_dir: bytearray, entry: ImageFile) -> None:
    needs_lfn = entry.dest_name.upper() != decode_short_name(entry.short_name)
    if needs_lfn:
        checksum = short_name_checksum(entry.short_name)
        chunks = lfn_chunks(entry.dest_name)
        total = len(chunks)
        for chunk_index in range(total, 0, -1):
            chunk = chunks[chunk_index - 1]
            order = chunk_index | (0x40 if chunk_index == total else 0)
            root_dir.extend(encode_lfn_entry(order, chunk, checksum))
    root_dir.extend(
        encode_short_dirent(entry.short_name, len(entry.data), entry.start_cluster)
    )


def cluster_count_for_bytes(size_bytes: int, cluster_size_bytes: int) -> int:
    return 0 if size_bytes == 0 else (size_bytes + cluster_size_bytes - 1) // cluster_size_bytes


def build_boot_sector(
    total_sectors: int,
    sectors_per_cluster: int,
    fat_sectors: int,
    label: str,
    hidden_sectors: int = 0,
) -> bytes:
    sector = bytearray(BYTES_PER_SECTOR)
    sector[0:3] = b"\xEB\x3C\x90"
    sector[3:11] = b"MSDOS5.0"
    struct.pack_into("<H", sector, 11, BYTES_PER_SECTOR)
    sector[13] = sectors_per_cluster
    struct.pack_into("<H", sector, 14, RESERVED_SECTORS)
    sector[16] = NUM_FATS
    struct.pack_into("<H", sector, 17, ROOT_ENTRY_COUNT)
    if total_sectors < 0x10000:
        struct.pack_into("<H", sector, 19, total_sectors)
    else:
        struct.pack_into("<I", sector, 32, total_sectors)
    sector[21] = MEDIA_DESCRIPTOR
    struct.pack_into("<H", sector, 22, fat_sectors)
    struct.pack_into("<H", sector, 24, 32)
    struct.pack_into("<H", sector, 26, 64)
    struct.pack_into("<I", sector, 28, hidden_sectors)
    sector[36] = 0x80
    sector[38] = 0x29
    struct.pack_into("<I", sector, 39, DEFAULT_VOLUME_ID)
    sector[43:54] = fat_pad(label.upper(), 11)
    sector[54:62] = b"FAT16   "
    sector[510:512] = b"\x55\xAA"
    return bytes(sector)


def build_fat16(
    files: list[ImageFile],
    total_bytes: int,
    label: str,
    hidden_sectors: int = 0,
) -> bytes:
    total_sectors = total_bytes // BYTES_PER_SECTOR
    sectors_per_cluster, fat_sectors, total_clusters = choose_fat_layout(total_sectors)
    cluster_size_bytes = sectors_per_cluster * BYTES_PER_SECTOR
    root_sectors = root_dir_sectors()
    data_start_sector = RESERVED_SECTORS + NUM_FATS * fat_sectors + root_sectors

    next_cluster = 2
    for entry in files:
        count = cluster_count_for_bytes(len(entry.data), cluster_size_bytes)
        entry.start_cluster = next_cluster if count else 0
        next_cluster += count
    needed_clusters = next_cluster - 2
    if needed_clusters > total_clusters:
        raise ValueError(f"files need {needed_clusters} clusters, image has {total_clusters}")

    used_short_names: set[bytes] = set()
    for entry in files:
        entry.short_name = make_short_name(entry.dest_name, used_short_names)

    root_dir = bytearray()
    root_dir.extend(encode_short_dirent(fat_pad(label.upper(), 11), 0, 0, attr=0x08))
    for entry in files:
        append_directory_entries(root_dir, entry)
    root_dir.extend(b"\x00" * 32)
    root_bytes = root_sectors * BYTES_PER_SECTOR
    if len(root_dir) > root_bytes:
        raise ValueError("root directory overflow")
    root_dir.extend(b"\x00" * (root_bytes - len(root_dir)))

    fat_entries = [0] * (total_clusters + 2)
    fat_entries[0] = 0xFFF8
    fat_entries[1] = 0xFFFF
    for entry in files:
        count = cluster_count_for_bytes(len(entry.data), cluster_size_bytes)
        for i in range(count):
            cluster = entry.start_cluster + i
            fat_entries[cluster] = 0xFFFF if i == count - 1 else cluster + 1

    fat = bytearray(fat_sectors * BYTES_PER_SECTOR)
    for index, value in enumerate(fat_entries):
        struct.pack_into("<H", fat, index * 2, value)

    image = bytearray(total_bytes)
    image[0:BYTES_PER_SECTOR] = build_boot_sector(
        total_sectors, sectors_per_cluster, fat_sectors, label, hidden_sectors
    )
    fat1_offset = RESERVED_SECTORS * BYTES_PER_SECTOR
    fat2_offset = fat1_offset + len(fat)
    image[fat1_offset : fat1_offset + len(fat)] = fat
    image[fat2_offset : fat2_offset + len(fat)] = fat

    root_offset = (RESERVED_SECTORS + NUM_FATS * fat_sectors) * BYTES_PER_SECTOR
    image[root_offset : root_offset + len(root_dir)] = root_dir

    for entry in files:
        count = cluster_count_for_bytes(len(entry.data), cluster_size_bytes)
        if count == 0:
            continue
        first_sector = data_start_sector + (entry.start_cluster - 2) * sectors_per_cluster
        file_offset = first_sector * BYTES_PER_SECTOR
        image[file_offset : file_offset + len(entry.data)] = entry.data

    return bytes(image)


def sectors_for_bytes(size: int, label: str) -> int:
    if size <= 0 or size % BYTES_PER_SECTOR:
        raise ValueError(f"{label} size must be positive and sector-aligned")
    return size // BYTES_PER_SECTOR


def align_up(value: int, alignment: int) -> int:
    if alignment <= 0:
        raise ValueError("alignment must be positive")
    return ((value + alignment - 1) // alignment) * alignment


def encode_chs(lba: int) -> bytes:
    if lba <= 0:
        return b"\x00\x01\x00"

    sectors_per_track = 63
    heads = 255
    sector = (lba % sectors_per_track) + 1
    temp = lba // sectors_per_track
    head = temp % heads
    cylinder = temp // heads
    if cylinder > 1023:
        return b"\xFE\xFF\xFF"
    return bytes(
        [
            head & 0xFF,
            (sector & 0x3F) | ((cylinder >> 2) & 0xC0),
            cylinder & 0xFF,
        ]
    )


def build_mbr(partitions: list[Partition]) -> bytes:
    if len(partitions) > 4:
        raise ValueError("MBR supports at most four partitions")

    mbr = bytearray(BYTES_PER_SECTOR)
    for index, part in enumerate(partitions):
        if part.start_lba <= 0 or part.sectors <= 0:
            raise ValueError("partition start and size must be positive")
        off = MBR_PARTITION_OFFSET + index * 16
        mbr[off] = 0x80 if part.bootable else 0x00
        mbr[off + 1 : off + 4] = encode_chs(part.start_lba)
        mbr[off + 4] = part.part_type & 0xFF
        mbr[off + 5 : off + 8] = encode_chs(part.start_lba + part.sectors - 1)
        struct.pack_into("<I", mbr, off + 8, part.start_lba)
        struct.pack_into("<I", mbr, off + 12, part.sectors)
    mbr[MBR_SIGNATURE_OFFSET : MBR_SIGNATURE_OFFSET + 2] = b"\x55\xAA"
    return bytes(mbr)


def build_partitioned_image(
    fat_image: bytes,
    rootfs_image: bytes,
    total_bytes: int,
    fat_start_lba: int,
    rootfs_align_lba: int,
) -> tuple[bytes, dict]:
    total_sectors = sectors_for_bytes(total_bytes, "disk")
    fat_sectors = sectors_for_bytes(len(fat_image), "FAT16 partition")
    rootfs_sectors = sectors_for_bytes(len(rootfs_image), "ext2 rootfs partition")

    if fat_start_lba < 1:
        raise ValueError("FAT partition must not start at LBA 0 in MBR mode")

    rootfs_start_lba = align_up(fat_start_lba + fat_sectors, rootfs_align_lba)
    if rootfs_start_lba + rootfs_sectors > total_sectors:
        raise ValueError(
            "partitions do not fit: "
            f"disk={total_sectors} sectors fat={fat_start_lba}+{fat_sectors} "
            f"rootfs={rootfs_start_lba}+{rootfs_sectors}"
        )

    partitions = [
        Partition(True, PARTITION_FAT16_LBA, fat_start_lba, fat_sectors),
        Partition(False, PARTITION_LINUX, rootfs_start_lba, rootfs_sectors),
    ]
    image = bytearray(total_bytes)
    image[0:BYTES_PER_SECTOR] = build_mbr(partitions)

    fat_offset = fat_start_lba * BYTES_PER_SECTOR
    rootfs_offset = rootfs_start_lba * BYTES_PER_SECTOR
    image[fat_offset : fat_offset + len(fat_image)] = fat_image
    image[rootfs_offset : rootfs_offset + len(rootfs_image)] = rootfs_image

    return bytes(image), {
        "fat_start_lba": fat_start_lba,
        "fat_sectors": fat_sectors,
        "rootfs_start_lba": rootfs_start_lba,
        "rootfs_sectors": rootfs_sectors,
    }


def main() -> int:
    args = parse_args()
    out = pathlib.Path(args.output)
    if out.exists() and not args.force:
        print(f"refusing to overwrite existing image: {out}", file=sys.stderr)
        return 1

    total_bytes = args.size_mib * 1024 * 1024
    if total_bytes < 4 * 1024 * 1024 or total_bytes % BYTES_PER_SECTOR:
        print("image size must be at least 4 MiB and sector-aligned", file=sys.stderr)
        return 1

    try:
        loader_container, loader_meta = build_b000ff(
            pathlib.Path(args.loader).read_bytes(), args.chunk
        )
        kernel_flat, kernel_meta = kernel_flat_bytes(pathlib.Path(args.vmlinux).read_bytes())
        files = [
            ImageFile("NANDWRITER.bin", loader_container),
            ImageFile("KLOADER.bin", loader_container),
            ImageFile("All_nand.bin", kernel_flat),
        ]
        for spec in args.file:
            files.append(parse_extra_file(spec))
        layout = None
        if args.rootfs_ext2:
            fat_bytes = args.fat_size_mib * 1024 * 1024
            if fat_bytes < 4 * 1024 * 1024 or fat_bytes % BYTES_PER_SECTOR:
                raise ValueError("FAT partition size must be at least 4 MiB and sector-aligned")
            rootfs_image = pathlib.Path(args.rootfs_ext2).read_bytes()
            fat_image = build_fat16(
                files,
                fat_bytes,
                args.volume_label,
                hidden_sectors=args.fat_start_lba,
            )
            image, layout = build_partitioned_image(
                fat_image,
                rootfs_image,
                total_bytes,
                args.fat_start_lba,
                args.rootfs_align_lba,
            )
        else:
            image = build_fat16(files, total_bytes, args.volume_label)
    except (OSError, ValueError) as exc:
        print(str(exc), file=sys.stderr)
        return 1

    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(image)

    if layout:
        print(f"Wrote {out} ({total_bytes} bytes, MBR + FAT16 + ext2)")
        print(
            f"  p1 FAT16: start_lba={layout['fat_start_lba']} "
            f"sectors={layout['fat_sectors']}"
        )
        print(
            f"  p2 ext2 rootfs: start_lba={layout['rootfs_start_lba']} "
            f"sectors={layout['rootfs_sectors']}"
        )
    else:
        print(f"Wrote {out} ({total_bytes} bytes, FAT16 superfloppy)")
    print(
        f"  NANDWRITER.bin: B000FF entry=0x{loader_meta['entry']:08X} "
        f"records={loader_meta['records']}"
    )
    print(
        f"  All_nand.bin: kernel load=0x{kernel_meta['load']:08X} "
        f"entry=0x{kernel_meta['entry']:08X} size=0x{kernel_meta['size']:X}"
    )
    for entry in files:
        print(
            f"  {entry.dest_name}: short={decode_short_name(entry.short_name)!r} "
            f"cluster={entry.start_cluster} size={len(entry.data)}"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
