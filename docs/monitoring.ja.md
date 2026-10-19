# 稼働の確認

[English](monitoring.md)

Koitohan のサービスは、止まっても気づかれにくいものです。

- RADIUS は、止まれば機器にログインできなくなるので気づきます。ただ、ネットワーク機器に日々ログインする運用は多くありません。気づくのが、障害の対応でログインしようとしたとき、ということになりかねません。
- syslog は UDP で送られ、届かなくても機器は何も言いません。
- TFTP によるコンフィグのバックアップも、失敗に気づくのは戻したくなったときです。
- NTP は、配るのをやめても、機器の時計が黙ってずれていくだけです。

`bin/check_services.sh` は、稼働中のスタックの各サービスを実際に使ってみて、動いているかを確かめます。確かめるだけで、知らせることはしません。cron から定期的に実行し、結果を自分に届くようにしておくことを強く推奨します。

Koitohan とは別の監視の仕組み(すでに運用している監視サーバーなど)があるなら、そちらから RADIUS、syslog、TFTP、NTP を確かめるほうが確実です。このコマンドは、そうした仕組みがないときのためのものです。

## 確かめること

| 項目                 | 確かめ方                                                                                     | NG / WARN になるとき                       |
| -------------------- | -------------------------------------------------------------------------------------------- | ------------------------------------------ |
| コンテナ             | 起動しているはずのコンテナの状態(再起動した回数も表示する)                                 | 動いていない(NG)                         |
| OpenLDAP             | OpenSSH のコンテナから、そのサービスアカウントで LDAPS に bind する                         | bind できない(NG)                        |
| FreeRADIUS           | コンテナの中から Status-Server を送る                                                        | 応答がない(NG)                           |
| syslog-ng            | 制御ソケットに問い合わせる                                                                   | 応答がない(NG)                           |
| ログの置き場所       | `syslog-ng/log/` のファイルシステムの空き                                                    | 90% 以上使っている(WARN)                 |
| tftpd-hpa            | コンテナの中から、ないファイルを要求する                                                     | `File not found` が返らない(NG)          |
| `configs/`           | コンテナから見た所有者と、ファイルシステムの空き                                             | `in.tftpd` が書けない(NG)、90% 以上(WARN) |
| OpenSSH              | コンテナの中から sshd に接続する                                                             | 応答がない(NG)                           |
| chrony               | 配っているか(`COMPOSE_PROFILES` に `ntp` があるときだけ)                                   | ホストの時計が同期しておらず、配るのをやめている(NG) |
| 証明書               | `CA/` の証明書の有効期限                                                                     | 30 日以内に切れる(WARN)                  |

要求はどれもコンテナの中からループバックで送ります。`DEVICE_NETWORKS` を絞っていても断られません。

`configs/` の所有者が `in.tftpd` でないのは、多くの場合、[TFTP](tftp.ja.md#アップロード先の容量を制限する強く推奨) のイメージファイルがマウントされていないか、tftpd-hpa を起動したあとでマウントしたときです。下にある root 所有のディレクトリが見えていて、アップロードはすべて失敗します。

## 実行する

スタックが起動している状態で、Docker ホストで実行します。`sudo` は要らず、何も変更しません。

```sh
bin/check_services.sh
```

```
OK    openldap: running since 2026-10-18 19:35:38, restarted 0 times
...
OK    freeradius: answers Status-Server
OK    syslog-ng: answers on its control socket
OK    logs: the filesystem of /path/to/koitohan/syslog-ng/log is 83% full
OK    tftpd-hpa: answers a request
...
OK    certificates: none expires within 30 days
```

項目ごとに `OK`、`NG`、`WARN`、`SKIP` を1行ずつ表示し、`NG` と `WARN` には対処を添えます。`NG` が1つでもあれば、終了ステータスは 1 です。

`-q` を付けると、`NG` と `WARN` の行だけを表示します。異常がなければ何も表示しません。

### RADIUS の確認に必要なもの

FreeRADIUS には、コンテナの中の `127.0.0.1` から要求を送ります。`clients.conf` に `127.0.0.1` のクライアントが必要です(`clients.conf.sample` の `localhost`)。共有シークレットは、このコマンドが `clients.conf` から読みます。

```
client localhost {
	ipaddr = 127.0.0.1
	secret = <共有シークレット>
	nas_type = service-type
}
```

ないときは `WARN` を表示し、RADIUS の確認を飛ばします。足したら `docker compose restart freeradius` で読み込ませてください。

## 定期実行する(推奨)

`docker` を実行できるこいとはん管理者の crontab(`crontab -e`)に行を足します。`/path/to/koitohan` はリポジトリのディレクトリに書き換えてください。

```
MAILTO=koitohan-admin@example.com
*/15 * * * * /path/to/koitohan/bin/check_services.sh -q
0 8 * * * /path/to/koitohan/bin/check_services.sh
```

- 1行目は、15 分ごとに確かめます。cron は、出力があったときだけ `MAILTO` にメールを送ります。`-q` を付けているので、メールが届くのは異常があるときだけです。異常が続くあいだは、15 分ごとに届きます。
- 2行目は、毎朝 8 時に、異常がなくても結果を送ります。これが「I'm OK」の知らせです。

`MAILTO` でメールを送るには、Docker ホストに、メールを送る仕組み(MTA)が要ります。メールを使わないときは、出力を送り先に渡す小さなスクリプトを用意して、crontab からはそれを呼んでください。

```sh
#!/bin/sh
# 異常があるときだけ送る。毎朝の分は、-q を外して必ず送る
OUT=$(/path/to/koitohan/bin/check_services.sh -q 2>&1)
[ -n "${OUT}" ] && printf '%s\n' "${OUT}" | <送るコマンド>
```

### 「I'm OK」が届かなかったら

Docker ホストごと止まったとき(電源、ストレージ、ネットワークの障害)は、このコマンドも動かず、何も届きません。そのとき手がかりになるのは、毎朝の結果が届かなくなったことだけです。届かない日があったら、Koitohan を確かめてください。

## 知っておくこと

- tftpd-hpa の確認は、実行のたびに `tftpd-hpa/log/tftpd.log` に1行残します(`RRQ from 127.0.0.1 filename firmware/koitohan-service-check`)。そのファイルがないことを確かめる要求です。`firmware/` に同じ名前のファイルを置かないでください。
- FreeRADIUS の確認は、Status-Server に応答することだけを見ます。FreeRADIUS が OpenLDAP に問い合わせる部分(FreeRADIUS のクライアント証明書とサービスアカウント)は確かめません。確かめるには、機器からログインしてみてください。
- 前回の結果は覚えていません。状態が変わったときだけ知らせる、ということはしません。
- しきい値(空きの 90%、証明書の 30 日)は、スクリプトの先頭の定数です。
- `make host_check` は Docker ホストの設定を確かめるもので、こちらは稼働中のサービスを確かめるものです。`check_services.sh` で `NG` が出たら、`make host_check` も実行してみてください。
