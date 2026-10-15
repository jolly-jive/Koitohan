#!/bin/sh
set -eu

# The listener of FreeRADIUS v4 has a "networks" section, but it limits
# only the sources that may define dynamic clients, and is ignored
# without them. So the packets are dropped by a filter before they reach
# radiusd. Without the filter the container does not start (it does not
# listen without the limit).
networks=$(printf '%s' "${DEVICE_NETWORKS:-}" | tr -s ' \t\n' ',,,' | sed 's/^,//; s/,$//')
if [ -z "$networks" ]; then
    echo "DEVICE_NETWORKS is empty" >&2
    exit 1
fi
if ! printf '%s' "$networks" | grep -Eq '^[0-9./,]+$'; then
    echo "DEVICE_NETWORKS must be IPv4 addresses or prefixes separated by spaces: $DEVICE_NETWORKS" >&2
    exit 1
fi

# The loopback stays open: the smoke test sends its requests from inside
# the container. The replies from OpenLDAP pass as established, and the
# embedded DNS of Docker as loopback. The table is inet, so this drops
# IPv6 as well.
nft -f - <<EOF
table inet koitohan {
	chain input {
		type filter hook input priority filter; policy drop;
		iif "lo" accept
		ct state established,related accept
		ip saddr { $networks } udp dport 1812 accept
	}
}
EOF

# Nothing from here on keeps NET_ADMIN. radiusd starts as root and could
# change the rules otherwise. The entrypoint of the base image starts it.
exec setpriv --bounding-set -net_admin /docker-entrypoint.sh "$@"
