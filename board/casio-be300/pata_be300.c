/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * CompactFlash ATA in the BE-300's socket 0, Linux 4.2.
 *
 * On a real BE-300 each 16-bit access of the CF data register carried one
 * byte with a zero high byte, so 16-bit IDENTIFY read as garbage. glaze-os
 * (kernel/drivers/cf.c identify_as/read_sector) therefore puts the card in
 * 8-bit mode with SET FEATURES 01h (CF spec) after every reset and moves
 * data a byte at a time; a SanDisk 1 GB card mounted that way. This is
 * pata_platform with that data path. Polled: VRC4173_IRQ(0) belongs to
 * the NE2000 when that card is in the socket.
 *
 * The taskfile is at PA 0x0A00C170-7 (COR 0x43, secondary IDE ports, set by
 * hardware.c), alternate status/device control at 0x0A00C376.
 */
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/libata.h>
#include <linux/ata.h>
#include <linux/delay.h>
#include <scsi/scsi_host.h>

#define DRV_NAME "pata_be300"

static struct scsi_host_template be300_sht = {
	ATA_PIO_SHT(DRV_NAME),
};

/* The ATA data register's words are low byte first (ATA-4 8.12). */
static unsigned int be300_data_xfer(struct ata_device *dev, unsigned char *buf,
				    unsigned int buflen, int rw)
{
	void __iomem *data = dev->link->ap->ioaddr.data_addr;
	unsigned long flags;
	unsigned int i;

	local_irq_save(flags);
	if (rw == READ)
		for (i = 0; i < buflen; i++)
			buf[i] = ioread8(data);
	else
		for (i = 0; i < buflen; i++)
			iowrite8(buf[i], data);
	local_irq_restore(flags);
	return buflen;
}

/* SET FEATURES 01h: 8-bit data transfers, for each device that answered
 * the reset. A card that refuses (the IC3100 camera) reports ABRT. */
static void be300_set_8bit(struct ata_port *ap, unsigned int devmask)
{
	struct ata_ioports *io = &ap->ioaddr;
	unsigned int dev, n;
	u8 status;

	for (dev = 0; dev < 2; dev++) {
		if (!(devmask & (1U << dev)))
			continue;
		iowrite8(ATA_DEVICE_OBS | (dev ? ATA_DEV1 : 0), io->device_addr);
		iowrite8(0x01, io->feature_addr); /* CF: enable 8-bit */
		iowrite8(ATA_CMD_SET_FEATURES, io->command_addr);
		for (n = 0; n < 1000; n++) {
			status = ioread8(io->status_addr);
			if (!(status & ATA_BUSY))
				break;
			udelay(100);
		}
		if (status & (ATA_BUSY | ATA_ERR))
			ata_port_warn(ap, "dev %u: 8-bit mode status %02x\n",
				      dev, status);
	}
}

static int be300_softreset(struct ata_link *link, unsigned int *classes,
			   unsigned long deadline)
{
	struct ata_port *ap = link->ap;
	unsigned int devmask = 0, dev;
	int rc;

	rc = ata_sff_softreset(link, classes, deadline);
	if (rc)
		return rc;
	for (dev = 0; dev < 2; dev++)
		if (classes[dev] == ATA_DEV_ATA)
			devmask |= 1U << dev;
	be300_set_8bit(ap, devmask);
	return 0;
}

static int be300_set_mode(struct ata_link *link, struct ata_device **unused)
{
	struct ata_device *dev;

	ata_for_each_dev(dev, link, ENABLED) {
		dev->pio_mode = dev->xfer_mode = XFER_PIO_0;
		dev->xfer_shift = ATA_SHIFT_PIO;
		dev->flags |= ATA_DFLAG_PIO;
		ata_dev_info(dev, "configured for PIO0, 8-bit\n");
	}
	return 0;
}

static struct ata_port_operations be300_port_ops = {
	.inherits	= &ata_sff_port_ops,
	.sff_data_xfer	= be300_data_xfer,
	.softreset	= be300_softreset,
	.cable_detect	= ata_cable_unknown,
	.set_mode	= be300_set_mode,
};

static int be300_pata_probe(struct platform_device *pdev)
{
	struct resource *io, *ctl;
	struct ata_host *host;
	struct ata_port *ap;
	void __iomem *base, *ctl_addr;

	io = platform_get_resource(pdev, IORESOURCE_MEM, 0);
	ctl = platform_get_resource(pdev, IORESOURCE_MEM, 1);
	if (!io || !ctl)
		return -EINVAL;
	host = ata_host_alloc(&pdev->dev, 1);
	if (!host)
		return -ENOMEM;
	ap = host->ports[0];
	ap->ops = &be300_port_ops;
	ap->pio_mask = ATA_PIO0;
	/* A CF socket holds one card, the master; some cards (and the
	 * emulator's) also answer for device 1, which would add a ghost. */
	ap->flags |= ATA_FLAG_PIO_POLLING;
	base = devm_ioremap(&pdev->dev, io->start, resource_size(io));
	ctl_addr = devm_ioremap(&pdev->dev, ctl->start, resource_size(ctl));
	if (!base || !ctl_addr)
		return -ENOMEM;
	ap->ioaddr.cmd_addr = base;
	ap->ioaddr.altstatus_addr = ctl_addr;
	ap->ioaddr.ctl_addr = ctl_addr;
	ata_sff_std_ports(&ap->ioaddr);
	ata_port_desc(ap, "mmio cmd 0x%llx ctl 0x%llx",
		      (unsigned long long)io->start,
		      (unsigned long long)ctl->start);
	return ata_host_activate(host, 0, NULL, 0, &be300_sht);
}

static struct platform_driver be300_pata_driver = {
	.probe	= be300_pata_probe,
	.remove	= ata_platform_remove_one,
	.driver	= {
		.name = DRV_NAME,
	},
};
module_platform_driver(be300_pata_driver);

MODULE_DESCRIPTION("BE-300 CompactFlash ATA, 8-bit data transfers");
MODULE_LICENSE("GPL");
