# ログ

[English](logs.md)

| パス                                    | 内容                         | ユーザーから(SSH)            |
| --------------------------------------- | ---------------------------- | ----------------------------- |
| `syslog-ng/log/Hosts/<アドレス>/<アドレス>.log` | 各機器の syslog      | `/logs/Hosts/<アドレス>/<アドレス>.log` |
| `syslog-ng/log/debug.log`               | すべての生メッセージ(調査用) | 見えない                      |
| `freeradius/log/`                       | FreeRADIUS の認証ログ        | 見えない                      |
| `tftpd-hpa/log/tftpd.log`               | TFTP の転送の記録            | 見えない                      |

ユーザーは Docker ホストに入れないので、各機器の syslog は、OpenSSH のコンテナに SSH でログインして読みます。読み方は「[ユーザーズガイド](user-guide.ja.md#ログを読む)」にあります。ほかのログは、こいとはん管理者が Docker ホストで読みます。

各機器の syslog は、送信元のアドレスごとのファイルに分かれます。各行は次の形です。

```
2026-11-15T09:24:30+09:00 core-switch %SYS-5-CONFIG_I: Configured from console by admin
```

- 行頭の時刻は、Koitohan が受け取った時刻です。機器がメッセージに載せた時刻は使いません。
- 続くホスト名は、機器が名乗ったものです(名乗らない機器ではアドレスになります)。
- ファイルの名前と時刻を機器の言い分で決めないのは、認証のない syslog では、機器のネットワークの中の誰でも、ほかの機器の名前と好きな時刻でログを送れるためです。ホスト名の欄は送る側が書いた値なので、確かなのはファイルの名前のほうです。
- 送信元のアドレスが複数ある機器は、ログを送るインターフェースを機器の設定で固定してください。固定しないと、ログが複数のファイルに分かれます。
- アドレス変換(NAT)を通って届く機器のログは、変換後のアドレスの1つのファイルにまとまります。

`freeradius/log/` のファイルは uid 101 の所有です。読むときは `sudo` を使ってください。

SSH のログインの記録はファイルには保存されません。`docker compose logs openssh` で確認します。

## ローテーション

上の表のファイルは、Docker ホストの logrotate が1日ごとに切り替えます。設定は `make` が `logrotate/koitohan` に生成するので、logrotate が読む場所に置いてください。

```sh
make logrotate_conf
sudo install -m 644 -o root -g root logrotate/koitohan /etc/logrotate.d/koitohan
```

`make host_check` で、置いたファイルが root の所有であること、グループとその他が書き込めないこと(書き込めると logrotate が読まない)、`logrotate/koitohan` と同じ中身であることを確かめられます。

| ファイル                                           | 切り替えたあとの名前                  | 残す日数 |
| -------------------------------------------------- | ------------------------------------- | -------- |
| `syslog-ng/log/Hosts/<アドレス>/<アドレス>.log`    | `<アドレス>.log-2026-10-10.gz`        | 1096(3年) |
| `syslog-ng/log/debug.log`                          | `debug.log-2026-10-10.gz`             | 7        |
| `freeradius/log/radius.log`                        | `radius.log-2026-10-10.gz`            | 1096     |
| `freeradius/log/radacct/<client>/auth-detail`、`reply-detail` | `auth-detail-2026-10-10.gz`、`reply-detail-2026-10-10.gz` | 1096 |
| `tftpd-hpa/log/tftpd.log`                          | `tftpd.log-2026-10-10.gz`             | 1096     |

- 名前の日付は、中身の日付です。切り替えは、日付が変わったあとに logrotate が動いたときに起きます。
- 前日のファイルは、もう1日だけ圧縮されずに残ります(`<アドレス>.log-2026-10-10`)。
- ログが1行もなかった日のファイルは作られません。
- logrotate は、初めて見たファイルを記録するだけで、切り替えは翌日から始めます。
- 生成される設定には、リポジトリの絶対パスと syslog-ng のコンテナ名(`.env` の `SYSLOG_CONTAINER_NAME`)が入ります。リポジトリを移動したときや、コンテナ名を変えたときは、上の2行をもう一度実行してください。
- 残す日数を変えるときは、`scripts/generate_logrotate.sh` の先頭の値を変えて、同じく2行を実行します。
- 設定を試すには、`sudo logrotate -d /etc/logrotate.d/koitohan` を使います。何も変更せずに、対象のファイルと判定を表示します。

## コンテナの標準出力

`docker compose logs` で読むログ(SSH のログイン、OpenLDAP、TFTP の転送)は、Docker のログドライバが保存します。このうち TFTP の転送だけは、同じものがファイルにも残ります。`compose.yaml` はドライバを指定せず、Docker ホストの設定に従います。

Docker の既定のドライバ(`json-file`)は、上限を指定しないかぎり、ログを際限なく残します。`/etc/docker/daemon.json` で、上限のあるドライバにしておいてください。たとえば、systemd の journal に送るには次のようにします。

```json
{
  "log-driver": "journald"
}
```

`journald` のほか、`local`(既定でローテーションします)や、`json-file` に `max-size` と `max-file` を指定する方法があります。変更は、Docker を再起動したあとに作られたコンテナから効きます。
