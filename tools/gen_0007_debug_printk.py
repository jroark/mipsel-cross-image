#!/usr/bin/env python3
"""Apply BE300DBG: printk markers to a 2.4.18 fs/ tree.

Reads /tmp/0007_stage as the tree to edit in place.  Used by
gen_0007_debug_printk.sh to generate the patch file via diff.
"""
import sys
from pathlib import Path

STAGE = Path("/tmp/0007_stage")


def edit(rel, old, new):
    p = STAGE / rel
    data = p.read_text(encoding="latin-1")
    if old not in data:
        print(f"NOT FOUND in {rel}: {old[:120]!r}", file=sys.stderr)
        sys.exit(2)
    cnt = data.count(old)
    if cnt > 1:
        print(f"AMBIGUOUS in {rel} ({cnt}x): {old[:120]!r}", file=sys.stderr)
        sys.exit(3)
    p.write_text(data.replace(old, new), encoding="latin-1")
    print(f"  edited {rel}")


# fs/namespace.c — do_add_mount
edit("fs/namespace.c",
     "static int do_add_mount(struct nameidata *nd, char *type, int flags,\n"
     "\t\t\tint mnt_flags, char *name, void *data)\n"
     "{\n"
     "\tstruct vfsmount *mnt = do_kern_mount(type, flags, name, data);\n"
     "\tint err = PTR_ERR(mnt);\n"
     "\n"
     "\tif (IS_ERR(mnt))\n"
     "\t\tgoto out;\n"
     "\n"
     "\tdown(&mount_sem);\n",
     "static int do_add_mount(struct nameidata *nd, char *type, int flags,\n"
     "\t\t\tint mnt_flags, char *name, void *data)\n"
     "{\n"
     "\tstruct vfsmount *mnt;\n"
     "\tint err;\n"
     "\n"
     "\tprintk(KERN_EMERG \"BE300DBG: do_add_mount: enter type=%s flags=0x%x\\n\",\n"
     "\t       type ? type : \"(null)\", flags);\n"
     "\tmnt = do_kern_mount(type, flags, name, data);\n"
     "\terr = PTR_ERR(mnt);\n"
     "\tprintk(KERN_EMERG \"BE300DBG: do_add_mount: do_kern_mount -> %p\\n\", mnt);\n"
     "\tif (IS_ERR(mnt))\n"
     "\t\tgoto out;\n"
     "\n"
     "\tprintk(KERN_EMERG \"BE300DBG: do_add_mount: before down(&mount_sem)\\n\");\n"
     "\tdown(&mount_sem);\n"
     "\tprintk(KERN_EMERG \"BE300DBG: do_add_mount: after  down(&mount_sem)\\n\");\n")

# fs/namespace.c — do_add_mount: graft_tree + exit
edit("fs/namespace.c",
     "\tmnt->mnt_flags = mnt_flags;\n"
     "\terr = graft_tree(mnt, nd);\n"
     "unlock:\n"
     "\tup(&mount_sem);\n"
     "\tmntput(mnt);\n"
     "out:\n"
     "\treturn err;\n"
     "}\n",
     "\tmnt->mnt_flags = mnt_flags;\n"
     "\tprintk(KERN_EMERG \"BE300DBG: do_add_mount: before graft_tree\\n\");\n"
     "\terr = graft_tree(mnt, nd);\n"
     "\tprintk(KERN_EMERG \"BE300DBG: do_add_mount: graft_tree -> %d\\n\", err);\n"
     "unlock:\n"
     "\tup(&mount_sem);\n"
     "\tmntput(mnt);\n"
     "out:\n"
     "\tprintk(KERN_EMERG \"BE300DBG: do_add_mount: exit err=%d\\n\", err);\n"
     "\treturn err;\n"
     "}\n")

# fs/namespace.c — do_mount entry
edit("fs/namespace.c",
     "long do_mount(char * dev_name, char * dir_name, char *type_page,\n"
     "\t\t  unsigned long flags, void *data_page)\n"
     "{\n"
     "\tstruct nameidata nd;\n"
     "\tint retval = 0;\n"
     "\tint mnt_flags = 0;\n"
     "\n"
     "\t/* Discard magic */\n",
     "long do_mount(char * dev_name, char * dir_name, char *type_page,\n"
     "\t\t  unsigned long flags, void *data_page)\n"
     "{\n"
     "\tstruct nameidata nd;\n"
     "\tint retval = 0;\n"
     "\tint mnt_flags = 0;\n"
     "\tprintk(KERN_EMERG \"BE300DBG: do_mount: dev=%s dir=%s type=%s flags=0x%lx\\n\",\n"
     "\t       dev_name ? dev_name : \"(null)\", dir_name ? dir_name : \"(null)\",\n"
     "\t       type_page ? type_page : \"(null)\", flags);\n"
     "\n"
     "\t/* Discard magic */\n")

# fs/namespace.c — do_mount exit
edit("fs/namespace.c",
     "\t\tretval = do_add_mount(&nd, type_page, flags, mnt_flags,\n"
     "\t\t\t\t      dev_name, data_page);\n"
     "\tpath_release(&nd);\n"
     "\treturn retval;\n"
     "}\n"
     "\n"
     "asmlinkage long sys_mount(",
     "\t\tretval = do_add_mount(&nd, type_page, flags, mnt_flags,\n"
     "\t\t\t\t      dev_name, data_page);\n"
     "\tpath_release(&nd);\n"
     "\tprintk(KERN_EMERG \"BE300DBG: do_mount: exit retval=%d\\n\", retval);\n"
     "\treturn retval;\n"
     "}\n"
     "\n"
     "asmlinkage long sys_mount(")

# fs/namespace.c — sys_mount entry
edit("fs/namespace.c",
     "asmlinkage long sys_mount(char * dev_name, char * dir_name, char * type,\n"
     "\t\t\t  unsigned long flags, void * data)\n"
     "{\n"
     "\tint retval;\n"
     "\tunsigned long data_page;\n",
     "asmlinkage long sys_mount(char * dev_name, char * dir_name, char * type,\n"
     "\t\t\t  unsigned long flags, void * data)\n"
     "{\n"
     "\tint retval;\n"
     "\tunsigned long data_page;\n"
     "\tprintk(KERN_EMERG \"BE300DBG: sys_mount: enter\\n\");\n")

# fs/namespace.c — sys_mount after do_mount
edit("fs/namespace.c",
     "\tlock_kernel();\n"
     "\tretval = do_mount((char*)dev_page, dir_page, (char*)type_page,\n"
     "\t\t\t  flags, (void*)data_page);\n"
     "\tunlock_kernel();\n"
     "\tfree_page(data_page);\n",
     "\tlock_kernel();\n"
     "\tretval = do_mount((char*)dev_page, dir_page, (char*)type_page,\n"
     "\t\t\t  flags, (void*)data_page);\n"
     "\tunlock_kernel();\n"
     "\tprintk(KERN_EMERG \"BE300DBG: sys_mount: post do_mount retval=%d\\n\", retval);\n"
     "\tfree_page(data_page);\n")

# fs/super.c — grab_super
edit("fs/super.c",
     "static int grab_super(struct super_block *s)\n"
     "{\n"
     "\ts->s_count++;\n"
     "\tspin_unlock(&sb_lock);\n"
     "\tdown_write(&s->s_umount);\n"
     "\tif (s->s_root) {\n"
     "\t\tspin_lock(&sb_lock);\n"
     "\t\tif (s->s_count > S_BIAS) {\n"
     "\t\t\tatomic_inc(&s->s_active);\n"
     "\t\t\ts->s_count--;\n"
     "\t\t\tspin_unlock(&sb_lock);\n"
     "\t\t\treturn 1;\n"
     "\t\t}\n"
     "\t\tspin_unlock(&sb_lock);\n"
     "\t}\n"
     "\tup_write(&s->s_umount);\n"
     "\tput_super(s);\n"
     "\treturn 0;\n"
     "}\n",
     "static int grab_super(struct super_block *s)\n"
     "{\n"
     "\ts->s_count++;\n"
     "\tprintk(KERN_EMERG \"BE300DBG: grab_super: s=%p s_count=%d before down_write\\n\", s, s->s_count);\n"
     "\tspin_unlock(&sb_lock);\n"
     "\tdown_write(&s->s_umount);\n"
     "\tprintk(KERN_EMERG \"BE300DBG: grab_super: s=%p after down_write s_root=%p\\n\", s, s->s_root);\n"
     "\tif (s->s_root) {\n"
     "\t\tspin_lock(&sb_lock);\n"
     "\t\tif (s->s_count > S_BIAS) {\n"
     "\t\t\tatomic_inc(&s->s_active);\n"
     "\t\t\ts->s_count--;\n"
     "\t\t\tspin_unlock(&sb_lock);\n"
     "\t\t\tprintk(KERN_EMERG \"BE300DBG: grab_super: ok s=%p\\n\", s);\n"
     "\t\t\treturn 1;\n"
     "\t\t}\n"
     "\t\tspin_unlock(&sb_lock);\n"
     "\t}\n"
     "\tup_write(&s->s_umount);\n"
     "\tput_super(s);\n"
     "\tprintk(KERN_EMERG \"BE300DBG: grab_super: FAIL s=%p\\n\", s);\n"
     "\treturn 0;\n"
     "}\n")

# fs/super.c — get_sb_single header
edit("fs/super.c",
     "static struct super_block *get_sb_single(struct file_system_type *fs_type,\n"
     "\tint flags, void *data)\n"
     "{\n"
     "\tstruct super_block * s = alloc_super();\n"
     "\tif (!s)\n"
     "\t\treturn ERR_PTR(-ENOMEM);\n",
     "static struct super_block *get_sb_single(struct file_system_type *fs_type,\n"
     "\tint flags, void *data)\n"
     "{\n"
     "\tstruct super_block * s;\n"
     "\tprintk(KERN_EMERG \"BE300DBG: get_sb_single: enter fs=%s flags=0x%x\\n\",\n"
     "\t       fs_type ? fs_type->name : \"(null)\", flags);\n"
     "\ts = alloc_super();\n"
     "\tif (!s)\n"
     "\t\treturn ERR_PTR(-ENOMEM);\n"
     "\tprintk(KERN_EMERG \"BE300DBG: get_sb_single: alloc_super -> %p\\n\", s);\n")

# fs/super.c — get_sb_single fs_supers check
edit("fs/super.c",
     "retry:\n"
     "\tspin_lock(&sb_lock);\n"
     "\tif (!list_empty(&fs_type->fs_supers)) {\n"
     "\t\tstruct super_block *old;\n"
     "\t\told = list_entry(fs_type->fs_supers.next, struct super_block,\n"
     "\t\t\t\ts_instances);\n"
     "\t\tif (!grab_super(old))\n"
     "\t\t\tgoto retry;\n"
     "\t\tdestroy_super(s);\n"
     "\t\tdo_remount_sb(old, flags, data);\n"
     "\t\treturn old;\n",
     "retry:\n"
     "\tspin_lock(&sb_lock);\n"
     "\tprintk(KERN_EMERG \"BE300DBG: get_sb_single: fs_supers_empty=%d\\n\",\n"
     "\t       list_empty(&fs_type->fs_supers));\n"
     "\tif (!list_empty(&fs_type->fs_supers)) {\n"
     "\t\tstruct super_block *old;\n"
     "\t\told = list_entry(fs_type->fs_supers.next, struct super_block,\n"
     "\t\t\t\ts_instances);\n"
     "\t\tprintk(KERN_EMERG \"BE300DBG: get_sb_single: existing old=%p before grab_super\\n\", old);\n"
     "\t\tif (!grab_super(old))\n"
     "\t\t\tgoto retry;\n"
     "\t\tdestroy_super(s);\n"
     "\t\tprintk(KERN_EMERG \"BE300DBG: get_sb_single: before do_remount_sb old=%p\\n\", old);\n"
     "\t\tdo_remount_sb(old, flags, data);\n"
     "\t\tprintk(KERN_EMERG \"BE300DBG: get_sb_single: after  do_remount_sb old=%p\\n\", old);\n"
     "\t\treturn old;\n")

# fs/super.c — get_sb_single first-time read_super path
edit("fs/super.c",
     "\t\ts->s_dev = dev;\n"
     "\t\ts->s_flags = flags;\n"
     "\t\tinsert_super(s, fs_type);\n"
     "\t\tlock_super(s);\n"
     "\t\tif (!fs_type->read_super(s, data, flags & MS_VERBOSE ? 1 : 0))\n"
     "\t\t\tgoto out_fail;\n",
     "\t\ts->s_dev = dev;\n"
     "\t\ts->s_flags = flags;\n"
     "\t\tinsert_super(s, fs_type);\n"
     "\t\tlock_super(s);\n"
     "\t\tprintk(KERN_EMERG \"BE300DBG: get_sb_single: before read_super (first-time)\\n\");\n"
     "\t\tif (!fs_type->read_super(s, data, flags & MS_VERBOSE ? 1 : 0))\n"
     "\t\t\tgoto out_fail;\n"
     "\t\tprintk(KERN_EMERG \"BE300DBG: get_sb_single: after  read_super\\n\");\n")

# fs/super.c — do_remount_sb entry + shrink_dcache_sb/fsync_super
edit("fs/super.c",
     "int do_remount_sb(struct super_block *sb, int flags, void *data)\n"
     "{\n"
     "\tint retval;\n"
     "\t\n"
     "\tif (!(flags & MS_RDONLY) && sb->s_dev && is_read_only(sb->s_dev))\n"
     "\t\treturn -EACCES;\n"
     "\t\t/*flags |= MS_RDONLY;*/\n"
     "\tif (flags & MS_RDONLY)\n"
     "\t\tacct_auto_close(sb->s_dev);\n"
     "\tshrink_dcache_sb(sb);\n"
     "\tfsync_super(sb);\n",
     "int do_remount_sb(struct super_block *sb, int flags, void *data)\n"
     "{\n"
     "\tint retval;\n"
     "\tprintk(KERN_EMERG \"BE300DBG: do_remount_sb: enter sb=%p flags=0x%x s_dev=0x%x\\n\",\n"
     "\t       sb, flags, sb->s_dev);\n"
     "\t\n"
     "\tif (!(flags & MS_RDONLY) && sb->s_dev && is_read_only(sb->s_dev))\n"
     "\t\treturn -EACCES;\n"
     "\t\t/*flags |= MS_RDONLY;*/\n"
     "\tif (flags & MS_RDONLY)\n"
     "\t\tacct_auto_close(sb->s_dev);\n"
     "\tprintk(KERN_EMERG \"BE300DBG: do_remount_sb: before shrink_dcache_sb\\n\");\n"
     "\tshrink_dcache_sb(sb);\n"
     "\tprintk(KERN_EMERG \"BE300DBG: do_remount_sb: before fsync_super\\n\");\n"
     "\tfsync_super(sb);\n"
     "\tprintk(KERN_EMERG \"BE300DBG: do_remount_sb: after  fsync_super\\n\");\n")

# fs/super.c — do_remount_sb remount_fs and exit
edit("fs/super.c",
     "\tif (sb->s_op && sb->s_op->remount_fs) {\n"
     "\t\tlock_super(sb);\n"
     "\t\tretval = sb->s_op->remount_fs(sb, &flags, data);\n"
     "\t\tunlock_super(sb);\n"
     "\t\tif (retval)\n"
     "\t\t\treturn retval;\n"
     "\t}\n"
     "\tsb->s_flags = (sb->s_flags & ~MS_RMT_MASK) | (flags & MS_RMT_MASK);\n",
     "\tif (sb->s_op && sb->s_op->remount_fs) {\n"
     "\t\tprintk(KERN_EMERG \"BE300DBG: do_remount_sb: before s_op->remount_fs\\n\");\n"
     "\t\tlock_super(sb);\n"
     "\t\tretval = sb->s_op->remount_fs(sb, &flags, data);\n"
     "\t\tunlock_super(sb);\n"
     "\t\tprintk(KERN_EMERG \"BE300DBG: do_remount_sb: after  s_op->remount_fs rc=%d\\n\", retval);\n"
     "\t\tif (retval)\n"
     "\t\t\treturn retval;\n"
     "\t} else {\n"
     "\t\tprintk(KERN_EMERG \"BE300DBG: do_remount_sb: no remount_fs op (sb->s_op=%p)\\n\", sb->s_op);\n"
     "\t}\n"
     "\tprintk(KERN_EMERG \"BE300DBG: do_remount_sb: exit ok\\n\");\n"
     "\tsb->s_flags = (sb->s_flags & ~MS_RMT_MASK) | (flags & MS_RMT_MASK);\n")

# fs/super.c — do_kern_mount header
edit("fs/super.c",
     "struct vfsmount *do_kern_mount(char *type, int flags, char *name, void *data)\n"
     "{\n"
     "\tstruct file_system_type * fstype;\n"
     "\tstruct vfsmount *mnt = NULL;\n"
     "\tstruct super_block *sb;\n"
     "\n"
     "\tif (!type || !memchr(type, 0, PAGE_SIZE))\n"
     "\t\treturn ERR_PTR(-EINVAL);\n",
     "struct vfsmount *do_kern_mount(char *type, int flags, char *name, void *data)\n"
     "{\n"
     "\tstruct file_system_type * fstype;\n"
     "\tstruct vfsmount *mnt = NULL;\n"
     "\tstruct super_block *sb;\n"
     "\tprintk(KERN_EMERG \"BE300DBG: do_kern_mount: enter type=%s name=%s\\n\",\n"
     "\t       type ? type : \"(null)\", name ? name : \"(null)\");\n"
     "\n"
     "\tif (!type || !memchr(type, 0, PAGE_SIZE))\n"
     "\t\treturn ERR_PTR(-EINVAL);\n")

# fs/super.c — do_kern_mount dispatch + exit
edit("fs/super.c",
     "\tset_devname(mnt, name);\n"
     "\t/* get locked superblock */\n"
     "\tif (fstype->fs_flags & FS_REQUIRES_DEV)\n"
     "\t\tsb = get_sb_bdev(fstype, name, flags, data);\n"
     "\telse if (fstype->fs_flags & FS_SINGLE)\n"
     "\t\tsb = get_sb_single(fstype, flags, data);\n"
     "\telse\n"
     "\t\tsb = get_sb_nodev(fstype, flags, data);\n"
     "\n"
     "\tif (IS_ERR(sb)) {\n"
     "\t\tfree_vfsmnt(mnt);\n"
     "\t\tmnt = (struct vfsmount *)sb;\n"
     "\t\tgoto fs_out;\n"
     "\t}\n"
     "\tif (fstype->fs_flags & FS_NOMOUNT)\n"
     "\t\tsb->s_flags |= MS_NOUSER;\n"
     "\n"
     "\tmnt->mnt_sb = sb;\n"
     "\tmnt->mnt_root = dget(sb->s_root);\n"
     "\tmnt->mnt_mountpoint = mnt->mnt_root;\n"
     "\tmnt->mnt_parent = mnt;\n"
     "\tup_write(&sb->s_umount);\n"
     "fs_out:\n"
     "\tput_filesystem(fstype);\n"
     "\treturn mnt;\n"
     "}\n",
     "\tset_devname(mnt, name);\n"
     "\t/* get locked superblock */\n"
     "\tif (fstype->fs_flags & FS_REQUIRES_DEV) {\n"
     "\t\tprintk(KERN_EMERG \"BE300DBG: do_kern_mount: dispatch=get_sb_bdev\\n\");\n"
     "\t\tsb = get_sb_bdev(fstype, name, flags, data);\n"
     "\t} else if (fstype->fs_flags & FS_SINGLE) {\n"
     "\t\tprintk(KERN_EMERG \"BE300DBG: do_kern_mount: dispatch=get_sb_single\\n\");\n"
     "\t\tsb = get_sb_single(fstype, flags, data);\n"
     "\t} else {\n"
     "\t\tprintk(KERN_EMERG \"BE300DBG: do_kern_mount: dispatch=get_sb_nodev\\n\");\n"
     "\t\tsb = get_sb_nodev(fstype, flags, data);\n"
     "\t}\n"
     "\tprintk(KERN_EMERG \"BE300DBG: do_kern_mount: after dispatch sb=%p err=%ld\\n\",\n"
     "\t       sb, IS_ERR(sb) ? PTR_ERR(sb) : 0L);\n"
     "\n"
     "\tif (IS_ERR(sb)) {\n"
     "\t\tfree_vfsmnt(mnt);\n"
     "\t\tmnt = (struct vfsmount *)sb;\n"
     "\t\tgoto fs_out;\n"
     "\t}\n"
     "\tif (fstype->fs_flags & FS_NOMOUNT)\n"
     "\t\tsb->s_flags |= MS_NOUSER;\n"
     "\n"
     "\tmnt->mnt_sb = sb;\n"
     "\tmnt->mnt_root = dget(sb->s_root);\n"
     "\tmnt->mnt_mountpoint = mnt->mnt_root;\n"
     "\tmnt->mnt_parent = mnt;\n"
     "\tprintk(KERN_EMERG \"BE300DBG: do_kern_mount: before up_write(s_umount)\\n\");\n"
     "\tup_write(&sb->s_umount);\n"
     "\tprintk(KERN_EMERG \"BE300DBG: do_kern_mount: after  up_write(s_umount)\\n\");\n"
     "fs_out:\n"
     "\tput_filesystem(fstype);\n"
     "\tprintk(KERN_EMERG \"BE300DBG: do_kern_mount: exit mnt=%p\\n\", mnt);\n"
     "\treturn mnt;\n"
     "}\n")

# fs/proc/inode.c — proc_read_super entry
edit("fs/proc/inode.c",
     "struct super_block *proc_read_super(struct super_block *s,void *data, \n"
     "\t\t\t\t    int silent)\n"
     "{\n"
     "\tstruct inode * root_inode;\n"
     "\tstruct task_struct *p;\n"
     "\n"
     "\ts->s_blocksize = 1024;\n",
     "struct super_block *proc_read_super(struct super_block *s,void *data, \n"
     "\t\t\t\t    int silent)\n"
     "{\n"
     "\tstruct inode * root_inode;\n"
     "\tstruct task_struct *p;\n"
     "\tprintk(KERN_EMERG \"BE300DBG: proc_read_super: enter s=%p\\n\", s);\n"
     "\n"
     "\ts->s_blocksize = 1024;\n")

# fs/proc/inode.c — proc_read_super tasklist/d_alloc_root
edit("fs/proc/inode.c",
     "\t/*\n"
     "\t * Fixup the root inode's nlink value\n"
     "\t */\n"
     "\tread_lock(&tasklist_lock);\n"
     "\tfor_each_task(p) if (p->pid) root_inode->i_nlink++;\n"
     "\tread_unlock(&tasklist_lock);\n"
     "\ts->s_root = d_alloc_root(root_inode);\n"
     "\tif (!s->s_root)\n"
     "\t\tgoto out_no_root;\n"
     "\tparse_options(data, &root_inode->i_uid, &root_inode->i_gid);\n"
     "\treturn s;\n",
     "\t/*\n"
     "\t * Fixup the root inode's nlink value\n"
     "\t */\n"
     "\tprintk(KERN_EMERG \"BE300DBG: proc_read_super: before tasklist_lock\\n\");\n"
     "\tread_lock(&tasklist_lock);\n"
     "\tfor_each_task(p) if (p->pid) root_inode->i_nlink++;\n"
     "\tread_unlock(&tasklist_lock);\n"
     "\tprintk(KERN_EMERG \"BE300DBG: proc_read_super: after  tasklist_lock\\n\");\n"
     "\ts->s_root = d_alloc_root(root_inode);\n"
     "\tif (!s->s_root)\n"
     "\t\tgoto out_no_root;\n"
     "\tparse_options(data, &root_inode->i_uid, &root_inode->i_gid);\n"
     "\tprintk(KERN_EMERG \"BE300DBG: proc_read_super: exit ok s_root=%p\\n\", s->s_root);\n"
     "\treturn s;\n")

# fs/proc/root.c — proc_root_init: raise loglevel + entry print
edit("fs/proc/root.c",
     "void __init proc_root_init(void)\n"
     "{\n"
     "\tint err = register_filesystem(&proc_fs_type);\n",
     "void __init proc_root_init(void)\n"
     "{\n"
     "\tint err;\n"
     "\textern int console_loglevel;\n"
     "\tconsole_loglevel = 15;  /* BE300DBG: force KERN_* through to console */\n"
     "\tprintk(KERN_EMERG \"BE300DBG: proc_root_init: console_loglevel=15\\n\");\n"
     "\terr = register_filesystem(&proc_fs_type);\n")

print("All edits applied.")
