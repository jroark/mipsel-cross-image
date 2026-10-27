/* SPDX-License-Identifier: GPL-2.0-only
 * WE18 command ABI for the 2.6.8.1 driver's legacy do_ioctl fallback.
 * Values/layouts are Linux Wireless Extensions UAPI, not private ioctls.
 * Existing WE17 scan-event and ESSID layouts remain unchanged.
 */
#ifndef BE300_WIFI_WEXT_H
#define BE300_WIFI_WEXT_H
#ifndef SIOCSIWAUTH
#define SIOCSIWMLME 0x8b16
#define SIOCSIWGENIE 0x8b30
#define SIOCGIWGENIE 0x8b31
#define SIOCSIWAUTH 0x8b32
#define SIOCGIWAUTH 0x8b33
#define SIOCSIWENCODEEXT 0x8b34
#define SIOCGIWENCODEEXT 0x8b35
#define IWEVGENIE 0x8c05
#define IW_AUTH_INDEX 0x0fff
#define IW_AUTH_WPA_VERSION 0
#define IW_AUTH_CIPHER_PAIRWISE 1
#define IW_AUTH_CIPHER_GROUP 2
#define IW_AUTH_KEY_MGMT 3
#define IW_AUTH_TKIP_COUNTERMEASURES 4
#define IW_AUTH_DROP_UNENCRYPTED 5
#define IW_AUTH_80211_AUTH_ALG 6
#define IW_AUTH_WPA_ENABLED 7
#define IW_AUTH_RX_UNENCRYPTED_EAPOL 8
#define IW_AUTH_ROAMING_CONTROL 9
#define IW_AUTH_PRIVACY_INVOKED 10
#define IW_AUTH_WPA_VERSION_DISABLED 1
#define IW_AUTH_WPA_VERSION_WPA 2
#define IW_AUTH_WPA_VERSION_WPA2 4
#define IW_AUTH_CIPHER_NONE 1
#define IW_AUTH_CIPHER_WEP40 2
#define IW_AUTH_CIPHER_TKIP 4
#define IW_AUTH_CIPHER_CCMP 8
#define IW_AUTH_CIPHER_WEP104 16
#define IW_AUTH_KEY_MGMT_PSK 2
#define IW_AUTH_ALG_OPEN_SYSTEM 1
#define IW_AUTH_ALG_SHARED_KEY 2
#define IW_ENCODE_ALG_NONE 0
#define IW_ENCODE_ALG_WEP 1
#define IW_ENCODE_ALG_TKIP 2
#define IW_ENCODE_ALG_CCMP 3
#define IW_ENCODE_EXT_TX_SEQ_VALID 1
#define IW_ENCODE_EXT_RX_SEQ_VALID 2
#define IW_ENCODE_EXT_GROUP_KEY 4
#define IW_ENCODE_EXT_SET_TX_KEY 8
#define IW_ENCODE_SEQ_MAX_SIZE 8
struct iw_encode_ext {
	__u32 ext_flags;
	__u8 tx_seq[8], rx_seq[8];
	struct sockaddr addr;
	__u16 alg, key_len;
	__u8 key[0];
};
struct iw_mlme {
	__u16 cmd, reason_code;
	struct sockaddr addr;
};
#define IW_MLME_DEAUTH 0
#define IW_MLME_DISASSOC 1
#endif
#ifndef IW_AUTH_MFP
#define IW_AUTH_MFP 12
#endif
#endif
