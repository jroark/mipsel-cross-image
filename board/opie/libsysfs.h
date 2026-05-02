#ifndef BE300_LIBSYSFS_STUB_H
#define BE300_LIBSYSFS_STUB_H

#include <stddef.h>

#define SYSFS_PATH_MAX 256

struct sysfs_attribute {
	char name[SYSFS_PATH_MAX];
	char path[256];
	char value[256];
	size_t len;
};

struct sysfs_class {
	int unused;
};

struct sysfs_class_device {
	int unused;
};

struct dlist {
	int unused;
};

#define dlist_for_each_data(list, data, type) \
	for ((data) = (type *)0; (data) != (type *)0; )

#ifdef __cplusplus
extern "C" {
#endif

struct sysfs_class *sysfs_open_class(const char *name);
void sysfs_close_class(struct sysfs_class *cls);
struct sysfs_class_device *sysfs_get_class_device(struct sysfs_class *cls,
						  const char *name);
struct dlist *sysfs_get_class_devices(struct sysfs_class *cls);
struct dlist *sysfs_get_classdev_attributes(struct sysfs_class_device *dev);
struct sysfs_attribute *sysfs_get_classdev_attr(struct sysfs_class_device *dev,
						const char *name);
struct sysfs_attribute *sysfs_open_attribute(const char *path);
void sysfs_close_attribute(struct sysfs_attribute *attr);
int sysfs_read_attribute(struct sysfs_attribute *attr);
int sysfs_write_attribute(struct sysfs_attribute *attr, const char *value,
			  size_t len);

#ifdef __cplusplus
}
#endif

#endif
