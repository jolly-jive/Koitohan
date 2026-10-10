#!/bin/sh
set -eu

# in.tftpd は syslog にしか出力しないので、コンテナの標準出力へ流す
# musl の syslog() は時刻を UTC で付けるので、-t で捨てて syslogd に TZ の時刻を付け直させる
syslogd -n -t -O - &

exec in.tftpd --foreground --user tftpd --secure --create --permissive --umask 022 --verbose /tftpboot
