/*
 * Tiny libsysfs compatibility layer for the OPIE components that probe power,
 * RTC, and PCMCIA state.  The BE-300 image already manages these devices from
 * kernel drivers and BusyBox scripts; returning "not present" keeps OPIE small
 * and avoids pulling in the obsolete libsysfs dependency.
 */
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sysfs/libsysfs.h>

struct sysfs_class *sysfs_open_class(const char *name)
{
	(void)name;
	errno = ENOENT;
	return NULL;
}

void sysfs_close_class(struct sysfs_class *cls)
{
	(void)cls;
}

struct sysfs_class_device *sysfs_get_class_device(struct sysfs_class *cls,
						  const char *name)
{
	(void)cls;
	(void)name;
	errno = ENOENT;
	return NULL;
}

struct dlist *sysfs_get_class_devices(struct sysfs_class *cls)
{
	(void)cls;
	return NULL;
}

struct dlist *sysfs_get_classdev_attributes(struct sysfs_class_device *dev)
{
	(void)dev;
	return NULL;
}

struct sysfs_attribute *sysfs_get_classdev_attr(struct sysfs_class_device *dev,
						const char *name)
{
	(void)dev;
	(void)name;
	errno = ENOENT;
	return NULL;
}

struct sysfs_attribute *sysfs_open_attribute(const char *path)
{
	struct sysfs_attribute *attr;

	attr = calloc(1, sizeof(*attr));
	if (!attr)
		return NULL;
	if (path) {
		const char *name;

		strncpy(attr->path, path, sizeof(attr->path) - 1);
		name = strrchr(path, '/');
		if (name)
			name++;
		else
			name = path;
		strncpy(attr->name, name, sizeof(attr->name) - 1);
	}
	return attr;
}

void sysfs_close_attribute(struct sysfs_attribute *attr)
{
	free(attr);
}

int sysfs_read_attribute(struct sysfs_attribute *attr)
{
	if (!attr)
		return -1;
	attr->value[0] = '\0';
	attr->len = 0;
	return 0;
}

int sysfs_write_attribute(struct sysfs_attribute *attr, const char *value,
			  size_t len)
{
	(void)attr;
	(void)value;
	(void)len;
	return 0;
}
