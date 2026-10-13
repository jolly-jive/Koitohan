#!/bin/sh
set -eu

# in.tftpd には接続元を絞る機能がないので、起動の前にパケットフィルタを入れる
# 入れられなければ起動しない(制限のないまま待ち受けない)
networks=$(printf '%s' "${DEVICE_NETWORKS:-}" | tr -s ' \t\n' ',,,' | sed 's/^,//; s/,$//')
if [ -z "$networks" ]; then
    echo "DEVICE_NETWORKS is empty" >&2
    exit 1
fi
if ! printf '%s' "$networks" | grep -Eq '^[0-9./,]+$'; then
    echo "DEVICE_NETWORKS must be IPv4 addresses or prefixes separated by spaces: $DEVICE_NETWORKS" >&2
    exit 1
fi

# 転送はサーバーが別のポートから送り始めるので、要求(69/udp)だけを見れば足りる
# inet のテーブルなので、IPv6 もここで捨てる
nft -f - <<EOF
table inet koitohan {
	chain input {
		type filter hook input priority filter; policy drop;
		iif "lo" accept
		ct state established,related accept
		ip saddr { $networks } udp dport 69 accept
	}
}
EOF

# ここから先は NET_ADMIN を持たせない。in.tftpd の待ち受けのプロセスは root のまま残る
# (uid 1000 に降りるのは、要求ごとの子プロセス)ので、落とさないとルールを変えられる
# busybox の setpriv には --bounding-set がないので、util-linux のものを使う
drop="setpriv --bounding-set -net_admin"

# in.tftpd は syslog にしか出力しないので、コンテナの標準出力へ流す
# musl の syslog() は時刻を UTC で付けるので、-t で捨てて syslogd に TZ の時刻を付け直させる
$drop syslogd -n -t -O - &

exec $drop in.tftpd --foreground --user tftpd --secure --create --permissive --umask 022 --verbose /tftpboot
