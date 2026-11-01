#!/usr/bin/env python3
"""Check that used-filesystem snapshots cannot weaken installation binding."""
import importlib.util
from pathlib import Path
import sys
import unittest
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
import prepare_linux_nand_transaction as tx
import physical_linux_nand as n
spec=importlib.util.spec_from_file_location('fixtures',ROOT/'tests/physical_linux_nand.py')
fixtures=importlib.util.module_from_spec(spec);spec.loader.exec_module(fixtures)

class SnapshotTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        fixtures.PhysicalTests.setUpClass()
        cls.f=fixtures.PhysicalTests

    @classmethod
    def tearDownClass(cls):
        fixtures.PhysicalTests.tearDownClass()

    def test_mutable_filesystem_binding(self):
        used=bytearray(self.f.raw);used[330*n.BLOCK+17]^=1
        bound=tx.snapshot_binding(used,self.f.raw,self.f.backup,self.f.inv,self.f.plan)
        self.assertEqual(bound['physical_sha256'],n.sha(used))
        self.assertEqual(bound['snapshot_of_sha256'],n.sha(self.f.raw))
        self.assertEqual(bound['preserve_blocks'],self.f.plan['preserve_blocks'])

    def test_immutable_and_quarantine_changes_refused(self):
        for offset in (0,160*528,1004*n.BLOCK,327*n.BLOCK+9):
            used=bytearray(self.f.raw);used[offset]^=1
            with self.subTest(offset=offset),self.assertRaises(ValueError):
                tx.snapshot_binding(used,self.f.raw,self.f.backup,self.f.inv,self.f.plan)

    def test_new_runtime_bad_block_refused(self):
        used=bytearray(self.f.raw);used[330*n.BLOCK+517]=0
        with self.assertRaises(ValueError):
            tx.snapshot_binding(used,self.f.raw,self.f.backup,self.f.inv,self.f.plan)

    def test_unbound_installed_reference_refused(self):
        plan=dict(self.f.plan,physical_sha256='0'*64)
        with self.assertRaises(ValueError):
            tx.snapshot_binding(self.f.raw,self.f.raw,self.f.backup,self.f.inv,plan)

if __name__=='__main__':unittest.main()
