/* SPDX-License-Identifier: GPL-2.0-only
 * Station interfaces: PRISM HFA384x (Linux hostap/hermes definitions) and
 * Marvell CF8385 (Linux libertas if_cs/host definitions). No embedded ROMs.
 * Called only with the Linux adapter's sleeping lock held, never in an ISR.
 */
#ifndef BE300_WIFI_PROTO_H
#define BE300_WIFI_PROTO_H
#define BW_XI825 1
#define BW_WL54 2
#define BW_MAX_FRAME 1514
#define BW_MAX_AP 16
struct bw_ap {
	u8 ssid[32], ssid_len, bssid[6], channel;
	u16 capability, signal, noise;
	u8 rates[14], nrates, ie[80], ie_len;
};
struct bw_state {
	int kind, connected, scanning, initialized;
	u8 mac[6], ssid[32], ssid_len, bssid[6];
	u8 keys[4][13], key_len[4], key_index, shared_auth;
	unsigned int count, sta_version;
	u16 tx_fid, sequence;
	struct bw_ap aps[BW_MAX_AP];
	u8 command[512], packet[2048];
};
#ifndef WIFI_R16
#define WIFI_R8(r) readb((void __iomem *)(0xaa00c300UL + (r)))
#define WIFI_R16(r) readw((void __iomem *)(0xaa00c300UL + (r)))
#define WIFI_W8(r, v) writeb((v), (void __iomem *)(0xaa00c300UL + (r)))
#define WIFI_W16(r, v) writew((v), (void __iomem *)(0xaa00c300UL + (r)))
#define WIFI_DELAY(us) udelay(us)
#endif
static u16 bw_get16(const u8 *p)
{
	return p[0] | ((u16)p[1] << 8);
}
static void bw_put16(u8 *p, unsigned int n)
{
	p[0] = n;
	p[1] = n >> 8;
}
static void bw_put32(u8 *p, unsigned int n)
{
	bw_put16(p, n);
	bw_put16(p + 2, n >> 16);
}
static int bw_wait(unsigned int reg, u16 mask, u16 wanted, unsigned int us)
{
	u16 word;
	while (us >= 10) {
		word = WIFI_R16(reg);
		if (word == 0xffff)
			return -ENODEV;
		if ((word & mask) == wanted)
			return 0;
		WIFI_DELAY(10);
		us -= 10;
	}
	return -ETIMEDOUT;
}
static void bw_fifo_write(unsigned int reg, const u8 *bytes, unsigned int n)
{
	while (n >= 2) {
		WIFI_W16(reg, bw_get16(bytes));
		bytes += 2;
		n -= 2;
	}
	if (n)
		WIFI_W8(reg, *bytes);
}
static void bw_fifo_read(unsigned int reg, u8 *bytes, unsigned int n)
{
	while (n >= 2) {
		bw_put16(bytes, WIFI_R16(reg));
		bytes += 2;
		n -= 2;
	}
	if (n)
		*bytes = WIFI_R8(reg);
}
static int bx_command(u16 opcode, u16 parameter)
{
	int ret;
	unsigned int us = (opcode & 63) ? 500000 : 2000000;
	ret = bw_wait(0, 0x8000, 0, us);
	if (ret)
		return ret;
	WIFI_W16(0x34, 16);
	WIFI_W16(2, parameter);
	WIFI_W16(0, opcode);
	ret = bw_wait(0x30, 16, 16, us);
	if (ret)
		return ret;
	parameter = WIFI_R16(8);
	WIFI_W16(0x34, 16);
	return (parameter & 0x7f00) || (parameter & 63) != (opcode & 63) ? -EIO
									 : 0;
}
static int bx_bap(u16 fid, unsigned int offset, u8 *data, unsigned int n,
		  int write)
{
	int ret;
	if ((offset & 1) || offset > 4096 || n > 4096 - offset)
		return -EINVAL;
	WIFI_W16(0x18, fid);
	WIFI_W16(0x1c, offset);
	ret = bw_wait(0x1c, 0x8000, 0, 500000);
	if (ret)
		return ret;
	if (WIFI_R16(0x1c) & 0x4000)
		return -EIO;
	if (write)
		bw_fifo_write(0x36, data, n);
	else
		bw_fifo_read(0x36, data, n);
	return WIFI_R16(0x1c) & 0x4000 ? -EIO : 0;
}
static int bx_read(u16 rid, u8 *value, unsigned int n)
{
	u8 header[4];
	unsigned int words;
	int ret = bx_command(0x21, rid);
	if (!ret)
		ret = bx_bap(rid, 0, header, 4, 0);
	if (ret)
		return ret;
	words = bw_get16(header);
	if (!words || words > 63 || bw_get16(header + 2) != rid ||
	    (words - 1) * 2 < n)
		return -EIO;
	return bx_bap(rid, 4, value, n, 0);
}
static int bx_write(u16 rid, const u8 *value, unsigned int n)
{
	u8 record[128];
	int ret;
	if (n > 124)
		return -EINVAL;
	memset(record, 0, sizeof(record));
	bw_put16(record, 1 + (n + 1) / 2);
	bw_put16(record + 2, rid);
	memcpy(record + 4, value, n);
	ret = bx_bap(rid, 0, record, 4 + ((n + 1) & ~1U), 1);
	memset(record, 0, sizeof(record));
	return ret ? ret : bx_command(0x121, rid);
}
static int bx_scalar(u16 rid, u16 word)
{
	u8 bytes[2];
	bw_put16(bytes, word);
	return bx_write(rid, bytes, 2);
}
static int bx_init(struct bw_state *s)
{
	u8 identity[8];
	int ret;
	WIFI_W16(0x32, 0);
	ret = bx_command(0, 0);
	if (!ret)
		ret = bx_read(0xfc01, s->mac, 6);
	if (!ret && !bx_read(0xfd20, identity, 8))
		s->sta_version = ((unsigned int)bw_get16(identity + 4) << 16) |
				 (bw_get16(identity + 6) << 8) |
				 bw_get16(identity + 2);
	if (!ret)
		ret = bx_scalar(0xfc00, 1);
	if (!ret)
		ret = bx_scalar(0xfc28, 0);
	if (!ret)
		ret = bx_command(0x0a, sizeof(s->packet));
	if (!ret)
		ret = bw_wait(0x30, 8, 8, 500000);
	if (!ret) {
		s->tx_fid = WIFI_R16(0x22);
		WIFI_W16(0x34, 8);
	}
	return ret;
}
static int bx_scan(struct bw_state *s)
{
	u8 request[38];
	int ret;
	/* Enabling an unmatched SSID allows scanning without joining an AP. */
	if (!s->connected) {
		memset(request, 0xa5, sizeof(request));
		bw_put16(request, 32);
		ret = bx_write(0xfc02, request, 34);
		if (!ret)
			ret = bx_command(1, 0);
		if (ret)
			return ret;
	}
	s->count = 0;
	s->scanning = 1;
	ret = -EOPNOTSUPP;
	if (s->sta_version >= 0x010301) {
		memset(request, 0, sizeof(request));
		bw_put16(request, 0x3fff);
		bw_put16(request + 2, 1);
		ret = bx_write(0xfce5, request, sizeof(request));
	}
	if (ret)
		ret = bx_command(0x11, 0xf101);
	if (ret)
		s->scanning = 0;
	return ret;
}
static int bx_connect(struct bw_state *s)
{
	u8 value[34];
	unsigned int i, n = s->key_len[s->key_index];
	int ret = bx_command(2, 0);
	s->connected = 0;
	/* Default key records must all have the same length on PRISM. */
	for (i = 0; i < 4 && !ret; i++) {
		memset(value, 0, sizeof(value));
		if (s->key_len[i])
			memcpy(value, s->keys[i], s->key_len[i]);
		ret = bx_write(0xfc24 + i, value, n == 13 ? 14 : 6);
	}
	memset(value, 0, sizeof(value));
	if (!ret)
		ret = bx_scalar(0xfc23, s->key_index);
	if (!ret)
		ret = bx_scalar(0xfc2a, s->shared_auth ? 2 : 1);
	if (!ret)
		ret = bx_scalar(0xfc28, n ? 3 : 0);
	bw_put16(value, s->ssid_len);
	memcpy(value + 2, s->ssid, s->ssid_len);
	if (!ret)
		ret = bx_write(0xfc02, value, 34);
	return ret ? ret : bx_command(1, 0);
}
static void bx_information(struct bw_state *s)
{
	u8 header[4], *p;
	u16 fid = WIFI_R16(0x10), type;
	unsigned int words, n, size, offset, ssid_len;
	struct bw_ap *ap;
	if (bx_bap(fid, 0, header, 4, 0))
		return;
	words = bw_get16(header);
	type = bw_get16(header + 2);
	if (!words || words > 800)
		return;
	n = (words - 1) * 2;
	if (bx_bap(fid, 4, s->packet, n, 0))
		return;
	if (type == 0xf200 && n >= 2) {
		words = bw_get16(s->packet);
		s->connected = words == 1 || words == 5;
		if (s->connected)
			(void)bx_read(0xfd42, s->bssid, 6);
		return;
	}
	if ((type != 0xf101 && type != 0xf103) || n < 4)
		return;
	size = type == 0xf103 ? bw_get16(s->packet) : 62;
	if (size != (type == 0xf103 ? 64 : 62) || (n - 4) % size)
		return;
	s->count = 0;
	for (offset = 4; offset + size <= n && s->count < BW_MAX_AP;
	     offset += size) {
		p = s->packet + offset;
		ssid_len = bw_get16(p + 16);
		if (ssid_len > 32 || !ssid_len)
			continue;
		ap = &s->aps[s->count++];
		memset(ap, 0, sizeof(*ap));
		ap->channel = bw_get16(p);
		ap->noise = bw_get16(p + 2);
		ap->signal = bw_get16(p + 4);
		memcpy(ap->bssid, p + 6, 6);
		ap->capability = bw_get16(p + 14);
		ap->ssid_len = ssid_len;
		memcpy(ap->ssid, p + 18, ssid_len);
	}
	s->scanning = 0;
}
static int bx_send(struct bw_state *s, const u8 *frame, unsigned int n)
{
	unsigned int payload = n - 14 + 8;
	int ret;
	if (n < 14 || n > BW_MAX_FRAME)
		return -EINVAL;
	memset(s->packet, 0, 68);
	bw_put16(s->packet + 12, 6);
	bw_put16(s->packet + 44, payload);
	memcpy(s->packet + 46, frame, 12);
	s->packet[58] = payload >> 8;
	s->packet[59] = payload;
	s->packet[60] = 0xaa;
	s->packet[61] = 0xaa;
	s->packet[62] = 3;
	memcpy(s->packet + 66, frame + 12, n - 12);
	ret = bx_bap(s->tx_fid, 0, s->packet, 60 + payload, 1);
	if (ret)
		return ret;
	WIFI_W16(0x34, 6);
	ret = bx_command(0x10b, s->tx_fid);
	if (!ret)
		ret = bw_wait(0x30, 8, 8, 500000);
	if (!ret && WIFI_R16(0x22) != s->tx_fid)
		ret = -EIO;
	if (WIFI_R16(0x30) & 4)
		ret = -EIO;
	WIFI_W16(0x34, 14);
	return ret;
}
/* Marvell command FIFO. Response length includes the transport's 8-byte
 * trailer; header size and command identity must be validated independently. */
static void bm_signal(u16 bits)
{
	WIFI_W16(0, bits);
	WIFI_W16(2, bits);
}
static int bm_command(struct bw_state *s, u16 opcode, unsigned int n)
{
	unsigned int us, count, length;
	u16 returned;
	int ret;
	if (n < 8 || n > sizeof(s->command))
		return -EINVAL;
	ret = bw_wait(0x20, 4, 4, 500000);
	if (ret)
		return ret;
	bw_put16(s->command, opcode);
	bw_put16(s->command + 2, n);
	bw_put16(s->command + 4, ++s->sequence);
	bw_put16(s->command + 6, 0);
	WIFI_W16(0x18, n);
	bw_fifo_write(0x1a, s->command, n);
	bm_signal(4);
	us = opcode == 6 || opcode == 0x11 || opcode == 0x50 ? 3000000 : 500000;
	ret = bw_wait(0x22, 8, 8, us);
	if (ret)
		return ret;
	count = 0;
	while (us >= 10) {
		if ((WIFI_R16(0x20) & 8) && (count = WIFI_R16(0x30)))
			break;
		WIFI_DELAY(10);
		us -= 10;
	}
	if (count < 16 || count > sizeof(s->packet)) {
		WIFI_W16(0x22, 8);
		return -EIO;
	}
	bw_fifo_read(0x12, s->packet, count);
	WIFI_W16(0x22, 8);
	length = bw_get16(s->packet + 2);
	returned = bw_get16(s->packet);
	if ((returned != (opcode | 0x8000) &&
	     !(opcode == 0x50 && returned == 0x8012)) ||
	    bw_get16(s->packet + 4) != s->sequence || bw_get16(s->packet + 6) ||
	    length < 8 || length > count - 8)
		return -EIO;
	return length;
}
static int bm_firmware(const u8 *helper, unsigned int hn, const u8 *main,
		       unsigned int mn)
{
	unsigned int pos, n, previous = 0, retries = 0;
	int ret;
	if (WIFI_R8(0x3f) == 0x5a)
		return 0;
	if (!hn || hn > 65536 || (hn & 1) || !mn || mn > 512 * 1024 || (mn & 1))
		return -EINVAL;
	for (pos = 0; pos < hn; pos += n) {
		n = hn - pos;
		if (n > 256)
			n = 256;
		WIFI_W16(0x18, n);
		bw_fifo_write(0x1a, helper + pos, n);
		bm_signal(4);
		ret = bw_wait(0x20, 4, 4, 500000);
		if (ret)
			return ret;
	}
	WIFI_W16(0x18, 0);
	bm_signal(4);
	ret = bw_wait(0x20, 4, 4, 500000);
	if (ret)
		return ret;
	ret = bw_wait(0x28, 0xffff, 16, 500000);
	if (ret)
		return ret;
	pos = 0;
	while (pos < mn) {
		n = WIFI_R16(0x28);
		if (n & 1) {
			n &= ~1U;
			if (!previous || previous > pos || previous != n ||
			    ++retries > 20)
				return -EIO;
			pos -= previous;
		} else
			retries = 0;
		if (!n || n > 2048 || n > mn - pos)
			return -EIO;
		WIFI_W16(0x18, n);
		bw_fifo_write(0x1a, main + pos, n);
		bm_signal(4);
		ret = bw_wait(0x20, 4, 4, 500000);
		if (ret)
			return ret;
		pos += n;
		previous = n;
	}
	return bw_wait(0x3e, 0xff00, 0x5a00, 500000);
}
static int bm_scan(struct bw_state *s)
{
	static const u8 rates[] = {0x82, 0x84, 0x8b, 0x96, 0x0c, 0x12,
				   0x18, 0x24, 0x30, 0x48, 0x60, 0x6c};
	unsigned int first, i, p, end, offset, len, stop, tag, size,
		descriptors;
	u8 *b = s->packet, *c = s->command;
	struct bw_ap ap;
	int ret;
	s->scanning = 1;
	s->count = 0;
	for (first = 1; first <= 11; first += 4) {
		memset(c, 0, sizeof(s->command));
		c[8] = 3;
		p = 15;
		bw_put16(c + p, 0);
		p += 4;
		size = first == 9 ? 3 : 4;
		bw_put16(c + p, 0x101);
		bw_put16(c + p + 2, size * 7);
		p += 4;
		for (i = 0; i < size; i++) {
			c[p + 1] = first + i;
			bw_put16(c + p + 5, 100);
			p += 7;
		}
		bw_put16(c + p, 1);
		bw_put16(c + p + 2, sizeof(rates));
		memcpy(c + p + 4, rates, sizeof(rates));
		p += 4 + sizeof(rates);
		ret = bm_command(s, 6, p);
		if (ret < 11) {
			s->scanning = 0;
			return ret < 0 ? ret : -EIO;
		}
		len = bw_get16(b + 8);
		if (len > (unsigned int)ret - 11) {
			s->scanning = 0;
			return -EIO;
		}
		end = 11 + len;
		offset = 11;
		descriptors = b[10];
		for (i = 0; i < descriptors; i++) {
			if (offset + 2 > end)
				goto malformed;
			len = bw_get16(b + offset);
			offset += 2;
			if (len < 19 || len > end - offset)
				goto malformed;
			stop = offset + len;
			memset(&ap, 0, sizeof(ap));
			memcpy(ap.bssid, b + offset, 6);
			ap.signal = b[offset + 6];
			ap.capability = bw_get16(b + offset + 17);
			p = offset + 19;
			while (p < stop) {
				if (stop - p < 2)
					goto malformed;
				tag = b[p++];
				len = b[p++];
				if (len > stop - p)
					goto malformed;
				if (!tag && len && len <= 32) {
					ap.ssid_len = len;
					memcpy(ap.ssid, b + p, len);
				}
				if (tag == 3 && len == 1)
					ap.channel = b[p];
				if (tag == 1 || tag == 50) {
					for (size = 0;
					     size < len && ap.nrates < 14;
					     size++)
						ap.rates[ap.nrates++] =
							b[p + size];
				}
				if ((tag == 48 || tag == 221) && len <= 78) {
					ap.ie_len = len + 2;
					memcpy(ap.ie, b + p - 2, len + 2);
				}
				p += len;
			}
			if (ap.ssid_len && s->count < BW_MAX_AP) {
				for (p = 0;
				     p < s->count &&
				     memcmp(ap.bssid, s->aps[p].bssid, 6);
				     p++)
					;
				if (p == s->count)
					s->aps[s->count++] = ap;
			}
			offset = stop;
		}
	}
	s->scanning = 0;
	return 0;
malformed:
	s->count = 0;
	s->scanning = 0;
	return -EIO;
}
static int bm_setting(struct bw_state *s, u16 op, u16 a, u16 b)
{
	memset(s->command, 0, 12);
	bw_put16(s->command + 8, a);
	bw_put16(s->command + 10, b);
	return bm_command(s, op, 12) < 0 ? -EIO : 0;
}
static int bm_init(struct bw_state *s)
{
	int ret;
	WIFI_W16(4, 31);
	WIFI_W16(0x22, 31);
	memset(s->command, 0, 46);
	ret = bm_command(s, 3, 46);
	if (ret != 46)
		return ret < 0 ? ret : -EIO;
	memcpy(s->mac, s->packet + 16, 6);
	return bm_setting(s, 0x1c, 1, 1);
}
static int bm_disconnect(struct bw_state *s)
{
	int ret;
	memset(s->command, 0, 16);
	memcpy(s->command + 8, s->bssid, 6);
	bw_put16(s->command + 14, 3);
	ret = bm_command(s, 0x24, 16);
	s->connected = 0;
	memset(s->bssid, 0, 6);
	return ret < 0 ? ret : 0;
}
static int bm_connect(struct bw_state *s)
{
	struct bw_ap *ap = NULL;
	u8 *c = s->command;
	unsigned int i, n = s->key_len[s->key_index], p;
	int ret;
	(void)bm_disconnect(s);
	ret = bm_scan(s);
	if (ret)
		return ret;
	for (i = 0; i < s->count; i++)
		if (s->aps[i].ssid_len == s->ssid_len &&
		    !memcmp(s->aps[i].ssid, s->ssid, s->ssid_len)) {
			ap = &s->aps[i];
			break;
		}
	if (!ap)
		return -ENOENT;
	if (!!(ap->capability & 16) != !!n || ap->ie_len)
		return -EOPNOTSUPP;
	memset(c, 0, 80);
	bw_put16(c + 8, n ? 2 : 4);
	bw_put16(c + 10, s->key_index);
	for (i = 0; i < 4; i++) {
		c[12 + i] = s->key_len[i] == 13	 ? 2
			    : s->key_len[i] == 5 ? 1
						 : 0;
		memcpy(c + 16 + i * 16, s->keys[i], s->key_len[i]);
	}
	ret = bm_command(s, 0x13, 80);
	memset(c, 0, sizeof(s->command));
	if (ret < 0)
		return ret;
	if (bm_setting(s, 0x2f, 1, 0) ||
	    bm_setting(s, 0x28, 0x43 | (n ? 8 : 0), 0))
		return -EIO;
	memset(c, 0, 25);
	memcpy(c + 8, ap->bssid, 6);
	c[14] = s->shared_auth;
	if (bm_command(s, 0x11, 25) < 0)
		return -EIO;
	memset(c, 0, sizeof(s->command));
	memcpy(c + 8, ap->bssid, 6);
	bw_put16(c + 14, ap->capability & 0x11);
	bw_put16(c + 16, 10);
	bw_put16(c + 18, 100);
	p = 21;
	bw_put16(c + p, 0);
	bw_put16(c + p + 2, ap->ssid_len);
	memcpy(c + p + 4, ap->ssid, ap->ssid_len);
	p += 4 + ap->ssid_len;
	bw_put16(c + p, 3);
	bw_put16(c + p + 2, 1);
	c[p + 4] = ap->channel;
	p += 5;
	bw_put16(c + p, 4);
	bw_put16(c + p + 2, 6);
	p += 10;
	bw_put16(c + p, 1);
	bw_put16(c + p + 2, ap->nrates);
	memcpy(c + p + 4, ap->rates, ap->nrates);
	p += 4 + ap->nrates;
	ret = bm_command(s, 0x50, p);
	if (ret < 14 || bw_get16(s->packet + 10))
		return ret < 0 ? ret : -ECONNREFUSED;
	memcpy(s->bssid, ap->bssid, 6);
	s->connected = 1;
	return 0;
}
static int bm_send(struct bw_state *s, const u8 *frame, unsigned int n)
{
	int ret;
	if (n < 14 || n > BW_MAX_FRAME)
		return -EINVAL;
	ret = bw_wait(0x20, 1, 1, 500000);
	if (ret)
		return ret;
	memset(s->packet, 0, 24);
	bw_put32(s->packet + 8, 24);
	bw_put16(s->packet + 12, n);
	memcpy(s->packet + 14, frame, 6);
	memcpy(s->packet + 24, frame, n);
	WIFI_W16(0x22, 1);
	WIFI_W16(0x14, n + 24);
	bw_fifo_write(0x16, s->packet, n + 24);
	bm_signal(1);
	ret = bw_wait(0x22, 1, 1, 500000);
	WIFI_W16(0x22, 1);
	return ret;
}
#endif
