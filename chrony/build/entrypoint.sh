#!/bin/sh
set -eu

# Serves the clock of the Docker host, which the container shares, with
# no upstream servers (docs/basic-design.md, section 3.6). The host keeps
# the clock in sync; chronyd only reads it (-x).

# Serving stops when the maxerror of the kernel goes over this, in
# microseconds. maxerror grows by 500us a second after the last sync of
# the host, so 3.6s is two hours under systemd-timesyncd. Only the smoke
# test sets NTP_MAX_ERROR_US.
max_error=${NTP_MAX_ERROR_US:-3600000}
interval=60

case $max_error in
    ''|*[!0-9]*)
        echo "NTP_MAX_ERROR_US must be a number of microseconds: $max_error" >&2
        exit 1
        ;;
esac

# chronyd takes a host name in allow and resolves it, so let digits, dots
# and slashes through only. chronyd stops on a malformed address or
# prefix by itself. Without the limit the container does not start.
networks=$(printf '%s' "${DEVICE_NETWORKS:-}" | tr -s ' \t\n' '   ' | sed 's/^ //; s/ $//')
if [ -z "$networks" ]; then
    echo "DEVICE_NETWORKS is empty" >&2
    exit 1
fi
if ! printf '%s' "$networks" | grep -Eq '^[0-9./ ]+$'; then
    echo "DEVICE_NETWORKS must be IPv4 addresses or prefixes separated by spaces: $DEVICE_NETWORKS" >&2
    exit 1
fi

# No local reference here: the loop below turns it on once it has seen
# that the host is in sync. Until then chronyd answers that it is not
# synchronised. cmdport 0 leaves chronyc the Unix socket only.
conf=/run/koitohan/chrony.conf
mkdir -p /run/koitohan
{
    echo 'cmdport 0'
    for network in $networks; do
        echo "allow $network"
    done
} > "$conf"

# chronyd binds 123/udp as root, then goes down to the user chrony
chronyd -d -x -f "$conf" &
chronyd_pid=$!

# Reads maxerror from the kernel; adjtimex needs no capability to read.
max_error_now() {
    adjtimex | awk '$1 == "maxerror:" { print $2 }'
}

watch_clock() {
    state=
    until chronyc -n tracking > /dev/null 2>&1; do
        sleep 1
    done
    while :; do
        error=$(max_error_now)
        if [ -z "$error" ]; then
            echo "koitohan: could not read maxerror with adjtimex" >&2
        elif [ "$error" -gt "$max_error" ]; then
            if [ "$state" != off ] && chronyc local off > /dev/null; then
                echo "koitohan: stopped serving, maxerror ${error}us is over ${max_error}us" >&2
                state=off
            fi
        else
            if [ "$state" != on ] && chronyc local stratum 10 > /dev/null; then
                echo "koitohan: serving the host clock, maxerror ${error}us" >&2
                state=on
            fi
        fi
        sleep "$interval"
    done
}

watch_clock &
watch_pid=$!

# The container ends with chronyd, and restart brings it back.
stopping=
trap 'stopping=1; kill "$chronyd_pid" 2> /dev/null' TERM INT
status=0
wait "$chronyd_pid" || status=$?
# A signal cuts the first wait short with 128 + the signal. The second
# one gets how chronyd itself ended.
if [ -n "$stopping" ]; then
    status=0
    wait "$chronyd_pid" || status=$?
fi
kill "$watch_pid" 2> /dev/null || true
exit "$status"
