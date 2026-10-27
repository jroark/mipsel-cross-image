#ifndef BE300_HARDWARE_H
#define BE300_HARDWARE_H
int be300_lcd_blank(int blank);
int be300_piu_prepare(void);
void be300_giu0_prepare(void);
void be300_girq0_source_mask(unsigned int source);
void be300_girq0_source_unmask(unsigned int source);
void be300_girq0_pending_ack(unsigned int pending);
void be300_girq0_init(void);
#endif
