/* Native checks of the production Casio codec/power transactions. */
#include <assert.h>
#include <errno.h>
#include <stdio.h>
static unsigned int regs[0x1200 / 4], commands[16], command_count;
static unsigned long elapsed;
static int busy, busy_after;
static unsigned int read_reg(unsigned int offset)
{
	if (offset == 0x3c4)
		return !busy;
	return regs[offset / 4];
}
static void write_reg(unsigned int offset, unsigned int value)
{
	regs[offset / 4] = value;
	if (offset == 0x3c0) {
		assert(command_count < 16);
		commands[command_count++] = value;
		if (busy_after)
			busy = 1;
	}
}
#define AUDIO_R(off) read_reg(off)
#define AUDIO_W(off, v) write_reg(off, v)
#define AUDIO_R16(off) read_reg(off)
#define AUDIO_W16(off, v) write_reg(off, (v) & 65535)
#define AUDIO_DELAY(us) (elapsed += (us))
#include "../board/casio-be300/audio-regs.h"
int main(void)
{
	static const unsigned int rates[] = {8000,  11025, 16000,
					     22050, 32000, 44100};
	static const unsigned int codes[] = {0x40, 0x10, 0x30, 0, 0x30, 0};
	unsigned int i, code, x2;
	for (i = 0; i < 6; i++) {
		assert(audio_rate(rates[i], &code, &x2) == rates[i] &&
		       code == codes[i] && x2 == (i >= 4));
		command_count = 0;
		elapsed = 0;
		assert(!audio_prepare(rates[i], i & 1 ? 1 : 2));
		assert(command_count == 4 && commands[0] == 0x5000);
		assert(commands[2] == (0xd007U | ((i >= 4) << 7)) &&
		       commands[3] == (0xd001U | ((i >= 4) << 7)));
		assert((regs[0x880 / 4] & 0x70) == codes[i] &&
		       (regs[0x884 / 4] & 3) == 3);
		assert(!!(regs[0x888 / 4] & 2) == !!(i & 1) && elapsed >= 6000);
		regs[0x30 / 4] = 0xcc;
		regs[0x898 / 4] = 1;
		regs[0x8a0 / 4] = 1;
		audio_disable();
		assert(regs[0x30 / 4] == 0xc4 && !regs[0x898 / 4] &&
		       !regs[0x8a0 / 4]);
		assert(!(regs[0x880 / 4] & 8) && !(regs[0x890 / 4] & 2));
	}
	busy = 1;
	command_count = 0;
	elapsed = 0;
	assert(audio_codec(0xd007) == -ETIMEDOUT && !command_count &&
	       elapsed == 10000);
	busy = 0;
	busy_after = 1;
	elapsed = 0;
	assert(audio_prepare(22050, 2) == -ETIMEDOUT && elapsed == 11000);
	assert(!regs[0x8a0 / 4] && !(regs[0x880 / 4] & 8));
	puts("Casio six-rate mono/stereo codec setup, delays, stop and bounded "
	     "pre/post timeout passed");
	return 0;
}
