/* SPDX-License-Identifier: GPL-2.0-only
 * BE-300 CF station networking using normal Linux Ethernet/Wireless
 * Extensions interfaces. One socket; identified by CIS before NIC writes.
 * FIFO/command transactions run in a worker with a sleeping lock. Polling
 * keeps source 0 masked and avoids monopolizing the GIU during a timeout.
 */
#include <linux/version.h>
#include <linux/init.h>
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/slab.h>
#include <linux/err.h>
#include <linux/netdevice.h>
#include <linux/etherdevice.h>
#include <linux/if_arp.h>
#include <linux/skbuff.h>
#include <linux/wireless.h>
#include <linux/delay.h>
#include <linux/timer.h>
#include <linux/sched.h>
#include <linux/fs.h>
#include <linux/vmalloc.h>
#include <net/iw_handler.h>
#include <asm/io.h>
#include <asm/uaccess.h>
#if LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 26)
#include <linux/semaphore.h>
#else
#include <asm/semaphore.h>
#endif
#if LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 0)
#include <linux/workqueue.h>
#else
#include <linux/tqueue.h>
#endif
#ifndef __iomem
#define __iomem
#endif
#include "hardware.h"
#include "card.h"
/* Protocol polling is bounded and runs in process context. Yield when
 * requested so a missing firmware response cannot monopolize this CPU.
 */
static void wifi_delay(unsigned int us)
{
	static unsigned int budget;
	udelay(us);
	budget += us;
	if (budget >= 1000) {
		budget = 0;
#if LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 0)
		cond_resched();
#else
		if (current->need_resched)
			schedule();
#endif
	}
}
#define WIFI_R8(r) readb((void __iomem *)(0xaa00c300UL + (r)))
#define WIFI_R16(r) readw((void __iomem *)(0xaa00c300UL + (r)))
#define WIFI_W8(r, v) writeb((v), (void __iomem *)(0xaa00c300UL + (r)))
#define WIFI_W16(r, v) writew((v), (void __iomem *)(0xaa00c300UL + (r)))
#define WIFI_DELAY(us) wifi_delay(us)
#include "wifi-proto.h"
#if LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 37)
static DEFINE_SEMAPHORE(wifi_sem);
#else
static DECLARE_MUTEX(wifi_sem);
#endif
static struct bw_state station;
static struct net_device *wifi_dev;
static struct net_device_stats wifi_stats;
static struct iw_statistics wireless_stats;
static struct sk_buff_head transmit;
static struct timer_list wifi_timer;
static int active;
static unsigned long scan_deadline, association_deadline;
#if LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 0)
static struct workqueue_struct *wifi_queue;
static struct work_struct wifi_work;
#else
static struct tq_struct wifi_work;
#endif
static void receive_frame(const u8 *bytes, unsigned int n)
{
	struct sk_buff *skb;
	if (!station.connected || n < 14 || n > BW_MAX_FRAME) {
		wifi_stats.rx_dropped++;
		return;
	}
	skb = dev_alloc_skb(n + 2);
	if (!skb) {
		wifi_stats.rx_dropped++;
		return;
	}
	skb_reserve(skb, 2);
	memcpy(skb_put(skb, n), bytes, n);
	skb->dev = wifi_dev;
	skb->protocol = eth_type_trans(skb, wifi_dev);
	netif_rx(skb);
	wifi_stats.rx_packets++;
	wifi_stats.rx_bytes += n;
}
static void receive_prism(void)
{
	u8 header[60], *p = station.packet;
	unsigned int n;
	if (bx_bap(WIFI_R16(0x20), 0, header, 60, 0))
		goto drop;
	n = bw_get16(header + 44);
	if ((bw_get16(header) & 7) || n < 8 || n > 1508)
		goto drop;
	if (bx_bap(WIFI_R16(0x20), 60, p + 14, n, 0))
		goto drop;
	memcpy(p, header + 46, 12);
	if (!memcmp(p + 14, "\xaa\xaa\x03\0\0", 5) &&
	    (p[19] == 0 || p[19] == 0xf8)) {
		memmove(p + 12, p + 20, n - 6);
		n += 6;
	} else {
		memcpy(p + 12, header + 58, 2);
		n += 14;
	}
	receive_frame(p, n);
	return;
drop:
	wifi_stats.rx_dropped++;
}
static void receive_marvell(void)
{
	u8 *p = station.packet;
	unsigned int n = WIFI_R16(0x24), offset, len;
	if (n < 20 || n > sizeof(station.packet))
		goto drop;
	bw_fifo_read(0x10, p, n);
	offset = bw_get16(p + 8) | ((unsigned int)bw_get16(p + 10) << 16);
	len = bw_get16(p + 4);
	if (!(bw_get16(p) & 1) || offset < 20 || offset > n || len < 22 ||
	    len > n - offset || len - 8 > BW_MAX_FRAME)
		goto drop;
	p += offset;
	if (memcmp(p + 14, "\xaa\xaa\x03\0\0\0", 6))
		goto drop;
	memmove(p + 8, p, 12);
	receive_frame(p + 8, len - 8);
	return;
drop:
	wifi_stats.rx_dropped++;
}
static void link_event(int connected)
{
	union iwreq_data event;
	memset(&event, 0, sizeof(event));
	event.ap_addr.sa_family = ARPHRD_ETHER;
	if (connected) {
		netif_carrier_on(wifi_dev);
		memcpy(event.ap_addr.sa_data, station.bssid, 6);
	} else
		netif_carrier_off(wifi_dev);
	wireless_send_event(wifi_dev, SIOCGIWAP, &event, NULL);
}
static void poll_card(void)
{
	unsigned int i, events;
	int connected = station.connected;
	union iwreq_data event;
	for (i = 0; i < 8; i++) {
		events = WIFI_R16(station.kind == BW_XI825 ? 0x30 : 0x22);
		if (events == 0xffff) {
			station.initialized = station.connected = 0;
			break;
		}
		if (station.kind == BW_XI825) {
			if (!(events & 0x2081))
				break;
			if (events & 1)
				receive_prism();
			if (events & 128)
				bx_information(&station);
			WIFI_W16(0x34, events & 0x2081);
		} else {
			if (!(events & 18))
				break;
			if (events & 2) {
				receive_marvell();
				bm_signal(2);
			}
			if (events & 16) {
				if (((WIFI_R16(0x20) >> 8) & 127) == 3)
					station.connected = 0;
				bm_signal(16);
			}
			WIFI_W16(0x22, events & 18);
		}
	}
	if (connected != station.connected)
		link_event(station.connected);
	if (!station.initialized) {
		netif_stop_queue(wifi_dev);
		skb_queue_purge(&transmit);
	}
	if (station.scanning && time_after(jiffies, scan_deadline))
		station.scanning = 0;
	if (!station.scanning && scan_deadline) {
		scan_deadline = 0;
		memset(&event, 0, sizeof(event));
		wireless_send_event(wifi_dev, SIOCGIWSCAN, &event, NULL);
	}
	if (!station.connected && association_deadline &&
	    time_after(jiffies, association_deadline)) {
		association_deadline = 0;
		(void)bx_command(2, 0);
		link_event(0);
	}
}
#if LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 20)
static void wifi_worker(struct work_struct *work)
#else
static void wifi_worker(void *unused)
#endif
{
	struct sk_buff *skb;
	int ret;
	down(&wifi_sem);
	if (!active || !station.initialized)
		goto out;
	if (be300_wireless_card() != station.kind) {
		station.connected = station.initialized = 0;
		link_event(0);
		netif_stop_queue(wifi_dev);
		skb_queue_purge(&transmit);
		memset(station.keys, 0, sizeof(station.keys));
		memset(station.key_len, 0, sizeof(station.key_len));
		goto out;
	}
	poll_card();
	while ((skb = skb_dequeue(&transmit))) {
		if (!station.connected || skb->len < 14 ||
		    skb->len > BW_MAX_FRAME)
			ret = -ENETDOWN;
		else
			ret = station.kind == BW_XI825
				      ? bx_send(&station, skb->data, skb->len)
				      : bm_send(&station, skb->data, skb->len);
		if (ret)
			wifi_stats.tx_errors++;
		else {
			wifi_stats.tx_packets++;
			wifi_stats.tx_bytes += skb->len;
		}
		dev_kfree_skb(skb);
	}
	if (active)
		netif_wake_queue(wifi_dev);
out:
	up(&wifi_sem);
}
static void schedule_wifi(void)
{
#if LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 0)
	queue_work(wifi_queue, &wifi_work);
#else
	schedule_task(&wifi_work);
#endif
}
static void wifi_tick(unsigned long unused)
{
	if (active) {
		schedule_wifi();
		mod_timer(&wifi_timer, jiffies + (HZ / 100 ? HZ / 100 : 1));
	}
}
/* Old kernels have no direct filesystem fallback in request_firmware.
 * Load a bounded regular firmware image in process context on interface-up.
 * No credentials, opaque vendor modules or firmware bytes enter the source.
 */
static int firmware_file(const char *path, u8 **out, unsigned int *length,
			 unsigned int max)
{
	struct file *file;
	mm_segment_t saved;
	loff_t pos = 0, size;
	struct inode *inode;
	long n, used = 0;
	u8 *data;
	file = filp_open(path, O_RDONLY, 0);
	if (IS_ERR(file))
		return PTR_ERR(file);
#if LINUX_VERSION_CODE >= KERNEL_VERSION(3, 9, 0)
	inode = file_inode(file);
#else
	inode = file->f_dentry->d_inode;
#endif
	if (!S_ISREG(inode->i_mode)) {
		filp_close(file, NULL);
		return -EINVAL;
	}
#if LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 0)
	size = i_size_read(inode);
#else
	size = inode->i_size;
#endif
	if (size <= 0 || size > max || (size & 1)) {
		filp_close(file, NULL);
		return -EINVAL;
	}
	max = size;
	data = vmalloc(max + 1);
	if (!data) {
		filp_close(file, NULL);
		return -ENOMEM;
	}
	saved = get_fs();
	set_fs(KERNEL_DS);
	do {
#if LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 0)
		n = vfs_read(file, data + used, max + 1 - used, &pos);
#else
		n = file->f_op && file->f_op->read
			    ? file->f_op->read(file, data + used,
					       max + 1 - used, &pos)
			    : -EINVAL;
#endif
		if (n > 0)
			used += n;
	} while (n > 0 && used <= max);
	set_fs(saved);
	filp_close(file, NULL);
	if (n < 0 || !used || used > max || (used & 1)) {
		vfree(data);
		return n < 0 ? n : -EINVAL;
	}
	*out = data;
	*length = used;
	return 0;
}
static int marvell_firmware(void)
{
	u8 *helper = NULL, *main = NULL;
	unsigned int hn = 0, mn = 0;
	int ret;
	if (WIFI_R8(0x3f) == 0x5a)
		return 0;
	ret = firmware_file("/lib/firmware/libertas/cf8385_helper.bin", &helper,
			    &hn, 65536);
	if (!ret)
		ret = firmware_file("/lib/firmware/libertas/cf8385.bin", &main,
				    &mn, 512 * 1024);
	if (!ret)
		ret = bm_firmware(helper, hn, main, mn);
	vfree(main);
	vfree(helper);
	return ret;
}
static int initialize_card(void)
{
	int ret;
	unsigned int poll, revision;
	be300_girq0_source_mask(0);
	if (station.kind == BW_XI825) {
		writeb(1, (void *)0xaa00d3e0UL);
		ret = bx_init(&station);
	} else {
		/* Byte-addressed attribute bridge, never NAND DIO at AA00D200.
		 */
		writeb(0x80, (void *)0xab400100UL);
		udelay(1000);
		writeb(1, (void *)0xab400100UL);
		WIFI_W16(4, 31);
		for (poll = 0; poll < 1000; poll++) {
			revision = WIFI_R8(0x1c);
			if (revision >= 0x10 && revision != 255)
				break;
			WIFI_DELAY(1000);
		}
		if (poll == 1000)
			return -ENODEV;
		ret = marvell_firmware();
		if (!ret)
			ret = bm_init(&station);
		if (!ret && !is_valid_ether_addr(station.mac) &&
		    be300_card_node_id(station.mac)) {
			memset(station.command, 0, 16);
			bw_put16(station.command + 8, 1);
			memcpy(station.command + 10, station.mac, 6);
			ret = bm_command(&station, 0x4d, 16);
			if (ret > 0)
				ret = 0;
		}
	}
	if (!ret && !is_valid_ether_addr(station.mac))
		ret = -EIO;
	if (!ret) {
		memcpy(wifi_dev->dev_addr, station.mac, 6);
		station.initialized = 1;
	}
	return ret;
}
static int wifi_open(struct net_device *dev)
{
	int ret;
	down(&wifi_sem);
	if (be300_wireless_card() != station.kind)
		ret = -ENODEV;
	else
		ret = initialize_card();
	if (!ret) {
		active = 1;
		station.connected = station.scanning = 0;
		netif_carrier_off(dev);
		netif_start_queue(dev);
		mod_timer(&wifi_timer, jiffies + 1);
	}
	up(&wifi_sem);
	if (ret)
		printk(KERN_ERR
		       "BE-300 Wi-Fi: interface initialization failed: %d\n",
		       ret);
	return ret;
}
static int wifi_stop(struct net_device *dev)
{
	down(&wifi_sem);
	active = 0;
	netif_stop_queue(dev);
	netif_carrier_off(dev);
	be300_girq0_source_mask(0);
	if (station.initialized && be300_wireless_card() == station.kind) {
		if (station.kind == BW_XI825)
			(void)bx_command(2, 0);
		else {
			WIFI_W16(4, 31);
			(void)bm_disconnect(&station);
		}
	}
	station.connected = station.initialized = station.scanning = 0;
	memset(station.keys, 0, sizeof(station.keys));
	memset(station.key_len, 0, sizeof(station.key_len));
	memset(station.command, 0, sizeof(station.command));
	up(&wifi_sem);
	del_timer_sync(&wifi_timer);
#if LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 0)
	flush_workqueue(wifi_queue);
#else
	flush_scheduled_tasks();
#endif
	skb_queue_purge(&transmit);
	return 0;
}
#if LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 29)
static netdev_tx_t wifi_xmit(struct sk_buff *skb, struct net_device *dev)
#else
static int wifi_xmit(struct sk_buff *skb, struct net_device *dev)
#endif
{
	if (skb_queue_len(&transmit) >= 8) {
		netif_stop_queue(dev);
		return 1;
	}
	skb_queue_tail(&transmit, skb);
	if (skb_queue_len(&transmit) >= 8)
		netif_stop_queue(dev);
	schedule_wifi();
	return 0;
}
static struct net_device_stats *wifi_get_stats(struct net_device *dev)
{
	return &wifi_stats;
}
static struct iw_statistics *wifi_get_wireless_stats(struct net_device *dev)
{
	return &wireless_stats;
}
#if LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 27)
#define BW_EVENT(info, p, end, e, n) iwe_stream_add_event(info, p, end, e, n)
#define BW_POINT(info, p, end, e, bytes)                                       \
	iwe_stream_add_point(info, p, end, e, bytes)
#else
#define BW_EVENT(info, p, end, e, n) iwe_stream_add_event(p, end, e, n)
#define BW_POINT(info, p, end, e, bytes) iwe_stream_add_point(p, end, e, bytes)
#endif
static int wifi_ioctl_handler(struct net_device *dev,
			      struct iw_request_info *info,
			      union iwreq_data *request, char *extra)
{
	int ret = 0, index;
	unsigned int n, i;
	char *cursor = extra, *end;
	struct iw_event event;
	struct iw_range *range;
	struct bw_ap *ap;
	if (down_interruptible(&wifi_sem))
		return -ERESTARTSYS;
	switch (info->cmd) {
	case SIOCGIWNAME:
		strcpy(request->name, station.kind == BW_XI825
					      ? "IEEE 802.11b"
					      : "IEEE 802.11bg");
		break;
	case SIOCGIWMODE:
		request->mode = IW_MODE_INFRA;
		break;
	case SIOCSIWMODE:
		if (request->mode != IW_MODE_INFRA)
			ret = -EOPNOTSUPP;
		break;
	case SIOCGIWAP:
		request->ap_addr.sa_family = ARPHRD_ETHER;
		memset(request->ap_addr.sa_data, 0, 6);
		if (station.connected)
			memcpy(request->ap_addr.sa_data, station.bssid, 6);
		break;
	case SIOCGIWRANGE:
		range = (struct iw_range *)extra;
		memset(range, 0, sizeof(*range));
		request->data.length = sizeof(*range);
		range->we_version_compiled = WIRELESS_EXT;
		range->we_version_source = 14;
		range->num_encoding_sizes = 2;
		range->encoding_size[0] = 5;
		range->encoding_size[1] = 13;
		range->max_encoding_tokens = 4;
		range->num_channels = 11;
		range->num_frequency = 11;
		for (i = 0; i < 11; i++) {
			range->freq[i].i = i + 1;
			range->freq[i].m = 2412 + i * 5;
			range->freq[i].e = 6;
		}
		break;
	case SIOCSIWFREQ:
		ret = -EOPNOTSUPP;
		break; /* infrastructure AP selects channel */
	case SIOCGIWFREQ:
		request->freq.m = 0;
		request->freq.e = 0;
		break;
	case SIOCGIWESSID:
		request->essid.length = station.ssid_len;
		request->essid.flags = station.ssid_len != 0;
		memcpy(extra, station.ssid, station.ssid_len);
#if WIRELESS_EXT < 21
		extra[station.ssid_len] = 0;
		request->essid.length++;
#endif
		break;
	case SIOCSIWENCODE:
		/* Configuration is committed at association, never pretend a
		 * live key change reached the firmware. Disconnect before
		 * replacing it.
		 */
		if (active && station.ssid_len) {
			ret = -EBUSY;
			break;
		}
		index = (request->encoding.flags & IW_ENCODE_INDEX) - 1;
		if (index < 0)
			index = station.key_index;
		if (index > 3) {
			ret = -EINVAL;
			break;
		}
		n = request->encoding.length;
		if (n && n != 5 && n != 13) {
			ret = -EINVAL;
			break;
		}
		station.key_index = index;
		if (request->encoding.flags & IW_ENCODE_DISABLED) {
			memset(station.keys, 0, sizeof(station.keys));
			memset(station.key_len, 0, sizeof(station.key_len));
		} else if (n) {
			memset(station.keys[index], 0, 13);
			memcpy(station.keys[index], extra, n);
			station.key_len[index] = n;
		}
		station.shared_auth =
			!!(request->encoding.flags & IW_ENCODE_RESTRICTED);
		break;
	case SIOCGIWENCODE:
		request->encoding.flags =
			IW_ENCODE_NOKEY | (station.key_index + 1) |
			(station.key_len[station.key_index]
				 ? (station.shared_auth ? IW_ENCODE_RESTRICTED
							: IW_ENCODE_OPEN)
				 : IW_ENCODE_DISABLED);
		request->encoding.length = 0;
		break;
	case SIOCSIWESSID:
		if (!active || !station.initialized) {
			ret = -ENETDOWN;
			break;
		}
		n = request->essid.length;
#if WIRELESS_EXT < 21
		if (n && extra[n - 1] == 0)
			n--;
#endif
		if (n > 32) {
			ret = -EINVAL;
			break;
		}
		if (!request->essid.flags)
			n = 0;
		station.ssid_len = n;
		memset(station.ssid, 0, 32);
		memcpy(station.ssid, extra, n);
		station.connected = 0;
		skb_queue_purge(&transmit);
		link_event(0);
		if (!n)
			ret = station.kind == BW_XI825
				      ? bx_command(2, 0)
				      : bm_disconnect(&station);
		else {
			ret = station.kind == BW_XI825 ? bx_connect(&station)
						       : bm_connect(&station);
			if (!ret && station.kind == BW_XI825)
				association_deadline = jiffies + 10 * HZ;
			if (!ret && station.connected)
				link_event(1);
		}
		break;
	case SIOCSIWSCAN:
		if (!active || !station.initialized) {
			ret = -ENETDOWN;
			break;
		}
		if (station.scanning) {
			ret = -EBUSY;
			break;
		}
		ret = station.kind == BW_XI825 ? bx_scan(&station)
					       : bm_scan(&station);
		if (!ret)
			scan_deadline = jiffies + 5 * HZ;
		break;
	case SIOCGIWSCAN:
		if (station.scanning) {
			ret = -EAGAIN;
			break;
		}
		end = extra + request->data.length;
		for (i = 0; i < station.count; i++) {
			if (end - cursor < 200) {
				ret = -E2BIG;
				break;
			}
			ap = &station.aps[i];
			memset(&event, 0, sizeof(event));
			event.cmd = SIOCGIWAP;
			event.u.ap_addr.sa_family = ARPHRD_ETHER;
			memcpy(event.u.ap_addr.sa_data, ap->bssid, 6);
			cursor = BW_EVENT(info, cursor, end, &event,
					  IW_EV_ADDR_LEN);
			event.cmd = SIOCGIWESSID;
			event.u.data.length = ap->ssid_len;
			event.u.data.flags = 1;
			cursor = BW_POINT(info, cursor, end, &event, ap->ssid);
			event.cmd = SIOCGIWFREQ;
			event.u.freq.m = ap->channel;
			event.u.freq.e = 0;
			cursor = BW_EVENT(info, cursor, end, &event,
					  IW_EV_FREQ_LEN);
			event.cmd = SIOCGIWENCODE;
			event.u.data.length = 0;
			event.u.data.flags =
				(ap->capability & 16)
					? IW_ENCODE_ENABLED | IW_ENCODE_NOKEY
					: IW_ENCODE_DISABLED;
			cursor = BW_POINT(info, cursor, end, &event, "");
		}
		request->data.length = cursor - extra;
		request->data.flags = 0;
		break;
	default:
		ret = -EOPNOTSUPP;
	}
	up(&wifi_sem);
	return ret;
}
#define BW_HANDLER(cmd) [cmd - SIOCIWFIRST] = wifi_ioctl_handler
static iw_handler wifi_handlers[] = {
	BW_HANDLER(SIOCGIWNAME),   BW_HANDLER(SIOCSIWMODE),
	BW_HANDLER(SIOCGIWMODE),   BW_HANDLER(SIOCSIWFREQ),
	BW_HANDLER(SIOCGIWFREQ),   BW_HANDLER(SIOCGIWRANGE),
	BW_HANDLER(SIOCGIWAP),	   BW_HANDLER(SIOCSIWESSID),
	BW_HANDLER(SIOCGIWESSID),  BW_HANDLER(SIOCSIWSCAN),
	BW_HANDLER(SIOCGIWSCAN),   BW_HANDLER(SIOCSIWENCODE),
	BW_HANDLER(SIOCGIWENCODE),
};
static struct iw_handler_def wifi_handler_def = {
	.standard = wifi_handlers,
	.num_standard = sizeof(wifi_handlers) / sizeof(wifi_handlers[0]),
#if LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 19)
	.get_wireless_stats = wifi_get_wireless_stats,
#endif
};
#if LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 29)
static const struct net_device_ops wifi_ops = {
	.ndo_open = wifi_open,
	.ndo_stop = wifi_stop,
	.ndo_start_xmit = wifi_xmit,
	.ndo_get_stats = wifi_get_stats,
};
#endif
static int __init be300_wifi_init(void)
{
	int ret;
	station.kind = be300_wireless_card();
	if (!station.kind)
		return 0;
	wifi_dev = alloc_etherdev(0);
	if (!wifi_dev)
		return -ENOMEM;
	strcpy(wifi_dev->name, "wlan%d");
#if LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 29)
	wifi_dev->netdev_ops = &wifi_ops;
#else
	wifi_dev->open = wifi_open;
	wifi_dev->stop = wifi_stop;
	wifi_dev->hard_start_xmit = wifi_xmit;
	wifi_dev->get_stats = wifi_get_stats;
#endif
#if LINUX_VERSION_CODE < KERNEL_VERSION(2, 6, 19)
	wifi_dev->get_wireless_stats = wifi_get_wireless_stats;
#endif
	wifi_dev->wireless_handlers = &wifi_handler_def;
	wifi_dev->dev_addr[0] = 2;
	wifi_dev->dev_addr[5] = station.kind;
	skb_queue_head_init(&transmit);
	init_timer(&wifi_timer);
	wifi_timer.function = wifi_tick;
#if LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 0)
	wifi_queue = create_singlethread_workqueue("be300-wifi");
	if (!wifi_queue) {
		ret = -ENOMEM;
		goto fail;
	}
#if LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 20)
	INIT_WORK(&wifi_work, wifi_worker);
#else
	INIT_WORK(&wifi_work, wifi_worker, NULL);
#endif
#else
	INIT_TQUEUE(&wifi_work, wifi_worker, NULL);
#endif
	netif_carrier_off(wifi_dev);
	ret = register_netdev(wifi_dev);
	if (ret)
		goto fail_queue;
	printk(KERN_INFO
	       "BE-300: %s Wi-Fi registered as %s (open/WEP station)\n",
	       station.kind == BW_XI825 ? "XI-825" : "WL54-CF", wifi_dev->name);
	return 0;
fail_queue:
#if LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 0)
	destroy_workqueue(wifi_queue);
#endif
fail:
#if LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 0)
	free_netdev(wifi_dev);
#else
	kfree(wifi_dev);
#endif
	return ret;
}
#if LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 0)
late_initcall(be300_wifi_init);
#else
__initcall(be300_wifi_init);
#endif
MODULE_LICENSE("GPL");
