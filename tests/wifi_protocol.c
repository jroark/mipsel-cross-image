/* Exercise the production station protocol against independent card models.
 * Build with be300/src/hw/{xi825,wl54cf,wifi_security}.c, not guest assets.
 */
#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "hw/xi825.h"
#include "hw/wl54cf.h"
typedef uint8_t u8;
typedef uint16_t u16;
static xi825_t prism;
static wl54cf_t marvell;
static int kind, unplugged, corrupt;
static unsigned long delays;
static uint8_t sent[1600];
static size_t sent_n;
static unsigned read_io(unsigned r, unsigned width)
{
	if (unplugged)
		return width == 1 ? 255 : 65535;
	if (kind == 1) {
		xi825_tick(&prism);
		return xi825_read(&prism, r, width);
	}
	if (corrupt && r == 0x12 && marvell.response.pos == 4) {
		corrupt = 0;
		return wl54cf_read(&marvell, r, width) ^ 1;
	}
	return wl54cf_read(&marvell, r, width);
}
static void write_io(unsigned r, unsigned width, unsigned value)
{
	if (kind == 1)
		xi825_write(&prism, r, width, value);
	else
		wl54cf_write(&marvell, r, width, value);
}
#define WIFI_R8(r) read_io(r, 1)
#define WIFI_R16(r) read_io(r, 2)
#define WIFI_W8(r, v) write_io(r, 1, v)
#define WIFI_W16(r, v) write_io(r, 2, v)
#define WIFI_DELAY(us) (delays += (us))
#include "../board/casio-be300/wifi-proto.h"
static void capture(void *unused, const uint8_t *data, size_t n)
{
	assert(n <= sizeof(sent));
	memcpy(sent, data, n);
	sent_n = n;
}
static void prism_events(struct bw_state *state)
{
	unsigned i;
	for (i = 0; i < 16; i++) {
		xi825_tick(&prism);
		if (!(WIFI_R16(0x30) & 128))
			break;
		bx_information(state);
		WIFI_W16(0x34, 128);
	}
}
int main(void)
{
	static struct bw_state state;
	static const uint8_t mac[] = {2, 0, 0, 0, 0, 1};
	uint8_t helper[256] = {0}, firmware[34] = {0},
		frame[BW_MAX_FRAME] = {0};
	kind = 1;
	xi825_init(&prism, mac);
	prism.transmit = capture;
	assert(!bx_init(&state));
	assert(!memcmp(mac, state.mac, 6));
	assert(!bx_scan(&state));
	prism_events(&state);
	assert(!state.scanning && state.count && state.aps[0].ssid_len == 5);
	memcpy(state.ssid, "BE300", 5);
	state.ssid_len = 5;
	assert(!bx_connect(&state));
	prism_events(&state);
	assert(state.connected);
	memset(frame, 255, 6);
	memcpy(frame + 6, mac, 6);
	frame[12] = 8;
	frame[13] = 6;
	assert(!bx_send(&state, frame, 60));
	assert(sent_n == 60 && !memcmp(sent, frame, 60));
	frame[60] = 0x7f;
	assert(!bx_send(&state, frame, 61) && sent_n == 61 &&
	       !memcmp(sent, frame, 61));
	assert(!bx_send(&state, frame, sizeof(frame)) &&
	       sent_n == sizeof(frame) && !memcmp(sent, frame, sizeof(frame)));
	assert(bx_send(&state, frame, 13) == -EINVAL);
	assert(bx_send(&state, frame, sizeof(frame) + 1) == -EINVAL);
	assert(bx_bap(1, 4094, frame, 4, 0) == -EINVAL);
	assert(bx_bap(1, 1, frame, 2, 0) == -EINVAL);
	assert(wifi_security_configure(&prism.security, 1, "12345"));
	memcpy(state.keys[0], "12345", 5);
	state.key_len[0] = 5;
	assert(!bx_connect(&state));
	prism_events(&state);
	assert(state.connected);
	memcpy(state.keys[0], "wrong", 5);
	assert(!bx_connect(&state));
	prism_events(&state);
	assert(!state.connected);
	unplugged = 1;
	assert(bx_command(0, 0) == -ENODEV);
	unplugged = 0;

	memset(&state, 0, sizeof(state));
	kind = 2;
	wl54cf_init(&marvell, mac);
	marvell.transmit = capture;
	firmware[0] = 1;
	firmware[8] = 2;
	firmware[18] = 4;
	assert(!bm_firmware(helper, sizeof(helper), firmware,
			    sizeof(firmware)));
	assert(!bm_init(&state));
	assert(!memcmp(state.mac, mac, 6));
	corrupt = 1;
	assert(bm_command(&state, 3, 46) == -EIO);
	assert(!bm_scan(&state));
	assert(state.count && !state.scanning);
	memcpy(state.ssid, "BE300", 5);
	state.ssid_len = 5;
	assert(!bm_connect(&state));
	assert(state.connected);
	sent_n = 0;
	assert(!bm_send(&state, frame, 60));
	assert(sent_n == 60 && !memcmp(sent, frame, 60));
	assert(!bm_send(&state, frame, 61) && sent_n == 61 &&
	       !memcmp(sent, frame, 61));
	assert(!bm_send(&state, frame, sizeof(frame)) &&
	       sent_n == sizeof(frame) && !memcmp(sent, frame, sizeof(frame)));
	assert(bm_send(&state, frame, 13) == -EINVAL);
	assert(bm_send(&state, frame, sizeof(frame) + 1) == -EINVAL);
	assert(wifi_security_configure(&marvell.security, 1, "12345"));
	memcpy(state.keys[0], "12345", 5);
	state.key_len[0] = 5;
	assert(!bm_connect(&state));
	assert(state.connected);
	memcpy(state.keys[0], "wrong", 5);
	assert(bm_connect(&state) < 0 && !state.connected);
	assert(!bm_disconnect(&state));
	unplugged = 1;
	assert(bm_command(&state, 3, 46) == -ENODEV);
	unplugged = 0;
	wl54cf_reset(&marvell);
	delays = 0;
	assert(bm_command(&state, 3, 46) == -ETIMEDOUT && delays == 500000);
	assert(bm_firmware(helper, 3, firmware, sizeof(firmware)) == -EINVAL);
	puts("PRISM/CF8385 init, scan, open/WEP, byte-exact TX, removal and "
	     "bounded failures passed");
	return 0;
}
