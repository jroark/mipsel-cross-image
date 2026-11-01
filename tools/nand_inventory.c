/* SPDX-License-Identifier: GPL-2.0-only
 * From jroark/glaze-os, GPLv2 reuse authorized by John Roark, 2026-10-31.
 */
/* Local raw-image inspection and encoding. Never opens a hardware device. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../board/casio-be300/nand_boot.h"
#include "../board/casio-be300/nand_ecc.h"
static int raw_read(void *ctx, uint32_t p, uint8_t raw[528])
{
    FILE *f = ctx;
    return fseek(f, (long)p * 528, SEEK_SET) || fread(raw,1,528,f) != 528 ? -1 : 0;
}
/* The masked ROM cannot use our manifest before loading the SPL. Check
 * its tag quorum separately, so preserved stale SPL tags cannot be hidden
 * by the later protected-map policy. Refuse ambiguous placement. */
static uint32_t le32(const uint8_t *p)
{
    return p[0] | (uint32_t)p[1]<<8 | (uint32_t)p[2]<<16 | (uint32_t)p[3]<<24;
}
static int rom_spl(FILE *f)
{
    uint8_t raw[528];
    uint16_t map[4] = {0xffff,0xffff,0xffff,0xffff};
    if (raw_read(f,0,raw) || nand_ecc_check(raw)<0) return 1;
    uint32_t start=le32(raw+24), count=le32(raw+28);
    if (start<32 || !count || start+count>160) return 1;
    unsigned first=start/32, last=(start+count-1)/32;
    for (unsigned phys=0;phys<1024;phys++) {
        uint32_t ids[5]; unsigned n=0;
        for (unsigned p=0;p<5;p++) {
            if (raw_read(f,phys*32+p,raw) || nand_ecc_check(raw)<0) continue;
            if (raw[512]==0xaa && raw[513]==0x55 && raw[514]==0x0f)
                ids[n++]=le32(raw+516);
        }
        for (unsigned i=0;i<n;i++) {
            unsigned votes=0;
            for (unsigned j=0;j<n;j++) votes+=ids[i]==ids[j];
            if (votes<3 || ids[i]<first || ids[i]>last) continue;
            unsigned slot=ids[i]-1;
            if (map[slot]!=0xffff) return 1;
            map[slot]=(uint16_t)phys;
            break;
        }
    }
    for (unsigned page=start;page<start+count;page++) {
        if (map[page/32-1]==0xffff ||
            raw_read(f,map[page/32-1]*32+page%32,raw) || nand_ecc_check(raw)<0) return 1;
        if (page==start && memcmp(raw,"B000FF\n",7)) return 1;
    }
    return 0;
}
int main(int argc, char **argv)
{
    if (argc == 2 && !strcmp(argv[1], "--encode")) {
        uint8_t raw[528]; size_t n;
        while ((n=fread(raw,1,520,stdin))) {
            if (n != 520) return 2;
            nand_ecc_encode(raw);
            if (fwrite(raw,1,528,stdout) != 528) return 2;
        }
        return ferror(stdin) ? 2 : 0;
    }
    bool check = argc == 3 && !strcmp(argv[1], "--check-boot");
    if (!(argc == 2 || check)) return 2;
    FILE *f = fopen(argv[check ? 2 : 1], "rb");
    if (!f || fseek(f,0,SEEK_END) || ftell(f) != 1024L*32*528) return 2;
    if (check && rom_spl(f)) {
        fputs("ROM SPL placement is missing, corrupt or ambiguous\n",stderr); return 1;
    }
    static struct nand_boot_map map;
    if (nand_boot_scan(&map,raw_read,f,false)) return 1;
    if (check) {
        uint8_t data[512];
        for (unsigned p=0;p<NAND_BOOT_BLOCKS*32;p++)
            if (nand_boot_read(&map,raw_read,f,p,data,false)) return 1;
    } else if (fwrite(map.quarantine,1,128,stdout) != 128) return 2;
    fclose(f);
    return 0;
}
