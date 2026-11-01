/* SPDX-License-Identifier: GPL-3.0-only */
/* Standalone Glaze repair integration, using its production driver and the
 * independent emulator controller. Never opens a physical device. */
#include GLAZE_CLIENT_HEADER
#include <stdlib.h>
#include <unistd.h>
#include <sys/select.h>
#define select nand_driver_select
#define main glaze_controller_fixture_main
#include GLAZE_NAND_PROGRAM_TEST
#undef main
#undef select
static unsigned completed,order[1024];
int gu_call(struct gu_client *c,uint32_t op,const void *data,uint32_t n)
{
 const uint8_t *b=data;
 if(op==GU_NAND_READ) {
  assert(n==8);unsigned page=gu_get32(b),count=gu_get32(b+4);
  assert(count&&count<=7&&page+count<=32768);
  for(unsigned i=0;i<count;i++){nand_read_raw(page+i,c->frame+GU_HEADER+i*528);flush();}
  return count*528;
 }
 assert(op==GU_NAND_REPAIR&&n>=4);
 unsigned command=gu_get32(b);int r=repair_op(command,b+4,n-4);
 if(!r&&command==GZ_NAND_REPAIR_BLOCK)order[completed]=gu_get32(b+4);
 if(!r&&command==GZ_NAND_REPAIR_COMMIT)completed++;
 return r;
}
static void read_exact(const char *path,uint8_t *b)
{FILE *f=fopen(path,"rb");assert(f&&fread(b,1,32768u*528u,f)==32768u*528u&&fgetc(f)==EOF);fclose(f);}
static void matches(const uint8_t *raw)
{for(unsigned p=0;p<32768;p++){assert(!memcmp(model.image+p*512,raw+p*528,512));assert(!memcmp(model.oob+p*16,raw+p*528+512,16));}}
int main(int argc,char **argv)
{
 assert(argc==5);size_t size=32768u*528u;
 uint8_t *source=malloc(size),*target=malloc(size),*image=malloc(NAND_IMAGE_SIZE),*oob=malloc(NAND_OOB_IMAGE_SIZE);
 assert(source&&target&&image&&oob);read_exact(argv[1],source);read_exact(argv[2],target);
 for(unsigned p=0;p<32768;p++){memcpy(image+p*512,source+p*528,512);memcpy(oob+p*16,source+p*528+512,16);}
 nand_init(&model,image,NAND_IMAGE_SIZE,NAND_IMAGE_SIZE);model.oob=oob;nand_reset();flush();
 unsigned changed=0;
 for(unsigned b=0;b<1024;b++)changed+=memcmp(source+b*32*528,target+b*32*528,32*528)!=0;
 struct gu_client c={.caps=GU_CAP_NAND_REPAIR|GU_CAP_NAND_BACKUP};
 assert(!gu_nand_apply(&c,argv[1],argv[2],argv[3],false));matches(target);assert(completed==changed);
 if (changed && memcmp(source,target,32*528)) assert(order[changed-1]==0);
 for(unsigned i=1;i<completed;i++)assert(order[i-1]>order[i]);
 completed=0;assert(!gu_nand_apply(&c,argv[2],argv[1],argv[4],false));matches(source);assert(completed==changed);
 if (changed && memcmp(source,target,32*528)) assert(order[changed-1]==0);
 for(unsigned i=1;i<completed;i++)assert(order[i-1]>order[i]);
 free(source);free(target);free(image);free(oob);
 puts("Linux install/restore through production CLI, kernel repair, NAND driver and independent emulator controller: every data and spare byte PASS");return 0;
}
