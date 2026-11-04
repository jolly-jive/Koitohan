# <img src="docs/images/koitohan.svg" alt="Koitohan のアイコン" width="48" align="absmiddle"> Koitohan

A little and kawaii network backend server.

[English](README.md)

Koitohan は、ネットワーク機器にログイン認証の基盤、ログ収集、ファイル配布を提供する Docker Compose スタックです。Raspberry Pi 5 と、小規模なネットワークや検証環境を想定しています。

- **OpenLDAP** がユーザーとロールを保持します。
- **FreeRADIUS** が機器へのログインを LDAP で認証し、ベンダーごとに決まった権限属性を返します。
- **syslog-ng** が機器の syslog を収集し、ホストごとのディレクトリに保存します。
- **tftpd-hpa** がファームウェアを機器へ配布し、機器のコンフィグのバックアップを受け取ります。
- **OpenSSH** がユーザーに作業用のシェルを提供します。ログの閲覧と取得、TFTP のファイルの出し入れ、パスワードの変更に使います。
- **chrony** が Docker ホストの時計を NTP で機器に配ります。使うかどうかは選べます。

ユーザーとロール(`admin`、`operator`、`readonly`)は1か所で管理します。Koitohan がロールを各機器の流儀に読み替えます。たとえば Cisco には `shell:priv-lvl=15`、ArubaOS-CX には `Aruba-Priv-Admin-User = 15` を返します。

## 名前について

「こいとはん」は大阪の土地言葉です。大阪の商家では、その家の娘を「いとはん」と呼びます。「いとしい人」あるいは「いとけない人」が元になったとされる言葉で、親にとっての大切な娘を指します。娘が二人以上いるとき、いちばん下の娘が「こ(小)いとはん」です。

大規模なネットワーク向けの高機能な管理サーバーは、ほかにあります。Koitohan が目指すのは、そうした fat なサーバーではありません。Raspberry Pi で動くほど小さく、最低限よりも少しましな管理機能を備え、それでいて可用性まで考慮したサーバーです。小さくて愛しいサーバーなので、「こいとはん」と名付けました。

可用性のための冗長化は、まだ実装していません。

## 状況

Koitohan は検証段階です。本番利用に耐える堅牢化はしていません。

| 機能               | コンポーネント                                 | 状況     |
| ------------------ | ---------------------------------------------- | -------- |
| ディレクトリ       | OpenLDAP 2.6(Alpine から自前でビルド)          | 動作中   |
| 認証・認可         | FreeRADIUS 4.x(`cayenneryo/freeradius-server`) | 動作中   |
| ログ収集           | syslog-ng(`linuxserver/syslog-ng`)             | 動作中   |
| ファイル配布       | tftpd-hpa(Alpine から自前でビルド)             | 動作中   |
| ユーザーの作業環境 | OpenSSH(Alpine から自前でビルド)               | 動作中   |
| 時刻の配布(NTP、任意) | chrony(Alpine から自前でビルド)             | 動作中   |
| ログローテーション | Docker ホスト側の logrotate                    | 動作中   |
| DHCP と DNS        | Kea、BIND9                                     | 未決定   |

FreeRADIUS 4.x は開発バージョンです。Koitohan は正式リリースに先行して採用しています。イメージは [freeradius-server-image](https://github.com/jolly-jive/freeradius-server-image) で開発ブランチからビルドしたものです。Koitohan はその特定のビルド(`freeradius/build/Dockerfile` で固定)をもとに自前のイメージをビルドし、要求の送信元を制限するパケットフィルタを加えています。

## 必要なもの

- Docker と Compose プラグイン
- GNU Make 4.3 以上
- `openssl`
- `slappasswd`(Debian と Raspberry Pi OS では `slapd` パッケージに含まれます)
- `ssh-keygen`。`make test` は OpenSSH 8.4 以降の `ssh` と、TFTP に対応した `curl` も使います。
- `logrotate`(ログのローテーションに使います)
- NTP による Docker ホストの時刻の同期(Raspberry Pi OS では `systemd-timesyncd` が既定で行います)。コンテナはホストの時計を使い、ログの時刻もこれに従います。

## クイックスタート

```sh
git clone https://github.com/jolly-jive/Koitohan.git koitohan
cd koitohan

cp .env.sample .env    # その後 .env を編集
make                   # 証明書、パスワード、LDIF、FreeRADIUS の LDAP 設定、sshd のホスト鍵、logrotate の設定を生成
$EDITOR freeradius/config/clients.conf
sudo chown -R 101:101 freeradius/log
sudo chown 1000:10001 tftpd-hpa/tftpboot/firmware
sudo chmod 2770 tftpd-hpa/tftpboot/firmware
sudo install -m 644 -o root -g root logrotate/koitohan /etc/logrotate.d/koitohan
make host_check        # ここまでの手作業を確かめる
make up
```

`.env` にパスワードはありません。OpenLDAP の管理者のパスワードと、FreeRADIUS と OpenSSH のサービスアカウントのパスワードは、`make` が生成して `secrets/` に置きます(「[OpenLDAP の管理者のパスワード](docs/configuration.ja.md#openldap-の管理者のパスワード)」と「[サービスアカウントのパスワード](docs/configuration.ja.md#サービスアカウントのパスワード)」を参照)。

`make` は `clients.conf.sample` から `freeradius/config/clients.conf` を作ります。`make up` の前に、サンプルのクライアントを自分の機器に書き換えてください。

FreeRADIUS は uid 101 で動作し、`freeradius/log/` にログを書き込みます。`chown` をしないと、ログインを記録できず、すべての要求を拒否します。

`install` は、ログのローテーションの設定を Docker ホストの logrotate に渡します(「[ローテーション](docs/logs.ja.md#ローテーション)」を参照)。

`firmware/` の `chown` と `chmod` は、SSH でログインしたユーザーのうち、ロール `admin` のユーザーにだけこのディレクトリを開きます(「[ユーザーズガイド](docs/user-guide.ja.md#ファームウェアを配るコンフィグを取り出すadmin-のみ)」を参照)。`configs/` の同じ設定は、「[TFTP](docs/tftp.ja.md)」の手順に含まれています。

`make host_check` は、Docker ホストの状態のうち `make` が作らないものを確かめます。上の `sudo` の手作業、「[TFTP](docs/tftp.ja.md)」のイメージファイル、「[SSH](docs/ssh.ja.md)」が必要とするメモリのコントローラ、時刻の同期が対象です。`sudo` を使わずに実行でき、何も変更しません。項目ごとに `OK`、`NG`、`WARN`、`SKIP` を表示し、`NG` と `WARN` には対処を添えます。`NG` が1つでもあれば失敗します。`WARN` は、推奨の手順が抜けていることを表します。ホストの設定を変えたときや、logrotate の設定を生成し直したときにも実行してください。

クローン直後は、`docker compose up` を直接実行せずに `make up` を使ってください。Docker がマウントする前に、生成ファイルが揃っていることを保証します。

起動したら、`bin/check_services.sh` で各サービスが動いていることを確かめます。Koitohan のサービスは止まっても気づかれにくいので、これを cron から定期的に実行することを強く推奨します(「[稼働の確認](docs/monitoring.ja.md)」を参照)。

## ポート

| ポート           | サービス    |
| ---------------- | ----------- |
| 2222/tcp         | SSH(番号は `OPENSSH_PORT` で指定) |
| 1812/udp         | RADIUS 認証 |
| 514/udp、514/tcp | syslog      |
| 69/udp           | TFTP        |
| 636/tcp          | LDAPS       |
| 123/udp          | NTP(`COMPOSE_PROFILES='ntp'` のときだけ) |

どのポートも IPv4 でのみ公開しています。IPv6 には対応していません。

RADIUS アカウンティング(1813/udp)は提供していません。ログインの記録は FreeRADIUS の detail ログに、ログアウトと操作の記録は機器の syslog に残ります。

## コマンド

```sh
make                    # private_dirs + certs + secrets + ldap_dir + freeradius_conf + device_networks + ssh_hostkeys + logrotate_conf
make private_dirs       # 鍵とパスワードのディレクトリを、所有者しか入れないようにする
make certs              # プライベート CA、サーバー証明書、クライアント証明書
make secrets            # サービスアカウントと OpenLDAP の管理者のパスワード(すでにあれば作り直さない)
make ldap_dir           # OU、ロール、サービスアカウント、パスワードポリシー、ACL の LDIF
make freeradius_conf    # FreeRADIUS の LDAP モジュール設定と clients.conf
make device_networks    # syslog-ng に渡す、機器のネットワークの設定
make ssh_hostkeys       # sshd のホスト鍵(すでにあれば作り直さない)
make logrotate_conf     # Docker ホストの logrotate に渡す設定
make host_check         # Docker ホストの状態のうち、make が作らないものを確かめる
make test               # スモークテスト
make up                 # スタックを起動
make down               # スタックを停止
make clean              # 生成した証明書、LDIF、設定を削除
bin/manage_users.sh     # ユーザーの登録、削除、ロールの変更、パスワードの再発行、ロックの解除
bin/change_service_account_password.sh   # サービスアカウントのパスワードの変更
bin/change_ldap_admin_password.sh        # OpenLDAP の管理者のパスワードの変更
bin/backup.sh           # 稼働中のスタックのバックアップ
bin/restore_ldap.sh     # バックアップのディレクトリを、空の OpenLDAP に読み込む
bin/check_services.sh   # 稼働中のスタックの各サービスが動いているかを確かめる
```

スタックを起動せずに FreeRADIUS の設定を検査する:

```sh
docker compose run --rm --no-deps freeradius radiusd -XC
```

認証と認可を通しで確かめる:

```sh
make test
```

`make test` は、すべてのコンテナを別のプロジェクト(`koitohan-test`)として起動し、`bin/manage_users.sh` でテストユーザーを登録して認証し、機器種別とロールの組み合わせごとに応答属性を照合します。FreeRADIUS が、ローテーションで移動された detail ログを作り直すことも確かめます。RADIUS、syslog、TFTP、NTP については、`DEVICE_NETWORKS` の範囲からは届き、範囲の外からは届かないことを確かめます。TFTP の転送がファイルに記録されることと、ホストの時刻の同期が外れると NTP サーバーが「同期していない」と答えることも確かめます。続いて、各ロールのユーザーで SSH でログインし、ディレクトリの権限、圧縮されたログの読み取り、パスワードの変更を確かめます。そのあと、`bin/manage_users.sh` の各操作と、パスワードポリシー(最小の長さ、ロックとその解除)、サービスアカウントと OpenLDAP の管理者のパスワードの変更を確かめます。続いて OpenLDAP のコンテナを再起動し、起動し直せることを確かめます。`bin/check_services.sh` が、健全なときに異常を出さず、`configs/` の所有者の誤り、止まった syslog-ng、配るのをやめた NTP を異常として出すことも確かめます。最後に `bin/backup.sh` でバックアップを取り、OpenLDAP を空のデータで作り直して `bin/restore_ldap.sh` で復元し、ユーザーと `configs/` のファイルが戻ることを確かめます。ポートを公開せず、データも残さず、パスワードもテスト用に生成する(`tests/generated/`)ので、稼働中のスタックには影響しません。事前に `make` を済ませておいてください。失敗した項目は `KEEP=1 tests/smoke.sh` でテスト用のスタックを残して調べられます。

OpenLDAP、FreeRADIUS、tftpd-hpa、OpenSSH、chrony のイメージは、最初の `make up` で自動的にビルドされます。`openldap/build/`、`freeradius/build/`、`tftpd-hpa/build/`、`openssh/build/`、`chrony/build/` を変更したときは、ビルドし直してから起動します。

```sh
docker compose build openldap freeradius tftpd-hpa openssh chrony
make up
```

`make clean` は、sshd のホスト鍵(`openssh/hostkeys/`)を消しません。ホスト鍵が変わると、すべてのユーザーの手元で警告が出るためです。`secrets/` のパスワードも消しません(「[サービスアカウントのパスワード](docs/configuration.ja.md#サービスアカウントのパスワード)」と「[OpenLDAP の管理者のパスワード](docs/configuration.ja.md#openldap-の管理者のパスワード)」を参照)。

サービスのログを追う:

```sh
docker compose logs -f freeradius
```

## 既知の制限

- `bin/manage_users.sh` を使わずに行ったユーザーとロールの変更は、`koitohan-update-users` を実行するまで、SSH のログインに反映されません。
- `passwd` によるパスワードの判定は、ログインしたユーザーが迂回できます。この判定は、不注意で弱いパスワードを設定することを防ぐためのものです。迂回しても、OpenLDAP 自身が確かめる最小の長さ(`PPOLICY_MIN_LENGTH`)は守られます。
- ネットワーク機器のログイン画面や SSH のポートに到達できる相手は、誤ったパスワードを送り続けることで、名前を知っているユーザーをロックできます。ロックは時間が過ぎると解除されます(「[パスワードポリシー](docs/configuration.ja.md#パスワードポリシー)」を参照)。
- 既定では、SSH でログインしたユーザーが OpenSSH のコンテナから届くのは OpenLDAP だけです。ただし名前解決は Docker の DNS を通り、外部の名前も引けます。`OPENSSH_EGRESS='any'` にすると、Docker ホストや外部のネットワークへ接続できます(「[コンテナから外への接続](docs/ssh.ja.md#コンテナから外への接続)」を参照)。
- FreeRADIUS を動かしたまま OpenLDAP が再起動すると(`docker compose restart openldap` など)、FreeRADIUS はその後のログインを拒否し、やがてセグメンテーション違反で異常終了します。Docker が起動し直すので、それ以降のログインは通ります。開発バージョンである FreeRADIUS 4.x の不具合です([FreeRADIUS #5983](https://github.com/FreeRADIUS/freeradius-server/issues/5983))。ログインが拒否される時間をなくすには、OpenLDAP の再起動に続けて `docker compose restart freeradius` で FreeRADIUS も再起動してください。FreeRADIUS 側で修正されたら、この項目は削除します。

## セキュリティ上の注意

次のファイルには、秘密鍵、共有シークレット、パスワードが含まれます。いずれも git の管理対象外です。他人が読めるバックアップやコピーに含めないでください。`bin/backup.sh` が書き出すアーカイブには、その多くが暗号化されずに入っています(「[バックアップと復元](docs/backup.ja.md#アーカイブの扱い)」を参照)。

- `CA/`
- `freeradius/config/clients.conf`
- `freeradius/config/mods-available/ldap_openldap`
- `openldap/ldif/*.ldif`
- `openssh/hostkeys/`
- `secrets/`
- `tftpd-hpa/tftpboot/configs/`(機器のコンフィグ。パスワードのハッシュや共有シークレットを含むことがあります)

`CA/`、`secrets/`、`openssh/hostkeys/` は、`make` と `make up` が、所有者しか入れないディレクトリ(0700)にします。`CA/freeradius_client.key` のパーミッションは 0644 です(FreeRADIUS が、コンテナの中で uid 101 として読むためです)。Docker ホストのほかのユーザーから守っているのは、このディレクトリのパーミッションなので、緩めないでください。

CA の秘密鍵は、証明書を発行したあとに消されます。`make certs` は毎回 CA から作り直すので、残しておく必要がありません。

`syslog-ng/log/Hosts/` 以下の機器のログは、Docker ホストのすべてのユーザーが読めます。SSH でログインしたユーザーに読ませるためです。

RADIUS のログインは PAP を使うため、通信経路上でユーザーのパスワードを守るのは、各クライアントの共有シークレットです。機器ごとに長いランダムなシークレットを使ってください。

TFTP には認証も暗号化もありません。69/udp に到達できる相手は、ファイル名がわかれば `firmware/` と `configs/` のファイルを取得でき、`configs/` のファイルを上書きできます。バックアップしたコンフィグも取得の対象です。69/udp は、信頼できる管理用のネットワークにだけ公開してください。

## ドキュメント

ユーザー(機器にログインする人)向け:

- [ユーザーズガイド](docs/user-guide.ja.md): できること、ロール、ログの読み方、ファームウェアとコンフィグ、パスワード

こいとはん管理者向け:

- [設定](docs/configuration.ja.md): `.env`、機器のネットワーク、時刻の配布、RADIUS クライアント、ユーザーとロール、パスワード
- [TFTP](docs/tftp.ja.md): ファームウェアの配布とコンフィグのバックアップ、アップロードの上限
- [OpenSSH のコンテナ](docs/ssh.ja.md): 利用者作業用コンテナの目的、パスワードの規則、接続元
- [ログ](docs/logs.ja.md): ログの置き場所とローテーション
- [バックアップと復元](docs/backup.ja.md): バックアップに入るもの、毎日の実行、新しいホストへの復元
- [稼働の確認](docs/monitoring.ja.md): サービスが動いているかの確認と、その定期実行(推奨)
- [機器の設定例](docs/devices/README.md)(英語): ネットワーク機器側の設定。コントリビュータの提供
- [基本設計書](docs/basic-design.md)

## コントリビューション

ネットワーク機器の設定例を特に歓迎します。[CONTRIBUTING.ja.md](CONTRIBUTING.ja.md) を参照してください。

## ライセンス

Copyright 2026 Cayenne Ryo

[Apache License 2.0](LICENSE) で公開しています。[NOTICE](NOTICE) も参照してください。

## アイスクリーム

Koitohan が役に立ったら、アイスクリームを奢ってください。🍦

*これはお願いであって、ライセンスの条件ではありません。Koitohan は Apache-2.0 で、追加の条件はありません。*
