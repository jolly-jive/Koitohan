#!/bin/sh
set -eu

# in.tftpd cannot limit the source by itself, so put a packet filter in
# place before it starts. Without the filter the container does not start
# (it does not listen without the limit).
networks=$(printf '%s' "${DEVICE_NETWORKS:-}" | tr -s ' \t\n' ',,,' | sed 's/^,//; s/,$//')
if [ -z "$networks" ]; then
    echo "DEVICE_NETWORKS is empty" >&2
    exit 1
fi
if ! printf '%s' "$networks" | grep -Eq '^[0-9./,]+$'; then
    echo "DEVICE_NETWORKS must be IPv4 addresses or prefixes separated by spaces: $DEVICE_NETWORKS" >&2
    exit 1
fi

# The server starts the transfer from another port, so the request
# (69/udp) is all there is to look at. The table is inet, so this drops
# IPv6 as well.
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

# Nothing from here on keeps NET_ADMIN. The listening process of in.tftpd
# stays root (the child for each request is the one that goes down to
# uid 1000), and could change the rules otherwise.
# The setpriv of busybox has no --bounding-set; this is the one of
# util-linux.
drop="setpriv --bounding-set -net_admin"

# in.tftpd writes to syslog only, so pass it on to the stdout of the
# container and to a file (/var/log/tftpd/tftpd.log). /etc/syslog.conf
# names the two.
# The syslog() of musl stamps the time in UTC; -t drops it, and syslogd
# stamps it again in TZ.
# The logrotate of the Docker host rotates the file, so -s 0 stops syslogd
# from rotating it by itself (at 200KB by default). syslogd makes the file
# again on the next write after it is moved away.
mkdir -p /var/log/tftpd
$drop syslogd -n -t -s 0 -f /etc/syslog.conf -O - &

exec $drop in.tftpd --foreground --user tftpd --secure --create --permissive --umask 022 --verbose /tftpboot
