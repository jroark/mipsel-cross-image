#!/usr/bin/env python3
"""Independent fault fixtures for the offline Linux raw-image encoder."""
import importlib.util
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
import zlib

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('physical',ROOT/'tools/physical_linux_nand.py')
n = importlib.util.module_from_spec(spec)
spec.loader.exec_module(n)


class PhysicalTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.helper = Path(cls.tmp.name)/'inventory'
        subprocess.run(['cc','-O2',str(ROOT/'tools/nand_inventory.c'),
                        str(ROOT/'board/casio-be300/nand_boot.c'),
                        str(ROOT/'board/casio-be300/nand_ecc.c'),'-o',str(cls.helper)],check=True)
        cls.backup = bytes((i*13+7)%256 for i in range(n.BLOCK))*1024
        cls.logical = bytearray(b'\xff'*(16*1024*1024))
        for i,(start,count) in enumerate(((0,32),(32,8),(160,100),(10240,22528))):
            struct.pack_into('<II',cls.logical,i*16+8,start,count)
        cls.logical[0x4000:0x4007] = b'B000FF\n'
        cls.logical[0x14000:0x14000+len(b'BE300_PHYSICAL_NAND_V1')] = b'BE300_PHYSICAL_NAND_V1'
        cls.inv = dict(version=1,source_sha256=n.sha(cls.backup),quarantined=[1,327,1005])
        cls.fs = b'\x85\x19'+b'\x00'*510+b'\xff'*((684-1)*16384-512)
        cls.raw,cls.plan = n.pack(cls.helper,cls.logical,cls.backup,cls.inv,cls.fs)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_quarantine_mapping_and_fs(self):
        for b in self.inv['quarantined']:
            self.assertEqual(self.raw[b*n.BLOCK:(b+1)*n.BLOCK],self.backup[b*n.BLOCK:(b+1)*n.BLOCK])
        self.assertEqual(self.plan['boot_replacements'],{'1':1004})
        at = 1004*n.BLOCK
        self.assertEqual(self.raw[at:at+7],b'B000FF\n')
        manifest = self.raw[528:1040]
        self.assertEqual(manifest[:8],b'GZNAND1\0')
        self.assertEqual(manifest[188:196],b'LINUX1\0\0')
        self.assertEqual(struct.unpack_from('<I',manifest,508)[0],zlib.crc32(manifest[:508]))
        self.assertEqual(self.raw[320*n.BLOCK:320*n.BLOCK+512],self.fs[:512])
        self.assertEqual(self.raw[320*n.BLOCK+512:320*n.BLOCK+520],b'\xff'*8)
        self.assertNotEqual(self.raw[320*n.BLOCK+520:320*n.BLOCK+528],b'\xff'*8)
        self.assertEqual(self.raw[320*n.BLOCK+528:320*n.BLOCK+1056],b'\xff'*528)

    def test_strict_reader_and_corruption(self):
        candidate = Path(self.tmp.name)/'candidate.raw'
        candidate.write_bytes(self.raw)
        subprocess.run([str(self.helper),'--check-boot',str(candidate)],check=True)
        damaged = bytearray(self.raw)
        for i in (3,17,59):
            damaged[160*528+i] ^= 0x71
        candidate.write_bytes(damaged)
        self.assertNotEqual(subprocess.run([str(self.helper),'--check-boot',str(candidate)]).returncode,0)

    def test_preserved_stale_boot_tags_are_excluded(self):
        backup=bytearray(self.backup)
        tag=b'\xaa\x55\x0f\xff'+struct.pack('<I',8)
        stale=n.native(self.helper,['--encode'],(b'old CE'.ljust(512,b'\xff')+tag)*32)
        backup[8*n.BLOCK:9*n.BLOCK]=stale
        inv=dict(self.inv,source_sha256=n.sha(backup),quarantined=[1,8,327,1005])
        raw,plan=n.pack(self.helper,self.logical,backup,inv,self.fs)
        self.assertEqual(raw[8*n.BLOCK:9*n.BLOCK],stale)
        candidate=Path(self.tmp.name)/'stale-tags.raw'
        candidate.write_bytes(raw)
        subprocess.run([str(self.helper),'--check-boot',str(candidate)],check=True)

    def test_rom_cannot_ignore_preserved_duplicate_spl_tags(self):
        backup=bytearray(self.backup)
        tag=b'\xaa\x55\x0f\xff'+struct.pack('<I',1)
        stale=n.native(self.helper,['--encode'],(b'old CE'.ljust(512,b'\xff')+tag)*32)
        backup[n.BLOCK:2*n.BLOCK]=stale
        inv=dict(self.inv,source_sha256=n.sha(backup))
        raw,plan=n.pack(self.helper,self.logical,backup,inv,self.fs)
        candidate=Path(self.tmp.name)/'ambiguous-rom-spl.raw'
        candidate.write_bytes(raw)
        self.assertNotEqual(subprocess.run([str(self.helper),'--check-boot',str(candidate)]).returncode,0)

    def test_manifest_crc_rejected_despite_valid_ecc(self):
        raw=bytearray(self.raw)
        page=bytearray(raw[528:1056]);page[508]^=1
        raw[528:1056]=n.native(self.helper,['--encode'],page[:520])
        candidate=Path(self.tmp.name)/'bad-manifest.raw'
        candidate.write_bytes(raw)
        self.assertNotEqual(subprocess.run([str(self.helper),'--check-boot',str(candidate)]).returncode,0)

    def test_reject_invalid_inputs(self):
        for change in ({'source_sha256':'0'*64},{'quarantined':[0]},
                       {'quarantined':[1,1]},{'quarantined':[True]},
                       {'quarantined':list(range(1,22))}):
            with self.subTest(change=change),self.assertRaises(ValueError):
                n.pack(self.helper,self.logical,self.backup,dict(self.inv,**change),self.fs)
        with self.assertRaises(ValueError):
            n.pack(self.helper,self.logical,self.backup,self.inv,self.fs+b'\xff'*16384)

    def test_publication_refuses_overwrite(self):
        path = Path(self.tmp.name)/'private.raw'
        n.write_new(path,b'original')
        self.assertEqual(path.stat().st_mode & 0o777,0o600)
        with self.assertRaises(FileExistsError):
            n.write_new(path,b'replacement')
        self.assertEqual(path.read_bytes(),b'original')


if __name__ == '__main__':
    unittest.main()
