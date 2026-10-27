/* SPDX-License-Identifier: GPL-2.0-only
 * BE-300 Casio PCM DMA output, shared by Linux 2.4/2.6/4.2.
 * OSS /dev/dsp: S16_LE, mono/stereo, six hardware rates; /dev/mixer:
 * software master/PCM gain. No capture or guessed buzzer registers.
 * Register facts: stock wavedev.dll and be300/docs/BE300_AUDIO.md.
 */
#include <linux/version.h>
#include <linux/init.h>
#include <linux/module.h>
#include <linux/fs.h>
#include <linux/sound.h>
#include <linux/soundcard.h>
#include <linux/mm.h>
#include <linux/poll.h>
#include <linux/sched.h>
#include <linux/interrupt.h>
#include <linux/timer.h>
#include <linux/delay.h>
#include <linux/slab.h>
#include <asm/io.h>
#include <asm/uaccess.h>
#include <asm/cacheflush.h>
#if LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 26)
#include <linux/semaphore.h>
#else
#include <asm/semaphore.h>
#endif
#ifndef __iomem
#define __iomem
#endif
#ifndef __user
#define __user
#endif
#include "hardware.h"
#include "audio-regs.h"
#define AUDIO_IRQ 80
#define DMA_SIZE 4096
#define RING_SIZE 32768
#if LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 37)
static DEFINE_SEMAPHORE(audio_sem);
#else
static DECLARE_MUTEX(audio_sem);
#endif
static spinlock_t audio_lock;
static wait_queue_head_t audio_wait;
static struct timer_list audio_timer;
static unsigned char ring[RING_SIZE], *dma[2];
static unsigned long pages, last_completion;
static unsigned int head, tail, inflight[2], next_buffer;
static unsigned int rate = 22050, channels = 2, gain_left = 80, gain_right = 80;
static int opened, running, failure, irq_off = 1;
static unsigned int mixer_changes;

static unsigned int pending_bytes(void)
{
	return head - tail + inflight[0] + inflight[1];
}
static void refill(unsigned int index)
{
	unsigned int i, n = head - tail;
	short *samples = (short *)dma[index];
	int value, gain;
	if (n > DMA_SIZE)
		n = DMA_SIZE;
	for (i = 0; i < n; i++)
		dma[index][i] = ring[(tail + i) % RING_SIZE];
	memset(dma[index] + n, 0, DMA_SIZE - n);
	tail += n;
	inflight[index] = n;
	for (i = 0; i < DMA_SIZE / 2; i++) {
		gain = channels == 2 ? (i & 1 ? gain_right : gain_left)
				     : (gain_left + gain_right) / 2;
		value = samples[i];
		samples[i] = value * gain / 100;
	}
	wmb();
}
static void stop_locked(void)
{
	running = 0;
	audio_disable();
	audio_ack();
	if (!irq_off) {
		disable_irq_nosync(AUDIO_IRQ);
		irq_off = 1;
	}
}
static void service(void)
{
	unsigned long flags;
	unsigned int status, count, i;
	spin_lock_irqsave(&audio_lock, flags);
	if (running) {
		status = AUDIO_R(0x8a8) & 3;
		if (status) {
			audio_ack();
			count = (status & 1) + ((status >> 1) & 1);
			while (count--) {
				i = next_buffer;
				refill(i);
				/* Current/next queue, not fixed DMA slot
				 * identities. */
				AUDIO_W(0x8b8, (unsigned long)dma[i]);
				AUDIO_W(0x8bc,
					(unsigned long)dma[i] + DMA_SIZE - 1);
				next_buffer ^= 1;
			}
			last_completion = jiffies;
			if (AUDIO_R(0x8a8) & 3) {
				failure = -EIO;
				stop_locked();
			}
		} else if (time_after(jiffies, last_completion + 2 * HZ)) {
			failure = -ETIMEDOUT;
			stop_locked();
		}
	}
	spin_unlock_irqrestore(&audio_lock, flags);
	wake_up_interruptible(&audio_wait);
}
#if LINUX_VERSION_CODE < KERNEL_VERSION(2, 6, 0)
static void audio_interrupt(int irq, void *data, struct pt_regs *regs)
{
	service();
}
#elif LINUX_VERSION_CODE < KERNEL_VERSION(2, 6, 19)
static irqreturn_t audio_interrupt(int irq, void *data, struct pt_regs *regs)
{
	service();
	return IRQ_HANDLED;
}
#else
static irqreturn_t audio_interrupt(int irq, void *data)
{
	service();
	return IRQ_HANDLED;
}
#endif
static void audio_tick(unsigned long unused)
{
	service();
	mod_timer(&audio_timer, jiffies + (HZ / 100 ? HZ / 100 : 1));
}
static int start(void)
{
	unsigned long flags;
	int ret;
	if (running)
		return 0;
	ret = audio_prepare(rate, channels);
	if (ret) {
		failure = ret;
		return ret;
	}
	spin_lock_irqsave(&audio_lock, flags);
	refill(0);
	refill(1);
	next_buffer = 0;
	AUDIO_W(0x8b0, (unsigned long)dma[0]);
	AUDIO_W(0x8b4, (unsigned long)dma[0] + DMA_SIZE - 1);
	AUDIO_W(0x8b8, (unsigned long)dma[1]);
	AUDIO_W(0x8bc, (unsigned long)dma[1] + DMA_SIZE - 1);
	AUDIO_W(0x898, 1);
	AUDIO_W(0x8a0, 1);
	last_completion = jiffies;
	running = 1;
	irq_off = 0;
	spin_unlock_irqrestore(&audio_lock, flags);
	enable_irq(AUDIO_IRQ);
	return 0;
}
static void reset(void)
{
	unsigned long flags;
	spin_lock_irqsave(&audio_lock, flags);
	stop_locked();
	head = tail = 0;
	inflight[0] = inflight[1] = 0;
	failure = 0;
	spin_unlock_irqrestore(&audio_lock, flags);
	/* Codec commands never execute in IRQ context or on a wedged codec. */
	if (AUDIO_R(0x3c4))
		(void)audio_codec(0xd007);
	AUDIO_W(0x884, AUDIO_R(0x884) & ~2U);
	wake_up_interruptible(&audio_wait);
}
static int dsp_open(struct inode *inode, struct file *file)
{
	int ret = 0;
	if (!(file->f_mode & FMODE_WRITE) || (file->f_mode & FMODE_READ))
		return -ENODEV;
	if (down_interruptible(&audio_sem))
		return -ERESTARTSYS;
	if (opened)
		ret = -EBUSY;
	else {
		reset();
		opened = 1;
		rate = 22050;
		channels = 2;
	}
	up(&audio_sem);
	return ret;
}
static int drain(void)
{
	int ret = wait_event_interruptible(audio_wait,
					   !pending_bytes() || failure);
	return ret ? ret : failure;
}
static int dsp_release(struct inode *inode, struct file *file)
{
	down(&audio_sem);
	if (!(file->f_flags & O_NONBLOCK))
		(void)drain();
	reset();
	opened = 0;
	up(&audio_sem);
	return 0;
}
static ssize_t dsp_write(struct file *file, const char __user *buf, size_t len,
			 loff_t *pos)
{
	unsigned char chunk[512];
	unsigned long flags;
	size_t done = 0, n, space;
	int ret = 0;
	if (down_interruptible(&audio_sem))
		return -ERESTARTSYS;
	if (len % (channels * 2)) {
		ret = -EINVAL;
		goto out;
	}
	while (done < len) {
		if (failure) {
			ret = failure;
			break;
		}
		space = RING_SIZE - (head - tail);
		if (!space) {
			if (file->f_flags & O_NONBLOCK) {
				ret = -EAGAIN;
				break;
			}
			ret = wait_event_interruptible(
				audio_wait, head - tail < RING_SIZE || failure);
			if (ret)
				break;
			continue;
		}
		n = len - done;
		if (n > sizeof(chunk))
			n = sizeof(chunk);
		if (n > space)
			n = space;
		if (copy_from_user(chunk, buf + done, n)) {
			ret = -EFAULT;
			break;
		}
		spin_lock_irqsave(&audio_lock, flags);
		for (space = 0; space < n; space++)
			ring[(head + space) % RING_SIZE] = chunk[space];
		head += n;
		spin_unlock_irqrestore(&audio_lock, flags);
		done += n;
		ret = start();
		if (ret)
			break;
	}
out:
	up(&audio_sem);
	return done ? done : ret;
}
static unsigned int dsp_poll(struct file *file, poll_table *wait)
{
	poll_wait(file, &audio_wait, wait);
	if (failure)
		return POLLERR;
	return head - tail < RING_SIZE ? POLLOUT | POLLWRNORM : 0;
}
static long dsp_control(struct file *file, unsigned int cmd, unsigned long arg)
{
	int value = 0, ret = 0;
	unsigned int code, x2;
	struct audio_buf_info info;
	if (down_interruptible(&audio_sem))
		return -ERESTARTSYS;
	switch (cmd) {
	case SNDCTL_DSP_RESET:
		reset();
		goto out;
	case SNDCTL_DSP_SYNC:
		ret = drain();
		if (!ret)
			reset();
		goto out;
	case SNDCTL_DSP_POST:
		ret = start();
		goto out;
	case SNDCTL_DSP_NONBLOCK:
		file->f_flags |= O_NONBLOCK;
		goto out;
	case SNDCTL_DSP_GETCAPS:
		value = 0;
		break;
	case SNDCTL_DSP_GETFMTS:
		value = AFMT_S16_LE;
		break;
	case SNDCTL_DSP_GETBLKSIZE:
		value = DMA_SIZE;
		break;
	case SOUND_PCM_READ_RATE:
		value = rate;
		break;
	case SOUND_PCM_READ_CHANNELS:
		value = channels;
		break;
	case SOUND_PCM_READ_BITS:
		value = 16;
		break;
	case SNDCTL_DSP_GETODELAY:
		value = pending_bytes();
		break;
	case SNDCTL_DSP_GETOSPACE:
		info.fragsize = DMA_SIZE;
		info.fragstotal = RING_SIZE / DMA_SIZE;
		info.bytes = RING_SIZE - (head - tail);
		info.fragments = info.bytes / DMA_SIZE;
		ret = copy_to_user((void __user *)arg, &info, sizeof(info))
			      ? -EFAULT
			      : 0;
		goto out;
	case SNDCTL_DSP_SETFRAGMENT:
		goto out; /* fixed, reported by GETOSPACE */
	case SNDCTL_DSP_SETFMT:
		if (get_user(value, (int __user *)arg)) {
			ret = -EFAULT;
			goto out;
		}
		value = AFMT_S16_LE;
		break;
	case SNDCTL_DSP_SPEED:
	case SNDCTL_DSP_STEREO:
	case SNDCTL_DSP_CHANNELS:
		if (get_user(value, (int __user *)arg)) {
			ret = -EFAULT;
			goto out;
		}
		if (!value && cmd == SNDCTL_DSP_SPEED) {
			value = rate;
			break;
		}
		if (!value && cmd == SNDCTL_DSP_CHANNELS) {
			value = channels;
			break;
		}
		if (pending_bytes()) {
			ret = -EBUSY;
			goto out;
		}
		if (cmd == SNDCTL_DSP_SPEED && value < 0) {
			ret = -EINVAL;
			goto out;
		}
		if (cmd != SNDCTL_DSP_SPEED &&
		    (value < 0 || value > (cmd == SNDCTL_DSP_STEREO ? 1 : 2))) {
			ret = -EINVAL;
			goto out;
		}
		reset();
		if (cmd == SNDCTL_DSP_SPEED)
			value = rate = audio_rate(value, &code, &x2);
		else if (cmd == SNDCTL_DSP_STEREO)
			channels = value + 1;
		else
			channels = value;
		break;
	default:
		ret = -EINVAL;
		goto out;
	}
	if (put_user(value, (int __user *)arg))
		ret = -EFAULT;
out:
	up(&audio_sem);
	return ret;
}
static long mixer_control(struct file *file, unsigned int cmd,
			  unsigned long arg)
{
	int value, left, right;
	mixer_info identity;
	unsigned long flags;
	if (cmd == SOUND_MIXER_INFO || cmd == SOUND_OLD_MIXER_INFO) {
		memset(&identity, 0, sizeof(identity));
		strcpy(identity.id, "BE300");
		strcpy(identity.name, "Casio BE-300 wave output");
		spin_lock_irqsave(&audio_lock, flags);
		identity.modify_counter = mixer_changes;
		spin_unlock_irqrestore(&audio_lock, flags);
		return copy_to_user((void __user *)arg, &identity,
				    cmd == SOUND_MIXER_INFO
					    ? sizeof(identity)
					    : sizeof(_old_mixer_info))
			       ? -EFAULT
			       : 0;
	}
	if (_IOC_TYPE(cmd) != 'M')
		return -EINVAL;
	switch (_IOC_NR(cmd)) {
	case SOUND_MIXER_DEVMASK:
	case SOUND_MIXER_STEREODEVS:
		value = SOUND_MASK_VOLUME | SOUND_MASK_PCM;
		break;
	case SOUND_MIXER_RECMASK:
	case SOUND_MIXER_RECSRC:
	case SOUND_MIXER_CAPS:
		value = 0;
		break;
	case SOUND_MIXER_VOLUME:
	case SOUND_MIXER_PCM:
		spin_lock_irqsave(&audio_lock, flags);
		value = gain_left | (gain_right << 8);
		spin_unlock_irqrestore(&audio_lock, flags);
		if (_IOC_DIR(cmd) & _IOC_WRITE) {
			if (get_user(value, (int __user *)arg))
				return -EFAULT;
			left = value & 255;
			right = (value >> 8) & 255;
			if (left > 100 || right > 100)
				return -EINVAL;
			spin_lock_irqsave(&audio_lock, flags);
			gain_left = left;
			gain_right = right;
			mixer_changes++;
			spin_unlock_irqrestore(&audio_lock, flags);
		}
		break;
	default:
		return -EINVAL;
	}
	return put_user(value, (int __user *)arg) ? -EFAULT : 0;
}
#if LINUX_VERSION_CODE < KERNEL_VERSION(2, 6, 36)
static int dsp_ioctl(struct inode *inode, struct file *file, unsigned int cmd,
		     unsigned long arg)
{
	return dsp_control(file, cmd, arg);
}
static int mixer_ioctl(struct inode *inode, struct file *file, unsigned int cmd,
		       unsigned long arg)
{
	return mixer_control(file, cmd, arg);
}
#define DSP_IOCTL .ioctl = dsp_ioctl
#define MIXER_IOCTL .ioctl = mixer_ioctl
#else
#define DSP_IOCTL .unlocked_ioctl = dsp_control
#define MIXER_IOCTL .unlocked_ioctl = mixer_control
#endif
static struct file_operations dsp_fops = {
	.owner = THIS_MODULE,
	.open = dsp_open,
	.release = dsp_release,
	.write = dsp_write,
	.poll = dsp_poll,
	DSP_IOCTL,
};
static struct file_operations mixer_fops = {
	.owner = THIS_MODULE,
	MIXER_IOCTL,
};
static int __init be300_audio_init(void)
{
	int ret, dsp;
	spin_lock_init(&audio_lock);
	init_waitqueue_head(&audio_wait);
	pages = __get_free_pages(GFP_KERNEL | GFP_DMA, 1);
	if (!pages)
		return -ENOMEM;
	memset((void *)pages, 0, DMA_SIZE * 2);
	dma_cache_wback_inv(pages, DMA_SIZE * 2);
	dma[0] = (unsigned char *)KSEG1ADDR(virt_to_phys((void *)pages));
	dma[1] = dma[0] + DMA_SIZE;
	audio_disable();
	audio_ack();
	AUDIO_W(0x1118, 1);
	AUDIO_W16(0x880, AUDIO_R16(0x880) | 4);
	AUDIO_W16(0x888, 3);
	ret = request_irq(AUDIO_IRQ, audio_interrupt, 0, "be300-audio",
			  &audio_lock);
	if (ret)
		goto fail;
	disable_irq(AUDIO_IRQ);
	dsp = register_sound_dsp(&dsp_fops, -1);
	if (dsp < 0) {
		ret = dsp;
		goto fail_irq;
	}
	ret = register_sound_mixer(&mixer_fops, -1);
	if (ret < 0) {
		unregister_sound_dsp(dsp);
		goto fail_irq;
	}
	init_timer(&audio_timer);
	audio_timer.function = audio_tick;
	audio_timer.expires = jiffies + 1;
	add_timer(&audio_timer);
	printk(KERN_INFO
	       "BE-300: OSS wave output dsp minor %d mixer minor %d\n",
	       dsp, ret);
	return 0;
fail_irq:
	free_irq(AUDIO_IRQ, &audio_lock);
fail:
	free_pages(pages, 1);
	return ret;
}
/* After the board cascade and the sound core, including on 2.4. */
#if LINUX_VERSION_CODE < KERNEL_VERSION(2, 6, 0)
__initcall(be300_audio_init);
#else
late_initcall(be300_audio_init);
#endif
MODULE_LICENSE("GPL");
