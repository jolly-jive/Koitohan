# CLAUDE.md(`tftpd-hpa/`)

リポジトリの直下の `CLAUDE.md` の続きで、`tftpd-hpa/` に関わる部分。全体の構成、コマンド、複数のディレクトリにまたがる注意は直下にある。

**tftpd-hpa。** 公式イメージがないため、`tftpd-hpa/build/`(Alpine + `tftp-hpa` パッケージ)から `koitohan/tftpd-hpa` をビルドする。`in.tftpd` は uid 1000 で動き、syslog にしか出力しないので、`entrypoint.sh` が busybox の `syslogd` を並走させて、標準出力(`docker compose logs tftpd-hpa` で要求元とファイル名が見える)と、ファイル(`/var/log/tftpd/tftpd.log`。ホスト側は `tftpd-hpa/log/tftpd.log`。root 所有、0644)の両方へ流す。出力先はイメージの `/etc/syslog.conf`(`tftpd-hpa/build/syslog.conf`)に書いてある(`-O` で指定できるのは1つだけ)。`-s 0` は外さないこと。外すと `syslogd` が 200KB で自分で切り替え、1世代しか残さない(切り替えは Docker ホストの logrotate に任せている)。記録は要求の時点のもので、転送が済んだかどうかは残らない。設計は `docs/basic-design.md` の 6.3 節。`syslogd` の `-t` は外さないこと。musl の `syslog()` は時刻を UTC で付けるため、これを捨てて `syslogd` に `TZ` の時刻を付け直させている。`--permissive` は外さないこと。これがないと、`--umask 022` で作った新規ファイルを「全員に書き込み可ではない」として自分で拒否し、アップロードが 0 バイトのファイルを残して失敗する。

TFTP のルートは `tftpd-hpa/tftpboot/`。`firmware/` は `:ro` でマウントする配布専用、`configs/` が唯一の書き込み先。認証がないので書き込み量を2段で制限している。1ファイルあたりは `ulimits: fsize`(`.env` の `TFTP_UPLOAD_MAX_BYTES`)。超過した転送はエラーを返さずタイムアウトし、上限サイズの書きかけのファイルが残る。総量は、固定サイズのループバックイメージ `tftpd-hpa/configs.img` を `configs/` にマウントして制限する。これはホスト側の `sudo` 作業(`/etc/fstab`)で、手順は `docs/tftp.md` にあり、`make` には含めない。
