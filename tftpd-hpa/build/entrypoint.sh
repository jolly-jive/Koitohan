#!/bin/sh
set -eu

# in.tftpd は syslog にしか出力しないので、コンテナの標準出力へ流す
syslogd -n -O - &

exec in.tftpd --foreground --user tftpd --secure --create --permissive --umask 022 --verbose /tftpboot
