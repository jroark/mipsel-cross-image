#!/usr/bin/env python3
"""Exercise the production PIU service and scan helpers with stopped scans."""
from pathlib import Path
import importlib.util
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('installer',ROOT/'scripts/install_board_hardware.py')
installer=importlib.util.module_from_spec(spec);spec.loader.exec_module(installer)

class TouchTests(unittest.TestCase):
    def test_scan_rearm_overrun_short_tap_and_poll(self):
        text=(ROOT/'board/casio-be300/touch_be300.c').read_text()
        source='''
#include <assert.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
typedef uint16_t u16; typedef uint32_t u32;
static unsigned cnt,status,adc,starts,acks,next_poll;
static unsigned sample[0x60/4];
static unsigned r32(unsigned long pa) {(void)pa;return 0;}
static void w32(unsigned long pa,unsigned v) { if(pa==0x0a0003c8)adc=v; }
static void w16(unsigned long pa,unsigned v) {
 if(pa==0x0a000304){status=(v&0xff00)|((status&255)&~(v&255));acks++;}
 if(pa==0x0a000300){assert(adc==3&&v==0x306);cnt=v;starts++;}
}
#define BE300_R32(pa) r32(pa)
#define BE300_W32(pa,v) w32(pa,v)
#define BE300_R16(pa) r32(pa)
#define BE300_W16(pa,v) w16(pa,v)
#define BE300_DELAY(us) ((void)(us))
#include "hardware-regs.h"
struct input_dev {int x,y,down;};
struct event {int x,y,down;}; static struct event events[32];static unsigned nevents;
struct be300_touch {struct input_dev *input;int irq,lock,poll;bool pen_down;
 int stroke_samples,first_x,first_y,win_x[3],win_y[3],win_n;bool held;int held_x,held_y,pen_x,pen_y;};
#define BE300_TOUCH_FILTER_N 3
#define BE300_TOUCH_MOVE_MIN 2
#define ABS_X 0
#define ABS_Y 1
#define ABS_PRESSURE 2
#define BTN_TOUCH 330
#define IRQ_NONE 0
#define IRQ_HANDLED 1
typedef int irqreturn_t;
#define spin_lock_irqsave(lock,flags) ((void)(lock),(flags)=0)
#define spin_unlock_irqrestore(lock,flags) ((void)(lock),(void)(flags))
#define PIU_INTREG 4
#define PIU_CNTREG 0
#define PIUCNT_PEN_DETECTED 0x2000
#define PIUINT_PADPAGE0INTR 8
#define PIUINT_PADPAGE1INTR 16
#define PIUINT_PENCHGINTR 1
#define PIU_PB00 0x20
#define PIU_PB10 0x50
#define PIU_ADC_Y_MIN 0x81e1
#define PIU_ADC_Y_MAX 0x8e30
#define PIU_ADC_X_MIN 0x8300
#define PIU_ADC_X_MAX 0x8d1b
#define BE300_TOUCH_WIDTH 240
#define BE300_TOUCH_HEIGHT 320
#define BE300_TOUCH_PANEL_HEIGHT 359
static u16 piu_read(struct be300_touch *t,unsigned off) {
 (void)t;return off==0?cnt:off==4?status:sample[off/4];
}
static void input_report_abs(struct input_dev *d,int code,int v) {if(code==0)d->x=v;if(code==1)d->y=v;}
static void input_report_key(struct input_dev *d,int code,int v) {(void)code;d->down=v;}
static void input_sync(struct input_dev *d) {assert(nevents<32);events[nevents++]=(struct event){d->x,d->y,d->down};}
static void be300_piu_ack(unsigned s) {be300_regs_piu_ack(s);}
static unsigned jiffies=100;
static unsigned msecs_to_jiffies(unsigned ms) {return ms/10;}
static void mod_timer(int *timer,unsigned when) {(void)timer;next_poll=when;}
'''
        signatures=[
            ('piu_adc_valid','static bool','u16 value,u16 min,u16 max'),
            ('piu_adc_to_pos','static int','u16 value,u16 min,u16 max,int span'),
            ('piu_adc_to_pos_inv','static int','u16 value,u16 min,u16 max,int span'),
            ('piu_decode_page','static bool','struct be300_touch *t,unsigned page_off,int *out_x,int *out_y'),
            ('be300_touch_stroke_reset','static void','struct be300_touch *t'),
            ('be300_touch_report','static void','struct be300_touch *t,int x,int y'),
            ('be300_touch_sample','static void','struct be300_touch *t,int x,int y'),
            ('be300_touch_release','static void','struct be300_touch *t'),
            ('be300_touch_report_page','static void','struct be300_touch *t,unsigned page_off'),
            ('be300_touch_isr','static irqreturn_t','int irq,void *dev'),
            ('be300_touch_poll','static void','unsigned long data')]
        for name,ret,args in signatures:
            found=[];installer.function_body(text,name,lambda b:found.append(b) or b)
            source+=ret+' '+name+'('+args+') {'+found[0]+'}\n'
        source+='''
int main(void) {
 struct input_dev input={0};struct be300_touch t={.input=&input,.irq=81};
 be300_regs_piu_start();assert(adc==3&&cnt==0x306&&(status>>8)==0xdd);
 /* Invalid ADC page: acknowledge and restart, without a false press. */
 status=0xdd09;cnt|=0x2000;assert(be300_touch_isr(81,&t)==IRQ_HANDLED);assert(!nevents);
 /* A complete short tap arrives with coordinates and pen-up together. */
 sample[0x20/4]=0x81e1;sample[0x24/4]=0x8e30;
 sample[0x28/4]=0x8300;sample[0x2c/4]=0x8d1b;
 status=0xdd09;cnt=0x306;
 assert(be300_touch_isr(81,&t)==IRQ_HANDLED);assert(nevents==2);
 assert(events[0].down==1&&events[1].down==0&&events[0].x==239&&events[0].y==0);
 assert(!(status&255)&&cnt==0x306);
 /* A stopped overrun restarts only after both page flags are cleared. */
 status=0xdd1c;cnt=0x2000;memcpy(sample+0x50/4,sample+0x20/4,4*sizeof(unsigned));
 unsigned before=starts;be300_touch_poll((unsigned long)&t);
 assert(starts==before+1&&!(status&255)&&cnt==0x306&&next_poll==102);
 before=starts;assert(be300_touch_isr(81,&t)==IRQ_NONE);assert(starts==before);
 /* A still tap on a real panel: settling and lift-off samples jump, the
  * steady ones jitter by a pixel. One press and one release, no drag. */
 cnt=0x306;status=0xdd01;cnt|=0x2000;be300_touch_isr(81,&t);  /* pen down */
 nevents=0;
 static const unsigned xs[]={0x8400,0x8700,0x8705,0x86fa,0x8702,0x8a00};
 for(unsigned i=0;i<6;i++){
  sample[0x20/4]=0x8800;sample[0x24/4]=0x8800;sample[0x28/4]=0x8d1b-(xs[i]-0x8300);sample[0x2c/4]=xs[i];
  status=0xdd08;cnt=0x2306;be300_touch_isr(81,&t);
 }
 cnt=0x306;status=0xdd01;be300_touch_isr(81,&t);               /* pen up */
 assert(nevents==2&&events[0].down==1&&events[1].down==0);
 int expect=(0x8700-0x8300)*239/(0x8d1b-0x8300);
 assert(events[0].x>=expect-2&&events[0].x<=expect+2);
 return 0;
}
'''
        with tempfile.TemporaryDirectory() as tmp:
            tmp=Path(tmp);src=tmp/'touch.c';src.write_text(source)
            subprocess.run(['cc','-std=gnu99','-Wall','-Wextra','-Werror','-Wno-unused-function','-Wno-unused-parameter',
                            '-I'+str(ROOT/'board/casio-be300'),str(src),'-o',str(tmp/'touch')],check=True)
            subprocess.run([str(tmp/'touch')],check=True)

if __name__=='__main__':unittest.main()
