#ifndef BE300_HARDWARE_H
#define BE300_HARDWARE_H
int be300_lcd_blank(int blank);
int be300_piu_prepare(void);
void be300_piu_start(void);
void be300_piu_ack(unsigned int status);
void be300_giu0_prepare(void);
void be300_girq0_source_mask(unsigned int source);
void be300_girq0_source_unmask(unsigned int source);
void be300_girq0_pending_ack(unsigned int pending);
void be300_girq0_init(void);
/* Before the first companion SIU access: powers its units on if needed. */
void be300_console_ready(void);
/* Linux 2.4 registers fbcon before the board initcall runs. */
void be300_framebuffer_ready(void);
/* Configure socket 0's card (ATA or I/O COR) from its CIS. */
int be300_card_configure(void);
/* Write a card configuration register at attribute address attr. */
void be300_card_write_cor(unsigned int attr, unsigned int cor);
/* Stop the power MCU watchdog before halt, power-off or sleep. */
void be300_cmcu_shutdown(void);
#endif
