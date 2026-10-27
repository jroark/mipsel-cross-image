/* Freestanding Linux OSS + WEXT + packet-socket smoke test; no ROMs. */
#include <sys/socket.h>
#include <linux/if.h>
#include <linux/wireless.h>
#include <linux/soundcard.h>
#include <linux/if_packet.h>
#include <linux/un.h>
#include <linux/random.h>
static long call(long nr, long x0, long x1, long x2, long x3, long x4, long x5)
{
	register long v0 __asm__("v0") = nr;
	register long a0 __asm__("a0") = x0;
	register long a1 __asm__("a1") = x1;
	register long a2 __asm__("a2") = x2;
	register long a3 __asm__("a3") = x3;
	__asm__ volatile("addiu $sp,$sp,-32\n\tsw %6,16($sp)\n\tsw "
			 "%7,20($sp)\n\tsyscall\n\taddiu $sp,$sp,32"
			 : "+r"(v0), "+r"(a3)
			 : "r"(a0), "r"(a1), "r"(a2), "r"(x3), "r"(x4), "r"(x5)
			 : "memory", "$1", "$3", "$8", "$9", "$10", "$11",
			   "$12", "$13", "$14", "$15", "$24", "$25", "hi",
			   "lo");
	return a3 ? -v0 : v0;
}
static unsigned len(const char *p)
{
	unsigned n = 0;
	while (p[n])
		n++;
	return n;
}
static void print(const char *p)
{
	call(4004, 1, (long)p, len(p), 0, 0, 0);
}
static long open(const char *p, long flags)
{
	return call(4005, (long)p, flags, 0, 0, 0, 0);
}
static void close(long fd)
{
	call(4006, fd, 0, 0, 0, 0, 0);
}
static void sleep_seconds(long seconds)
{
	long delay[2] = {seconds, 0};
	call(4166, (long)delay, 0, 0, 0, 0, 0);
}

void *memset(void *dst, int value, unsigned long n)
{
	unsigned char *p = dst;
	while (n--)
		*p++ = value;
	return dst;
}
void *memcpy(void *dst, const void *src, unsigned long n)
{
	unsigned char *d = dst;
	const unsigned char *s = src;
	while (n--)
		*d++ = *s++;
	return dst;
}
static unsigned short pixels[256 * 20];
static unsigned char scan[4096], frame[1600];
static short pcm[2048];
static long fb = -1;
static unsigned stage;
static void mark(unsigned n, unsigned short color)
{
	unsigned x, y;
	for (y = 0; y < 20; y++)
		for (x = 0; x < 30; x++)
			pixels[y * 256 + n * 30 + x] = color;
	if (fb >= 0) {
		call(4019, fb, 0, 0, 0, 0, 0);
		call(4004, fb, (long)pixels, sizeof(pixels), 0, 0, 0);
	}
}
static long control(long fd, long cmd, void *p)
{
	return call(4054, fd, cmd, (long)p, 0, 0, 0);
}
static void copy(void *dst, const void *src, unsigned n)
{
	unsigned char *d = dst;
	const unsigned char *s = src;
	while (n--)
		*d++ = *s++;
}
#ifdef TEST_WPA
static int contains(const char *p, unsigned n, const char *text)
{
	unsigned i, j, size = len(text);
	for (i = 0; i + size <= n; i++) {
		for (j = 0; j < size && p[i + j] == text[j]; j++)
			;
		if (j == size)
			return 1;
	}
	return 0;
}
static void save_log(void)
{
	unsigned short line[256];
	unsigned row;
	long log = open("/tmp/wpa.log", 0), n;
	if (fb < 0)
		return;
	for (row = 20; row < 320; row++) {
		memset(line, 0, sizeof(line));
		n = log < 0 ? 0 : call(4003, log, (long)line, 480, 0, 0, 0);
		if (n < 0)
			memset(line, 0, sizeof(line));
		call(4019, fb, row * 512, 0, 0, 0, 0);
		call(4004, fb, (long)line, sizeof(line), 0, 0, 0);
		if (n <= 0)
			break;
	}
	close(log);
}
static int supplicant(void)
{
	struct sockaddr_un addr;
	struct {
		int bits, bytes;
		unsigned char data[256];
	} entropy;
	char *argv[] = {
		"/sbin/wpa_supplicant",	    "-D",  "wext", "-i", "wlan0", "-c",
		"/etc/wpa_supplicant.conf", "-dd", 0};
	long child, log, fd, client, ret, n, attempt;
	int status, connected = 0;
	call(4039, (long)"/tmp", 0700, 0, 0, 0, 0);
	call(4039, (long)"/tmp/wpa", 0700, 0, 0, 0, 0);
	call(4014, (long)"/dev/urandom", 0020600, (1 << 8) | 9, 0, 0, 0);
	call(4014, (long)"/dev/random", 0020600, (1 << 8) | 8, 0, 0, 0);
	fd = open("/entropy.seed", 0);
	if (fd < 0)
		return -1;
	n = call(4003, fd, (long)entropy.data, sizeof(entropy.data), 0, 0, 0);
	close(fd);
	if (n != sizeof(entropy.data))
		return -1;
	entropy.bits = sizeof(entropy.data) * 8;
	entropy.bytes = sizeof(entropy.data);
	fd = open("/dev/random", 2);
	ret = control(fd, RNDADDENTROPY, &entropy);
	close(fd);
	if (ret < 0)
		return -1;
	child = call(4002, 0, 0, 0, 0, 0, 0);
	if (child < 0)
		return -1;
	if (!child) {
		log = call(4005, (long)"/tmp/wpa.log", 0x101, 0600, 0, 0, 0);
		if (log >= 0) {
			call(4063, log, 1, 0, 0, 0, 0);
			call(4063, log, 2, 0, 0, 0, 0);
		}
		print("AVNET: executing supplicant\n");
		call(4011, (long)argv[0], (long)argv, 0, 0, 0, 0);
		print("supplicant exec failed\n");
		call(4001, 127, 0, 0, 0, 0, 0);
		for (;;)
			;
	}
	client = call(4183, AF_UNIX, SOCK_DGRAM, 0, 0, 0, 0);
	if (client < 0)
		return -1;
	memset(&addr, 0, sizeof(addr));
	addr.sun_family = 1;
	copy(addr.sun_path, "/tmp/avnet-ctrl", 16);
	if (call(4169, client, (long)&addr, sizeof(addr), 0, 0, 0) < 0)
		return -1;
	memset(&addr, 0, sizeof(addr));
	addr.sun_family = 1;
	copy(addr.sun_path, "/tmp/wpa/wlan0", 15);
	for (attempt = 0; attempt < 40; attempt++) {
		sleep_seconds(1);
		if (!(attempt % 5))
			save_log();
		if (call(4007, child, (long)&status, 1, 0, 0, 0) == child) {
			char diagnostic[] = "AVNET: child status 00000000\n";
			unsigned i;
			for (i = 0; i < 8; i++)
				diagnostic[20 + i] = "0123456789abcdef"
					[(status >> (28 - i * 4)) & 15];
			log = open("/tmp/wpa.log", 1 | 0x8);
			if (log >= 0) {
				call(4004, log, (long)diagnostic,
				     len(diagnostic), 0, 0, 0);
				close(log);
			}
			close(client);
			return -1;
		}
		if (!connected) {
			if (call(4170, client, (long)&addr, sizeof(addr), 0, 0,
				 0) < 0)
				continue;
			connected = 1;
		}
		call(4180, client, (long)"STATUS", 6, 0, 0, 0);
		n = call(4176, client, (long)scan, sizeof(scan), 0x40, 0, 0);
		if (n > 0 && contains((char *)scan, n, "wpa_state=COMPLETED")) {
			close(client);
			return 0;
		}
	}
	close(client);
	return -1;
}
#endif
void _start(void)
{
	long console, dsp, mixer, net, raw, n, ret;
	int value, i, j, index;
	mixer_info identity;
	struct iwreq w = {0};
	struct ifreq r = {0};
	struct sockaddr_ll address = {0};
	unsigned char mac[6], arp[42] = {0};
	call(4014, (long)"/dev/console", 0020600, (5 << 8) | 1, 0, 0, 0);
	console = open("/dev/console", 2);
	if (console >= 0)
		for (i = 0; i < 3; i++)
			call(4063, console, i, 0, 0, 0, 0);
	call(4014, (long)"/dev/fb0", 0020600, (29 << 8), 0, 0, 0);
	fb = open("/dev/fb0", 2);
	mark(0, 0x001f);
	call(4014, (long)"/dev/dsp", 0020600, (14 << 8) | 3, 0, 0, 0);
	call(4014, (long)"/dev/mixer", 0020600, (14 << 8), 0, 0, 0);
	dsp = open("/dev/dsp", 1);
	mixer = open("/dev/mixer", 2);
	if (dsp < 0 || mixer < 0)
		goto fail;
	value = AFMT_S16_LE;
	if (control(dsp, SNDCTL_DSP_SETFMT, &value) < 0 || value != AFMT_S16_LE)
		goto fail;
	value = 2;
	if (control(dsp, SNDCTL_DSP_CHANNELS, &value) < 0 || value != 2)
		goto fail;
	value = 22050;
	if (control(dsp, SNDCTL_DSP_SPEED, &value) < 0 || value != 22050)
		goto fail;
	value = -1;
	if (control(dsp, SNDCTL_DSP_SPEED, &value) != -22)
		goto fail;
	value = 50 | (25 << 8);
	if (control(mixer, SOUND_MIXER_WRITE_VOLUME, &value) < 0)
		goto fail;
	if (control(mixer, SOUND_MIXER_INFO, &identity) < 0 ||
	    identity.id[0] != 'B' || identity.modify_counter < 1)
		goto fail;
	for (j = 0; j < 2; j++) {
		for (i = 0; i < 2048; i++)
			pcm[i] = (i % 2 == j)
					 ? ((i / 2) % 40 < 20 ? 8192 : -8192)
					 : 0;
		for (i = 0; i < 10; i++)
			if (call(4004, dsp, (long)pcm, sizeof(pcm), 0, 0, 0) !=
			    sizeof(pcm))
				goto fail;
	}
	if (control(dsp, SNDCTL_DSP_SYNC, 0) < 0)
		goto fail;
	value = -1;
	if (control(dsp, SNDCTL_DSP_GETODELAY, &value) < 0 || value)
		goto fail;
	close(dsp);
	close(mixer);
	mark(stage++, 0x07e0);
	print("AVNET: OSS stereo/mixer/drain PASS\n");
	net = call(4183, AF_INET, SOCK_DGRAM, 0, 0, 0, 0);
	if (net < 0)
		goto fail;
#ifdef TEST_WIRED
	copy(r.ifr_name, "eth0", 5);
#else
	copy(r.ifr_name, "wlan0", 6);
#endif
	copy(w.ifr_name, "wlan0", 6);
	if (control(net, 0x8913, &r) < 0)
		goto fail;
	r.ifr_flags |= 1;
	ret = control(net, 0x8914, &r);
	if (ret < 0)
		goto fail;
	if (control(net, 0x8927, &r) < 0)
		goto fail;
	copy(mac, r.ifr_hwaddr.sa_data, 6);
	if (control(net, 0x8933, &r) < 0)
		goto fail;
	index = r.ifr_ifindex;
	mark(stage++, 0x07e0);
	print("AVNET: interface-up PASS\n");
#ifndef TEST_WIRED
	w.u.data.pointer = 0;
	w.u.data.length = 0;
	w.u.data.flags = 0;
	if (control(net, SIOCSIWSCAN, &w) < 0)
		goto fail;
	for (i = 0; i < 10; i++) {
		sleep_seconds(1);
		w.u.data.pointer = scan;
		w.u.data.length = sizeof(scan);
		w.u.data.flags = 0;
		ret = control(net, SIOCGIWSCAN, &w);
		if (ret != -11)
			break;
	}
	if (ret < 0 || !w.u.data.length)
		goto fail;
	mark(stage++, 0x07e0);
	print("AVNET: scan PASS\n");
#ifdef TEST_WPA
	if (supplicant())
		goto fail;
	mark(stage++, 0x07e0);
	print("AVNET: WPA supplicant COMPLETED\n");
#else
#ifdef TEST_WEP
	w.u.encoding.pointer = (void *)"12345";
	w.u.encoding.length = 5;
	w.u.encoding.flags = IW_ENCODE_OPEN | 1;
	if (control(net, SIOCSIWENCODE, &w) < 0)
		goto fail;
#endif
	w.u.essid.pointer = (void *)"BE300";
	w.u.essid.length = 5;
	w.u.essid.flags = 1;
	if (control(net, SIOCSIWESSID, &w) < 0)
		goto fail;
	for (i = 0; i < 10; i++) {
		sleep_seconds(1);
		if (control(net, SIOCGIWAP, &w) < 0)
			goto fail;
		for (j = 0; j < 6; j++)
			if (w.u.ap_addr.sa_data[j])
				break;
		if (j < 6)
			break;
	}
	if (i == 10)
		goto fail;
	mark(stage++, 0x07e0);
	print("AVNET: association PASS\n");
#endif
	w.u.encoding.pointer = (void *)"12345";
	w.u.encoding.length = 5;
	w.u.encoding.flags = IW_ENCODE_OPEN | 1;
	if (control(net, SIOCSIWENCODE, &w) != -16)
		goto fail;
#else
	mark(stage++, 0x07e0);
	mark(stage++, 0x07e0);
#endif
	raw = call(4183, 17, 3, 0x0300, 0, 0, 0);
	if (raw < 0)
		goto fail;
	address.sll_family = 17;
	address.sll_protocol = 0x0300;
	address.sll_ifindex = index;
	address.sll_halen = 6;
	for (i = 0; i < 6; i++)
		address.sll_addr[i] = arp[i] = 255;
	copy(arp + 6, mac, 6);
	arp[12] = 8;
	arp[13] = 6;
	arp[15] = 1;
	arp[16] = 8;
	arp[18] = 6;
	arp[19] = 4;
	arp[21] = 1;
	copy(arp + 22, mac, 6);
	arp[28] = 10;
	arp[31] = 1;
	arp[38] = 10;
	arp[41] = 254;
	if (call(4169, raw, (long)&address, sizeof(address), 0, 0, 0) < 0)
		goto fail;
	if (call(4180, raw, (long)arp, sizeof(arp), 0, (long)&address,
		 sizeof(address)) != sizeof(arp))
		goto fail;
	mark(stage++, 0x07e0);
	print("AVNET: ARP transmit PASS\n");
	for (i = 0; i < 20; i++) {
		n = call(4176, raw, (long)frame, sizeof(frame), 0x40, 0, 0);
		if (n >= 42 && frame[12] == 8 && frame[13] == 6 &&
		    frame[21] == 2 && frame[28] == 10 && frame[31] == 254)
			break;
		sleep_seconds(1);
	}
	if (i == 20)
		goto fail;
	mark(stage++, 0x07e0);
	print("AVNET: ARP receive PASS\n");
	close(raw);
	close(net);
	mark(stage++, 0x07e0);
	mark(stage++, 0x07e0);
	print("AVNET: ALL PASS\n");
	goto wait;
fail:
	mark(stage, 0xf800);
	print("AVNET: FAIL\n");
wait:
#ifdef TEST_WPA
	save_log();
#endif
	for (;;)
		sleep_seconds(10);
}
