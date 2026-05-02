/*
 *  Simple frame buffer device for Casio Cassiopeia BE-300/BE-500
 *  Copyright (C) 2004 Filip Onkelinx - Filip@linux4.be
 *
 *  based on linux/drivers/video/vfb.c -- Virtual frame buffer device
 *      Copyright (C) 2002 James Simmons
 *	Copyright (C) 1997 Geert Uytterhoeven
 *
 *  Ported to Linux 4.2.9 by removing soft_cursor, fixing fb_mmap
 *  signature, and using FBINFO_DEFAULT.
 *
 *  This file is subject to the terms and conditions of the GNU General Public
 *  License. See the file COPYING in the main directory of this archive for
 *  more details.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/errno.h>
#include <linux/string.h>
#include <linux/mm.h>
#include <linux/tty.h>
#include <linux/slab.h>
#include <linux/vmalloc.h>
#include <linux/delay.h>
#include <linux/interrupt.h>
#include <linux/fb.h>
#include <linux/init.h>

/*
 * Video RAM at physical 0x0A200000 (KSEG1 virtual 0xAA200000).
 * 240x320 display, xres_virtual=256, 16bpp.
 * Stride = 256 * 2 = 512 bytes per line.
 *
 * Color format per hardware.txt: RGB565 (bits 15-11=R, 10-5=G, 4-0=B).
 * fbdev mmap exposes the physical framebuffer while screen_base uses the
 * uncached KSEG1 alias for kernel-side cfb helpers.
 */
#define VIDEORAM_PHYS	0x0a200000
#define VIDEORAM_KSEG1	0xaa200000
#define VIDEOMEMSIZE	(320 * 256 * 16 / 8)

static u_long videomemory = VIDEORAM_KSEG1;
static u_long videomemory_phys = VIDEORAM_PHYS;
static u_long videomemorysize = VIDEOMEMSIZE;

static struct fb_info fb_info;
static u32 sfb_pseudo_palette[17];

#define MAX_REGNO 15

static struct fb_var_screeninfo sfb_default __initdata = {
	.xres		= 240,
	.yres		= 320,
	.xres_virtual	= 256,
	.yres_virtual	= 320,
	.bits_per_pixel	= 16,
	.red		= { .offset = 11, .length = 5, },
	.green		= { .offset = 5,  .length = 6, },
	.blue		= { .offset = 0,  .length = 5, },
	.activate	= FB_ACTIVATE_NOW,
	.height		= -1,
	.width		= -1,
	.pixclock	= 20000,
	.left_margin	= 64,
	.right_margin	= 64,
	.upper_margin	= 32,
	.lower_margin	= 32,
	.hsync_len	= 64,
	.vsync_len	= 2,
	.vmode		= FB_VMODE_NONINTERLACED,
};

static struct fb_fix_screeninfo sfb_fix __initdata = {
	.id		= "Casio BE-x00 FB",
	.type		= FB_TYPE_PACKED_PIXELS,
	.visual		= FB_VISUAL_TRUECOLOR,
	.ypanstep	= 0,
	.accel		= FB_ACCEL_NONE,
};

static int sfb_check_var(struct fb_var_screeninfo *var,
			 struct fb_info *info);
static int sfb_set_par(struct fb_info *info);
static int sfb_setcolreg(u_int regno, u_int red, u_int green, u_int blue,
			 u_int transp, struct fb_info *info);
static int sfb_pan_display(struct fb_var_screeninfo *var,
			   struct fb_info *info);
static int sfb_mmap(struct fb_info *info,
		    struct vm_area_struct *vma);

static struct fb_ops sfb_ops = {
	.owner		= THIS_MODULE,
	.fb_check_var	= sfb_check_var,
	.fb_set_par	= sfb_set_par,
	.fb_setcolreg	= sfb_setcolreg,
	.fb_pan_display	= sfb_pan_display,
	.fb_fillrect	= cfb_fillrect,
	.fb_copyarea	= cfb_copyarea,
	.fb_imageblit	= cfb_imageblit,
	.fb_mmap	= sfb_mmap,
};

static u_long get_line_length(int xres_virtual, int bpp)
{
	u_long length;

	length = xres_virtual * bpp;
	length = (length + 31) & ~31;
	length >>= 3;
	return (length);
}

static int sfb_check_var(struct fb_var_screeninfo *var,
			 struct fb_info *info)
{
	u_long line_length;

	if (var->vmode & FB_VMODE_CONUPDATE) {
		var->vmode |= FB_VMODE_YWRAP;
		var->xoffset = info->var.xoffset;
		var->yoffset = info->var.yoffset;
	}

	if (!var->xres)
		var->xres = 1;
	if (!var->yres)
		var->yres = 1;
	if (var->xres > var->xres_virtual)
		var->xres_virtual = var->xres;
	if (var->yres > var->yres_virtual)
		var->yres_virtual = var->yres;
	if (var->bits_per_pixel <= 1)
		var->bits_per_pixel = 1;
	else if (var->bits_per_pixel <= 8)
		var->bits_per_pixel = 8;
	else if (var->bits_per_pixel <= 16)
		var->bits_per_pixel = 16;
	else if (var->bits_per_pixel <= 24)
		var->bits_per_pixel = 24;
	else if (var->bits_per_pixel <= 32)
		var->bits_per_pixel = 32;
	else
		return -EINVAL;

	if (var->xres_virtual < var->xoffset + var->xres)
		var->xres_virtual = var->xoffset + var->xres;
	if (var->yres_virtual < var->yoffset + var->yres)
		var->yres_virtual = var->yoffset + var->yres;

	line_length =
	    get_line_length(var->xres_virtual, var->bits_per_pixel);
	if (line_length * var->yres_virtual > videomemorysize)
		return -ENOMEM;

	switch (var->bits_per_pixel) {
	case 1:
	case 8:
		var->red.offset = 0;
		var->red.length = 8;
		var->green.offset = 0;
		var->green.length = 8;
		var->blue.offset = 0;
		var->blue.length = 8;
		var->transp.offset = 0;
		var->transp.length = 0;
		break;
	case 16:		/* RGB 565 */
		var->red.offset = 11;
		var->red.length = 5;
		var->green.offset = 5;
		var->green.length = 6;
		var->blue.offset = 0;
		var->blue.length = 5;
		var->transp.offset = 0;
		var->transp.length = 0;
		break;
	case 24:		/* RGB 888 */
		var->red.offset = 0;
		var->red.length = 8;
		var->green.offset = 8;
		var->green.length = 8;
		var->blue.offset = 16;
		var->blue.length = 8;
		var->transp.offset = 0;
		var->transp.length = 0;
		break;
	case 32:		/* RGBA 8888 */
		var->red.offset = 0;
		var->red.length = 8;
		var->green.offset = 8;
		var->green.length = 8;
		var->blue.offset = 16;
		var->blue.length = 8;
		var->transp.offset = 24;
		var->transp.length = 8;
		break;
	}
	var->red.msb_right = 0;
	var->green.msb_right = 0;
	var->blue.msb_right = 0;
	var->transp.msb_right = 0;

	return 0;
}

static int sfb_set_par(struct fb_info *info)
{
	info->fix.line_length = get_line_length(info->var.xres_virtual,
						info->var.bits_per_pixel);
	return 0;
}

static int sfb_setcolreg(u_int regno, u_int red, u_int green, u_int blue,
			 u_int transp, struct fb_info *info)
{
	if (regno >= MAX_REGNO)
		return 1;

	if (info->var.grayscale) {
		red = green = blue =
		    (red * 77 + green * 151 + blue * 28) >> 8;
	}

#define CNVT_TOHW(val,width) ((((val)<<(width))+0x7FFF-(val))>>16)
	switch (info->fix.visual) {
	case FB_VISUAL_TRUECOLOR:
	case FB_VISUAL_PSEUDOCOLOR:
		red = CNVT_TOHW(red, info->var.red.length);
		green = CNVT_TOHW(green, info->var.green.length);
		blue = CNVT_TOHW(blue, info->var.blue.length);
		transp = CNVT_TOHW(transp, info->var.transp.length);
		break;
	case FB_VISUAL_DIRECTCOLOR:
		red = CNVT_TOHW(red, 8);
		green = CNVT_TOHW(green, 8);
		blue = CNVT_TOHW(blue, 8);
		transp = CNVT_TOHW(transp, 8);
		break;
	}
#undef CNVT_TOHW

	if (info->fix.visual == FB_VISUAL_TRUECOLOR) {
		u32 v;

		if (regno >= 16)
			return 1;

		v = (red << info->var.red.offset) |
		    (green << info->var.green.offset) |
		    (blue << info->var.blue.offset) |
		    (transp << info->var.transp.offset);
		switch (info->var.bits_per_pixel) {
		case 8:
			break;
		case 16:
		case 24:
		case 32:
			((u32 *) (info->pseudo_palette))[regno] = v;
			break;
		}
		return 0;
	}
	return 0;
}

static int sfb_pan_display(struct fb_var_screeninfo *var,
			   struct fb_info *info)
{
	if (var->xoffset || var->yoffset)
		return -EINVAL;
	if (var->vmode & FB_VMODE_YWRAP) {
		if (var->yoffset < 0
		    || var->yoffset >= info->var.yres_virtual
		    || var->xoffset)
			return -EINVAL;
	} else {
		if (var->xoffset + var->xres > info->var.xres_virtual ||
		    var->yoffset + var->yres > info->var.yres_virtual)
			return -EINVAL;
	}
	info->var.xoffset = var->xoffset;
	info->var.yoffset = var->yoffset;
	if (var->vmode & FB_VMODE_YWRAP)
		info->var.vmode |= FB_VMODE_YWRAP;
	else
		info->var.vmode &= ~FB_VMODE_YWRAP;
	return 0;
}

static int sfb_mmap(struct fb_info *info,
		    struct vm_area_struct *vma)
{
	unsigned long len = vma->vm_end - vma->vm_start;
	unsigned long pfn;

	if (vma->vm_pgoff > (videomemorysize >> PAGE_SHIFT))
		return -EINVAL;
	if (len > videomemorysize - (vma->vm_pgoff << PAGE_SHIFT))
		return -EINVAL;

	pfn = (videomemory_phys >> PAGE_SHIFT) + vma->vm_pgoff;

	vma->vm_page_prot = pgprot_noncached(vma->vm_page_prot);
	if (remap_pfn_range(vma, vma->vm_start, pfn, len, vma->vm_page_prot))
		return -EAGAIN;

	return 0;
}

static int __init sfb_init(void)
{
	fb_info.fbops = &sfb_ops;
	videomemory = VIDEORAM_KSEG1;
	fb_info.screen_base = (char *)videomemory;
	fb_info.screen_size = videomemorysize;

	fb_info.var = sfb_default;

	fb_info.fix = sfb_fix;
	fb_info.fix.smem_start = videomemory_phys;
	fb_info.fix.smem_len = videomemorysize;
	fb_info.fix.type_aux = 0;
	sfb_set_par(&fb_info);

	fb_info.pseudo_palette = &sfb_pseudo_palette;
	fb_info.flags = FBINFO_DEFAULT;

	fb_alloc_cmap(&fb_info.cmap, 256, 0);

	if (register_framebuffer(&fb_info) < 0) {
		printk(KERN_ERR "sfb: register_framebuffer failed\n");
		return -EINVAL;
	}

	printk(KERN_INFO
	       "fb%d: Casio BE-x00 frame buffer device, using %ldK of video memory\n",
	       fb_info.node, videomemorysize >> 10);

	return 0;
}

device_initcall(sfb_init);

MODULE_LICENSE("GPL");
