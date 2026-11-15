# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 概要

ネットワーク機器向けの AAA、ログ収集、ファイル配布を提供する Docker Compose スタック(Raspberry Pi 上で稼働)。OpenLDAP がユーザーディレクトリ、FreeRADIUS がそれを参照して認証し、syslog-ng が機器のログを収集し、tftpd-hpa がファームウェアの配布とコンフィグのバックアップの受け取りを行い、OpenSSH がユーザに作業用のシェル(利用者作業用コンテナ)を提供する。chrony が Docker ホストの時計を NTP で機器に配る(任意。profile `ntp`)。アプリケーションコードはなく、リポジトリの中身は `compose.yaml`、`Makefile`、`scripts/` の生成スクリプト、`bin/` の運用スクリプト、バインドマウントされる各サービスの設定、OpenLDAP、FreeRADIUS、tftpd-hpa、OpenSSH、chrony のイメージの Dockerfile と起動スクリプトのみ。

設計の背景、保留している機能(利用者作業用コンテナの公開鍵認証。要望が上がり、必要性を確かめてから実装する)、未決定事項(DHCP / DNS)は `docs/basic-design.md` を参照。基本設計書は日本語だけで、`docs/basic-design.md` が概要と目次(1、2、9〜11、13、14 章の本文もここ)、3〜8 章と 12 章の本文は `docs/design/<章の番号>-<名前>.md` にある(7.6 節と 7.8 節は `07-openssh-pending.md`、7.7 節は `07-openssh-verification.md`)。「設計書の N 節」は、その章のファイルを読む。章と節の番号は変えないこと(文書とコードのあちこちから番号で参照している)。節を足したら、`docs/basic-design.md` の目次にも足す。`README.md`(英語)と `README.ja.md`(日本語)は同じ内容なので、片方を直したらもう片方も直すこと。`docs/` の運用ガイド(`configuration`、`tftp`、`ssh`、`logs`、`backup`、`monitoring`)とユーザーズガイド(`user-guide`)も同じく、`<名前>.md`(英語)と `<名前>.ja.md`(日本語)の対にしている。`CONTRIBUTING.md` と `CONTRIBUTING.ja.md` も対。例外は `docs/devices/`(機器の設定例。コントリビュータが提供し、保守者は実機で確かめていない)で、英語だけにする(日本語で届いたものは英語に直す)。ただし、ひな形だけは `TEMPLATE.md` と `TEMPLATE.ja.md` の対にしている(日本語で送る人のため。一覧の `README.md` は、設定例を足すたびに表を2つ直すことになるので対にしない)。確かめてほしい項目は `CONTRIBUTING` の2つとひな形の2つの表に書いてあるので、変えるときは4つを揃える。ロールの確認は、`admin` が設定を変えられること、`readonly` が変えられないことだけを言い切り、`operator` は「`readonly` 以上、`admin` 未満」にとどめている(Koitohan はロールが機器の上で何をできるかを定めていない。報告を見てから決める、というユーザーの決定)。README はクイックスタートまでで、設定と運用の手順は運用ガイド(読み手はこいとはん管理者)に、ユーザーから見た使い方はユーザーズガイドに書く。ユーザーズガイドは、こいとはん管理者がホスト名とポート番号を書き換えて配るひな形なので、`.env` の変数名や設定値に頼らずに書く(既定の値を示すときは、変えられている場合があると添える)。

## ディレクトリごとの CLAUDE.md

サービスやスクリプトごとの詳しい説明と注意は、そのディレクトリの `CLAUDE.md` に分けてある。ディレクトリの中のファイルを読むと自動で読み込まれるが、**次の場合は読み込まれないので、作業や回答の前に自分で読むこと。**

- `compose.yaml`、`.env.sample`、`Makefile`、`scripts/` の生成スクリプト、`docs/` のうち、あるサービスに関わる部分を変えるとき。そのサービスのディレクトリのものを読む(`compose.yaml` の `init`、`read_only`、`cap_add`、`ulimits`、`mem_limit`、`container_name`、ポート、マウントなどの理由は、そちらに書いてある)。
- ファイルを開かずに、設計や影響の範囲を答えるとき。
- 動作を変えたとき。対応する確認が `tests/smoke.sh` にあるので、`tests/CLAUDE.md` を読む。

| ファイル | 内容 | ディレクトリの外で関わるもの |
|---|---|---|
| `openldap/CLAUDE.md` | 初期投入、イメージ、パスワードポリシー、パスワードのハッシュ | `scripts/generate_ldap_base.sh`、`.env` の `LDAP_*` と `PPOLICY_*` |
| `freeradius/CLAUDE.md` | イメージ、設定ファイルの区分、認証の流れ、ロールの扱い、ベンダーの追加 | `scripts/generate_freeradius_ldap.sh`、OpenSSH の `update-users.sh`(ロールの順序) |
| `openssh/CLAUDE.md` | 利用者作業用コンテナ、SSH の接続元(`OPENSSH_ALLOWED_NETWORKS`)、外への通信(`OPENSSH_EGRESS`) | `compose.yaml` の公開ポート(syslog-ng と tftpd-hpa)、ロールの順序 |
| `syslog-ng/CLAUDE.md` | ログのパスと時刻 | `scripts/generate_device_networks.sh` |
| `tftpd-hpa/CLAUDE.md` | イメージ、転送の記録、書き込みの制限 | `compose.yaml` の `ulimits`、`docs/tftp.md` |
| `chrony/CLAUDE.md` | 時刻の配布(任意のサービス) | `compose.yaml` の `container_name`、`bin/check_host.sh` |
| `bin/CLAUDE.md` | ユーザーの管理、バックアップと復元、稼働の確認 | `docs/backup.md`、`docs/monitoring.md` |
| `tests/CLAUDE.md` | スモークテストの構成、確認の順序、確認を足すときの決まり | すべてのサービス |

複数のディレクトリにまたがる注意(「A を変えたら B も揃える」の形で、A がそのディレクトリの外にあるもの)は、このファイルに書く。新しい注意を足すときも、この基準で置き場所を決める。

## コマンド

```sh
cp .env.sample .env          # すべてのスクリプトと compose.yaml が .env を読む
make                         # = private_dirs + certs + secrets + ldap_dir + freeradius_conf + device_networks + ssh_hostkeys + logrotate_conf(private_dirs は CA/、secrets/、openssh/hostkeys/ を 0700 にする)
make certs                   # CA、OpenLDAP サーバー証明書、FreeRADIUS と OpenSSH のクライアント証明書 -> CA/
make ldap_dir                # OU / ロール / サービスアカウント / パスワードポリシー / ACL の LDIF -> openldap/ldif/
make freeradius_conf         # ldap_openldap を .env から生成、clients.conf がなければ .sample からコピー
make device_networks         # 機器のネットワーク(DEVICE_NETWORKS)を syslog-ng の書式で生成 -> syslog-ng/config/device_networks.conf
make secrets                 # サービスアカウントと OpenLDAP の管理者のパスワード -> secrets/(すでにあれば作り直さない。clean でも消さない)
make ssh_hostkeys            # sshd のホスト鍵 -> openssh/hostkeys/(すでにあれば作り直さない。clean でも消さない)
make logrotate_conf          # Docker ホストの logrotate の設定 -> logrotate/koitohan(/etc/logrotate.d/ への配置は sudo の手作業)
make host_check              # Docker ホストの状態のうち make が作らないもの(sudo の手作業、configs/ のマウント、logrotate の配置、cgroup、時刻の同期)を確かめる(bin/check_host.sh。sudo を使わず、何も変えない)
make test                    # スモークテスト(別プロジェクト koitohan-test で起動。稼働中のスタックには触れない)
make up / make down          # docker compose up -d / down(up は private_dirs、secrets、freeradius_conf、device_networks、ssh_hostkeys に依存)
make clean                   # 生成した証明書・鍵、LDIF、ldap_openldap、logrotate の設定を削除
docker compose run --rm --no-deps freeradius radiusd -XC   # FreeRADIUS 設定の構文チェック(スタックは起動しない)
docker compose build openldap freeradius tftpd-hpa openssh chrony   # openldap/build/、freeradius/build/、tftpd-hpa/build/、openssh/build/、chrony/build/ を変更したらビルドし直す(初回は up が自動でビルドする。chrony は名前を指定すれば profile なしでビルドできる)
docker compose exec openssh koitohan-update-users   # LDAP のユーザーとロールの変更を、SSH のログインに反映する
bin/manage_users.sh add|delete|role|passwd|unlock <ユーザー> ...   # ユーザーの管理(稼働中のスタックの LDAP を書き換える)
bin/change_service_account_password.sh freeradius|openssh   # サービスアカウントのパスワードの変更(稼働中のスタックの LDAP と secrets/ を書き換え、コンテナを作り直す)
bin/change_ldap_admin_password.sh   # OpenLDAP の管理者のパスワードの変更(稼働中のスタックの secrets/ を書き換え、OpenLDAP のコンテナを作り直す。そのあいだ全員の認証が止まる)
bin/backup.sh [-k 個数] <ディレクトリ>   # 稼働中のスタックのバックアップ(1つの tar.gz、0600。-k で古いものを消す)
bin/restore_ldap.sh <アーカイブ>   # バックアップのディレクトリを、空の OpenLDAP の永続データに読み込む(起動はしない。あとで make up)
bin/check_services.sh [-q]   # 稼働中のスタックの各サービスを、コンテナの中から実際に使って確かめる(sudo を使わず、何も変えない。-q は NG と WARN だけ)
```

生成スクリプトにはホスト側に `openssl`、`slappasswd`(`userPassword` のハッシュ化に使用)、`ssh-keygen` が必要。`make test` は OpenSSH 8.4 以降の `ssh` と、TFTP に対応した `curl` も使う。

プルリクエストの前: コミットメッセージやプルリクエストの本文を用意する前に `make test` を実行し、すべての項目が合格することを確かめる。ドキュメントだけの変更でも省かない。失敗が1つでもあれば、変更と関係がなさそうに見えても先へ進まず、出力を添えて報告する。

デバッグ: FreeRADIUS のデバッグモードは `compose.yaml` でコメントアウトされている `command: ["radiusd", "-X"]`。それ以外は `docker compose logs -f <service>` を使う。

## アーキテクチャ

**`.env` が唯一の設定元。** `LDAP_DOMAIN` は `domain2dn` ヘルパーで LDAP サフィックスに変換される(`example.com` -> `dc=example,dc=com`)。このヘルパーは各スクリプトに重複して定義されている。コンテナ名(`OPENLDAP_CONTAINER_NAME`、`FREERADIUS_CONTAINER_NAME`、`OPENSSH_CONTAINER_NAME`)は証明書の subject / SAN のホスト名を兼ねるため、コンテナ名を変えたら証明書の再生成が必要。`DOCKER_SUBNET` は `compose.yaml` のデフォルトネットワークのサブネットで、コンテナの IP は固定していない(コンテナ間は名前で解決する)。反映には `make down && make up` でネットワークを作り直す。ネットワークはもう1つあり(`openssh`。サブネットは `OPENSSH_SUBNET`)、OpenSSH と OpenLDAP だけがつながる。OpenSSH はデフォルトネットワークに入れないこと(ログインしたユーザーから FreeRADIUS、syslog-ng、tftpd-hpa に届くようになる)。公開するポートには `0.0.0.0` を付け、IPv4 に限っている。付けないと Docker が IPv6 でも待ち受けて中継し、コンテナからはブリッジのゲートウェイ(プライベートアドレス)が送信元に見えるので、FreeRADIUS の `networks` の制限を通ってしまう。新しいポートにも付けること。RADIUS アカウンティング(1813/udp)は提供しない(`docs/basic-design.md` の 5.7 節)。`TZ` は全コンテナに環境変数として渡す。新しいサービスを足すときは `environment` に `TZ` を入れ、イメージに tz database があることを確かめる(Alpine は `tzdata` パッケージが必要)。全コンテナに `security_opt: no-new-privileges:true` を付けている。どのイメージも root で起動して自分で降格するので影響を受けないが、setuid のバイナリやファイルケーパビリティで権限を得る構成(たとえば syslog-ng を `user:` で非 root から起動し、s6-overlay の `s6-overlay-suexec` に頼る場合)は動かなくなる。新しいサービスにも付け、起動と動作を確かめること。

**接続元の制限(`DEVICE_NETWORKS`)。** 機器が使う3つのサービスは、`.env` の `DEVICE_NETWORKS`(IPv4 のアドレスかプレフィックスを空白で区切る。既定はプライベートアドレスの全体)からの通信だけを受け付ける。任意の chrony も同じ変数で、本体の `allow` で絞る(`chrony/CLAUDE.md` を参照)。変数は1つで、掛け方はサービスごとに違う。syslog-ng は `syslog-ng.conf` が `/config/device_networks.conf` を `@include` してフィルタ `f_device_networks` をログの経路に置く。このファイルは `scripts/generate_device_networks.sh`(`make device_networks`)が書く(ignore。環境変数の `DEVICE_NETWORKS` が `.env` より優先される。スモークテストが使う)。FreeRADIUS と tftpd-hpa は本体で制限できないので、`entrypoint.sh` が nftables のルールを入れてから起動する。FreeRADIUS の v4 の `listen` にある `networks` は dynamic clients を定義してよい送信元の制限で、dynamic clients を使わない `ldap-pap` では無視される(以前はこれで制限したつもりで、効いていなかった)。`ldap-pap` に戻さないこと。FreeRADIUS のルールはループバックを常に通す(スモークテストがコンテナの中から送る)。ここからの説明は tftpd-hpa のものだが、FreeRADIUS も同じ(`radiusd` は root で起動してから降格する)。そのために `cap_add: NET_ADMIN` を与えており、ルールを入れたあと `setpriv --bounding-set -net_admin` で落としてから `in.tftpd` と `syslogd` を起動する。これを外さないこと。`in.tftpd` の待ち受けのプロセスは root のまま残る(uid 1000 に降りるのは要求ごとの子プロセス)ので、落とさないとルールを書き換えられる。`setpriv` は util-linux のもの(Alpine の `setpriv` パッケージ)で、busybox のものには `--bounding-set` がない。ルールを入れられないとき(変数が空、書式の誤り、`NET_ADMIN` がない)は起動しない。この失敗を握りつぶさないこと。生成したファイルは、単体のマウントが古いものを見続けないよう、その場で上書きしている(`mv` で置き換えないこと)。`.env` を変えたあとの反映は `make down && make up`(`make up` だけでは syslog-ng が作り直されない)。Docker ホスト自身から送ったものは、コンテナからはネットワークのゲートウェイが送信元に見えるので、範囲を絞るときは `DOCKER_SUBNET` を含めるかどうかを意識すること。OpenSSH の接続元(`OPENSSH_ALLOWED_NETWORKS`)と外への通信(`OPENSSH_EGRESS`)は `openssh/CLAUDE.md`。`clients.conf` から範囲を導かない理由と、Docker ホストのファイアウォールにしない理由は、`docs/basic-design.md` の 8 節の「接続元の制限」。

**TLS チェーン(`scripts/create_certs.sh`)。** プライベート CA(`CA/default-ca.pem`)、OpenLDAP サーバー証明書(`server_cert` 拡張。`scripts/openssl.conf.template` に SAN を追記して `scripts/openssl.conf` を生成)、FreeRADIUS と OpenSSH のクライアント証明書(`client_cert` 拡張)を作成する。`compose.yaml` はこれらのファイルを個別に各コンテナへマウントし、FreeRADIUS と OpenSSH は LDAPS で OpenLDAP に接続する(待ち受けは 636 と、コンテナ内の `ldapi:///` だけ。389 は待ち受けない)。OpenLDAP はクライアント証明書を要求し(`olcTLSVerifyClient: demand`)、TLS は 1.3 に限る(`olcTLSProtocolMin: 3.4`)。TLS 1.2 に戻さないこと(前方秘匿性のない静的 RSA の鍵交換も通るようになる)。DH パラメータのファイル(`olcTLSDHParamFile`)は置かない。使うのは TLS 1.2 の DHE だけで、TLS 1.3 では参照されない。`olcSecurity: ssf=128` も入れてあるので、`slapd` の `-h` に `ldap:///` を足しても、平文の操作は `Confidentiality required` になる。コンテナ内の作業は `ldapi:///` を使う。これらは初期投入のときに `openldap/build/entrypoint.sh` が `cn=config` に書くもので、スクリプトを直しても、すでにある設定には反映されない(`ldapi:///` から `ldapmodify` するか、永続データを消して作り直す)。例外は `olcTLSProtocolMin` で、起動のたびの `slapmodify -n 0` が書く(管理者のパスワードやログのレベルと同じく、`ldapi:///` から書き換えられても次の起動で戻す。スモークテストが確かめる)。OpenLDAP は降格後に証明書を読むので、`entrypoint.sh` が `/etc/koitohan/certs`(root しか入れない)から `/run/koitohan/certs`(tmpfs)へ写している。`CA/.certs.stamp` は make 用のスタンプファイル。スクリプトは無条件に CA を作り直すため、再実行すると発行済みの証明書はすべて無効になる。証明書はこのスタックのコンテナ間でしか使われないので、作り直して構わない(その後 `make down && make up` で読み込み直す)。`freeradius_client.key` だけは 0644 にしている。FreeRADIUS が root から uid 101 に降りたあとで読むためで、0600 に戻すと `rlm_ldap` の設定の読み込みで止まり、起動しない。Docker ホストのほかのユーザーから守っているのは `CA/` の 0700(`make private_dirs`。`all` と `up` が依存する)なので、ディレクトリを緩めないこと。ファイル単体のマウントは親ディレクトリの権限に左右されないので、コンテナからは読める。スクリプトは最後に CA の秘密鍵(`default-ca-key.pem`)と CSR を消す。毎回 CA から作り直すので、発行のあとに使う場面がない。

**サービスアカウントのパスワード(`secrets/`)。** `.env` には置かず、`make secrets`(`scripts/generate_service_account_password.sh`)が `secrets/freeradius_service_account_password` と `secrets/openssh_service_account_password` に生成する(48 桁の 16 進数、0600、末尾の改行なし)。こいとはん管理者が値を確かめる手段は、このファイルを読むことだけ。記号を混ぜないこと。値は `ldap_openldap` の引用符の中と `nslcd.conf` にそのまま入る。改行も付けないこと(`ldapsearch -y` と `ldappasswd -T` がパスワードの一部として扱う)。sshd のホスト鍵と同じく、あれば作り直さず、`make clean` でも消さない。初期投入は空のデータベースにしか入らないので、ファイルだけを作り直すとディレクトリと食い違い、全員の認証が止まる。渡る先は3つで、LDIF(`generate_ldap_base.sh` がハッシュ化)、`ldap_openldap`(`generate_freeradius_ldap.sh`)、OpenSSH のコンテナ(ファイル単体を `/etc/koitohan/secrets/bindpw` にマウント。環境変数では渡さない)。稼働中に変えるのは `bin/change_service_account_password.sh freeradius|openssh`(生成し、`ldappasswd` で平文を渡し、ファイルを差し替え、LDIF と `ldap_openldap` を生成し直して、コンテナを `--force-recreate` で作り直す。OpenSSH はファイル単体のマウントなので、`restart` では古いファイルを見たままになる)。いまのパスワードを使わないので、ファイルとディレクトリが食い違った状態(`.env` にパスワードを書いていた環境からの移行を含む)も同じコマンドで直せる。生成スクリプトとこのスクリプトの書き込み先は `KOITOHAN_GENERATED_ROOT` で変えられ(指定しなければリポジトリの直下)、スモークテストはこれで `tests/generated/` に自前のパスワード、LDIF、`ldap_openldap` を作る(本番の `secrets/` は読まない)。テスト用のスタックに向けて手で実行するときは、`COMPOSE_PROJECT_NAME`、`COMPOSE_FILE` に加えて `KOITOHAN_GENERATED_ROOT=tests/generated` を付けること。付け忘れは、対象のコンテナがそのファイルをマウントしているかの確認で止まる(この確認は外さないこと)。サービスアカウントを増やすときは、`freeradius` と `openssh` を決め打ちで並べている箇所を、`service_account` を大文字と小文字を区別せずにリポジトリの全体(スクリプト、`Makefile`、`compose.yaml`、`tests/`、`.env.sample`、文書)から検索して洗い出し、すべて広げる。検索ではわからないのは次の3つ。ppolicy の `cn=serviceaccounts` の割り当てを忘れると、既定のポリシーでロックされうる。`900-ACL` は `ou=ServiceAccounts` の下のすべてにツリーの読み取りを与えるので、新しいアカウントも置いただけで全体を読める。`change_service_account_password.sh` は、引数を compose のサービスの名前としても使う。稼働中のディレクトリへの足し方は `openldap/CLAUDE.md` の「LDAP の初期投入」の末尾(エントリ)と「パスワードポリシー」の末尾(割り当て)。設計は `docs/basic-design.md` の 4.10 節。

**OpenLDAP の管理者のパスワード(`secrets/`)。** データの管理者(`cn=admin,<サフィックス>`)と設定の管理者(`cn=admin,cn=config`)のパスワードも `.env` には置かず、`make secrets`(`scripts/generate_ldap_admin_password.sh`)が `secrets/ldap_admin_password` と `secrets/ldap_config_password` に生成する(形式はサービスアカウントと同じ)。`.env` にパスワードはもうない。OpenLDAP のコンテナにはファイル単体を `/etc/koitohan/secrets/` にマウントする。`entrypoint.sh` は起動のたびに、`slapd` を上げる前に `slappasswd -T` でハッシュ化し、`slapmodify -n 0` で2つの `olcRootPW` を置き換える(同じところでログのレベル `LDAP_LOG_LEVEL` と、TLS の下限も書く)。読んだ値をログに出さないこと(スモークテストが、ログに出ていないことを確かめる)。したがって正は常にファイルで、`ldapi:///` からディレクトリだけを書き換えても次の起動で戻る。ファイル単体のマウントなので、同じコンテナの再起動では古いファイルを見たままになる。ファイルを替えたら必ずコンテナを作り直す。稼働中に変えるのは `bin/change_ldap_admin_password.sh`(2つを生成し、ファイルを差し替え、OpenLDAP を `--force-recreate` で作り直し、新しいパスワードで bind できることを確かめる。いまのパスワードは使わない)。このスタックのスクリプトはどちらのパスワードも使わない(すべて `ldapi:///` の EXTERNAL)。`cn=admin,<サフィックス>` のエントリはデータベースになく、rootdn の `olcRootPW` だけがある。設計は `docs/basic-design.md` の 4.11 節。

**ログローテーション(`scripts/generate_logrotate.sh` -> `logrotate/koitohan`)。** Docker ホストの logrotate が、`syslog-ng/log/Hosts/*/*.log`、`syslog-ng/log/debug.log`、`freeradius/log/radius.log`、`freeradius/log/radacct/*/auth-detail` と `reply-detail`、`tftpd-hpa/log/tftpd.log` を日次で切り替える(`<元の名前>-YYYY-MM-DD`。`dateyesterday` で中身の日付にしている。前日分は圧縮しない)。保持は 1096 日、`debug.log` だけ 7 日で、スクリプトの先頭の定数。生成するのは、リポジトリの絶対パスと `SYSLOG_CONTAINER_NAME` が入るため。`/etc/logrotate.d/koitohan` への配置は `sudo install` の手作業で(手順は README のクイックスタートと `docs/logs.md`)、`make` には含めない。logrotate は root 所有でない設定を読まないので、シンボリックリンクにはしないこと。切り替えの方法はファイルごとに違う。syslog-ng は名前を変えたあと `postrotate` で `docker exec <コンテナ名> syslog-ng-ctl reopen --control=/config/syslog-ng.ctl`(新しいファイルは syslog-ng が作るので `nocreate`)。`radius.log` は FreeRADIUS が追記モードで開いたままなので `copytruncate`。detail ログは名前を変えるだけで、FreeRADIUS が次の書き込みで作り直す。このために `freeradius/config/mods-available/detail.log` でイメージの設定(日付入りのファイル名)を置き換え、クライアントごとに1ファイルにしている。ファイル名は、このファイル、生成スクリプトのパターン、`tests/smoke.sh` の3か所で揃えること。`su` は数値の uid / gid で書く(1000 は syslog-ng の `PUID`、101 はイメージの `freerad`。ホストに同じ名前のユーザーがあるとは限らない)。`compose.yaml` の `PUID` を変えたらスクリプトも直す。設定の検査は `sudo logrotate -d <ファイル>`(何も変更しない)。logrotate は初めて見たファイルを記録するだけなので、切り替えを実際に試すときは、ログの写しと別の状態ファイル(`-s`)を使い、`-f` を付ける。`tftpd.log` も名前を変えるだけで、tftpd-hpa のコンテナの `syslogd` が作り直す(1秒ごとに開き直すので、移した直後の1秒の行は古いファイルに入る。`delaycompress` があるので失われない)。root が書くので `su 0 0`。コンテナの標準出力のログ(OpenSSH、OpenLDAP)は対象外で、Docker のログドライバに任せている。`compose.yaml` に `logging:` を書かないのは意図したもの(オプションがドライバごとに違い、共通にするにはドライバを固定することになる。このホストは `journald` で、`max-size` を渡すとコンテナが起動しない)。設計は `docs/basic-design.md` の 6.2 節と 6.4 節。

## 注意点

- Docker ホストで動くスクリプト(`scripts/`、`bin/`、`tests/smoke.sh`)は bash で書く。条件は `[[ ]]`(文字列の比較は `==`)、外部コマンドで足りていたところも bash の機能を使う(`${VAR//./,dc=}`、`${VAR,,}`、`$(< file)`、`<<<`、`for (( ))`)。コンテナの中で動くもの(`*/build/` のスクリプトと、`smoke.sh` が `sh -c` や ssh で渡す文字列)は busybox の `sh` が実行するので、POSIX の書き方のまま残す。
- `scripts/` の生成スクリプトは `set -euo pipefail` で書く。失敗が握りつぶされると、Makefile が壊れた生成物を最新として扱う(`.DELETE_ON_ERROR` は、書きかけのターゲットを消すための網)。コマンド置換をヒアドキュメントの中に書かないこと(失敗しても `set -e` が効かない。`slappasswd` のハッシュは先に変数へ取って確かめている)。新しい変数を読むときは、`set -u` で止まらないよう、なくてよいものに `${VAR:-}` を使う。`bin/check_host.sh` は、`make` が作らないホストの状態を確かめるだけのもので、`sudo` を使わず、何も変更しない(直し方は出力に添えるだけ)。`make` が直せるものは対象にしない。手作業の手順を増やしたり変えたりしたら、このスクリプトも揃えること。`make up` の依存にはしていない。`bin/` は `set -u` だけで、失敗は1つずつ `die` で扱う(`docker inspect | grep -q` のようなパイプがあり、`pipefail` を付けると、`grep -q` が先に終わったときの SIGPIPE で偽って失敗する)。`bin/` で検索の結果をパイプに流すときは、先に変数へ取って終了ステータスを確かめる(パイプの終了ステータスは最後のコマンドのもの)。
- コードのコメントは英語で書く(Dockerfile、スクリプト、設定ファイルのすべて)。周りのコメントが日本語でも合わせないこと。ドキュメント(`README.ja.md`、`docs/` の日本語のファイル、このファイル)は対象外。
- LDIF のターゲットは1つのスクリプトが複数ファイルを書き出すため、グループターゲット(`&:`)を使っている。GNU Make 4.3 以上が必要。
- 生成物と実行時データは gitignore 済み(`CA/*`、`openldap/data`、`openldap/config`、`openldap/ldif/*.ldif`、`*/log`、`openssh/hostkeys/*`、`secrets/*`、`logrotate/*`、`tests/generated/`、`scripts/openssl.conf`、`syslog-ng/config` の `syslog-ng.conf` 以外、`tftpd-hpa/log/*`、`tftpd-hpa/configs.img`、`tftpd-hpa/tftpboot/` の `firmware/.gitkeep` 以外)。ディレクトリは `.gitkeep` で維持している。`.gitignore` では `!.gitkeep` を末尾に置くこと(後に書いたパターンが優先されるため)。
- `CA/`、`.env`、`secrets/`、`openssh/hostkeys/`、`freeradius/config/clients.conf`、`freeradius/config/mods-available/ldap_openldap`、生成された LDIF には秘密鍵、共有シークレット、パスワードが含まれる。LDIF は `umask 077` で生成する(0600)。既存のファイルに上書きするときは元の権限が残るので、古い 0664 のファイルは `chmod 600` で直す。
- ファイル単体のバインドマウントは、ホスト側にファイルがないと Docker が同名の root 所有ディレクトリを作る。`docker compose up` を直接叩く前に `make freeradius_conf` を済ませること。`make up` は、`CA/openssh_client.crt` がないと止まり、`syslog-ng/log/Hosts/` がなければ作る(Docker に root 所有で作らせると、syslog-ng が書けなくなる)。
- `openldap/data/` と `openldap/config/` はコンテナが uid 100、gid 101(イメージの `ldap`)に chown する(起動のたび。`openldap/config/.gitkeep` も含まれるが、git は所有者を記録しない)。永続データを消すのは `sudo` の作業で(`make down` のあと `sudo find openldap/data openldap/config -mindepth 1 ! -name .gitkeep -delete`)、ディレクトリの中身が失われるので、必ず事前に確認すること。
- `freeradius/log/` は uid 101(イメージの `freerad`)の所有にしておく(`sudo chown -R 101:101 freeradius/log`)。`radius.log` は root のうちに開かれるので所有者が違っても書けるが、`radacct/` 以下の詳細ログは降格後に作るため、書けないとログインがすべて Reject になる。スモークテストは匿名ボリュームを使うので、この不備を検出できない。
- `tftpd-hpa/tftpboot/firmware/` と `configs/` は、所有者 uid 1000(`in.tftpd`)、グループ GID 10001(ロール `admin`)、パーミッション 2770 にする(`sudo` の作業。手順は README のクイックスタートと `docs/tftp.md`)。ロール `admin` のユーザーが置いたファイルは、「その他」に読み取り権限がないと `in.tftpd` が読めない。
- `syslog-ng/log/Hosts/` 以下のディレクトリは 0755 で作らせている(`syslog-ng.conf` の `dir-perm`)。SSH でログインしたユーザーが読むためで、0700 に戻すとログが見えなくなる。
- `tftpd-hpa/tftpboot/configs/` は意図して追跡していない(`.gitkeep` も置かない)。ループバックイメージのマウントポイントであり、下のディレクトリを root 所有にしておくことで、マウントが外れたときに書き込みがホストのディスクへ落ちるのを防いでいる。存在しない場合は Docker が root 所有で作るので、アップロードが失敗する側に倒れる。
- TFTP をホスト自身から試すときは、公開アドレス(`<ホストの IP>:69`)ではなくコンテナのアドレスに向ける。ホストから自分の公開アドレス宛てだと、ダウンロードがタイムアウトする(原因は未特定。`network_mode: host` では起きない)。外部のクライアントからは問題なく通る。
- `freeradius/log/radacct/<client-ip>/`、`syslog-ng/log/Hosts/<ip>/`、`tftpd-hpa/tftpboot/configs/` は実機から届いた稼働中のデータであり、テスト用のフィクスチャではない。
- `test` は `all` に依存させていない。`.env` がスタンプより新しいと、テストのついでに CA を作り直してしまうため。
- FreeRADIUS や tftpd-hpa のログのマウント先を変えたときは、`tests/compose.test.yaml` の匿名ボリュームのパスも合わせること。合わせないと、テストが `freeradius/log/` や `tftpd-hpa/log/` に書き込む。
- syslog-ng と tftpd-hpa の公開ポート(`compose.yaml` のホスト側の番号)を変えたら、OpenSSH の `entrypoint.sh` が断る番号も揃える(`openssh/CLAUDE.md`)。
