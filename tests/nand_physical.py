#!/usr/bin/env python3
"""Exercise production filesystem page ECC with independent OOB changes."""
from pathlib import Path
import importlib.util
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('installer',ROOT/'scripts/install_board_hardware.py')
installer=importlib.util.module_from_spec(spec);spec.loader.exec_module(installer)

class PageTests(unittest.TestCase):
    def test_cleanmarker_and_correction(self):
        text=(ROOT/'board/casio-be300/nand_physical.h').read_text()
        bodies={}
        for name in ('physical_read_page','physical_write_page'):
            installer.function_body(text,name,lambda b,n=name:bodies.setdefault(n,b))
        code='''
#include <assert.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <errno.h>
#include "nand_ecc.h"
typedef uint8_t u8;
struct mtd_info { struct { unsigned failed, corrected; } ecc_stats; };
struct nand_chip { u8 *oob_poi; };
static u8 physical_page[528], media[528];
static bool be300_nand_io_failed;
static void be300_nand_read_buf(struct mtd_info *m,u8 *p,int n) {(void)m;memcpy(p,media,n);}
static void be300_nand_write_buf(struct mtd_info *m,const u8 *p,int n) {(void)m;memcpy(media,p,n);}
'''
        code+='static int physical_read_page(struct mtd_info *mtd,struct nand_chip *chip,u8 *buf,int oob_required,int page) {'+bodies['physical_read_page']+'}\n'
        code+='static int physical_write_page(struct mtd_info *mtd,struct nand_chip *chip,const u8 *buf,int oob_required) {'+bodies['physical_write_page']+'}\n'
        code+='''
int main(void) {
 struct mtd_info m={0}; u8 oob[16],buf[512],out[512]; struct nand_chip c={oob};
 memset(oob,255,16); memset(media,255,528);
 /* A cleanmarker-only page is still erased data, with no parity. */
 media[512]=0x85;media[513]=0x19;
 assert(physical_read_page(&m,&c,out,1,320*32)==0);
 for(unsigned i=0;i<512;i++)assert(out[i]==255);
 for(unsigned i=0;i<512;i++)buf[i]=(u8)(i*17+3);
 assert(physical_write_page(&m,&c,buf,1)==0);
 /* OOB metadata changes never change the data parity domain. */
 media[512]=0x85;media[513]=0x19;media[518]=0x20;
 assert(physical_read_page(&m,&c,out,1,320*32)==0);assert(!memcmp(buf,out,512));
 media[3]^=0x73;media[409]^=0x42;
 assert(physical_read_page(&m,&c,out,1,320*32)==2);assert(!memcmp(buf,out,512));
 media[82]^=0x13;assert(physical_read_page(&m,&c,out,1,320*32)==-EBADMSG);
 be300_nand_io_failed=true;assert(physical_read_page(&m,&c,out,1,320*32)==-EIO);
 return 0;
}
'''
        with tempfile.TemporaryDirectory() as d:
            src=Path(d)/'page.c';src.write_text(code);binary=Path(d)/'page'
            subprocess.run(['cc','-std=gnu99','-Wall','-Wextra','-Wno-unused-parameter','-Werror','-I'+str(ROOT/'board/casio-be300'),str(src),str(ROOT/'board/casio-be300/nand_ecc.c'),'-o',str(binary)],check=True)
            subprocess.run([str(binary)],check=True)

if __name__=='__main__':unittest.main()
