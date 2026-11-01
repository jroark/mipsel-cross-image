/* BE300 MTD backport: inode-cache lookup, as in later Linux 2.4. */
struct inode *ilookup(struct super_block *sb, unsigned long ino)
{
	struct list_head *head = inode_hashtable + hash(sb, ino);
	struct inode *inode;

	spin_lock(&inode_lock);
	inode = find_inode(sb, ino, head, NULL, NULL);
	if (inode) {
		__iget(inode);
		spin_unlock(&inode_lock);
		wait_on_inode(inode);
		return inode;
	}
	spin_unlock(&inode_lock);
	return NULL;
}
