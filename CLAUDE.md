# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 概要

ネットワーク機器向けの AAA、ログ収集、ファイル配布を提供する Docker Compose スタック(Raspberry Pi 上で稼働)。OpenLDAP がユーザーディレクトリ、FreeRADIUS がそれを参照して認証し、syslog-ng が機器のログを収集し、tftpd-hpa がファームウェアの配布とコンフィグのバックアップの受け取りを行う。アプリケーションコードはなく、リポジトリの中身は `compose.yaml`、`Makefile`、`scripts/` の生成スクリプト、バインドマウントされる各サービスの設定、tftpd-hpa のイメージの Dockerfile のみ。

設計の背景、実装予定(ログローテーション)、未決定事項(DHCP / DNS)は `docs/basic-design.md` を参照。`README.md`(英語)と `README.ja.md`(日本語)は同じ内容なので、片方を直したらもう片方も直すこと。

## コマンド

```sh
cp .env.sample .env          # すべてのスクリプトと compose.yaml が .env を読む
make                         # = certs + ldap_dir + freeradius_conf
make certs                   # CA、OpenLDAP サーバー証明書、FreeRADIUS クライアント証明書、dhparam -> CA/
make ldap_dir                # OU / ロール / サービスアカウント / ACL の LDIF -> openldap/ldif/
make freeradius_conf         # ldap_openldap を .env から生成、clients.conf がなければ .sample からコピー
make ldap_testaccounts       # テストユーザー admin01/operator01/readonly01 の LDIF(all には含まれない)
make test                    # スモークテスト(別プロジェクト koitohan-test で起動。稼働中のスタックには触れない)
make up / make down          # docker compose up -d / down(up は freeradius_conf に依存)
make clean                   # 生成した証明書・鍵、LDIF、ldap_openldap を削除
docker compose run --rm --no-deps freeradius radiusd -XC   # FreeRADIUS 設定の構文チェック(スタックは起動しない)
docker compose build tftpd-hpa   # tftpd-hpa/build/ を変更したらビルドし直す(初回は up が自動でビルドする)
```

生成スクリプトにはホスト側に `openssl` と `slappasswd`(`userPassword` のハッシュ化に使用)が必要。

デバッグ: FreeRADIUS のデバッグモードは `compose.yaml` でコメントアウトされている `command: ["radiusd", "-X"]`。それ以外は `docker compose logs -f <service>` を使う。

## アーキテクチャ

**`.env` が唯一の設定元。** `LDAP_DOMAIN` は `domain2dn` ヘルパーで LDAP サフィックスに変換される(`example.com` -> `dc=example,dc=com`)。このヘルパーは各スクリプトに重複して定義されている。コンテナ名(`OPENLDAP_CONTAINER_NAME`、`FREERADIUS_CONTAINER_NAME`)は証明書の subject / SAN のホスト名を兼ねるため、コンテナ名を変えたら証明書の再生成が必要。`DOCKER_SUBNET` は `compose.yaml` のデフォルトネットワークのサブネットで、コンテナの IP は固定していない(コンテナ間は名前で解決する)。反映には `make down && make up` でネットワークを作り直す。`TZ` は全コンテナに環境変数として渡す。新しいサービスを足すときは `environment` に `TZ` を入れ、イメージに tz database があることを確かめる(Alpine は `tzdata` パッケージが必要)。全コンテナに `security_opt: no-new-privileges:true` を付けている。どのイメージも root で起動して自分で降格するので影響を受けないが、setuid のバイナリやファイルケーパビリティで権限を得る構成(たとえば syslog-ng を `user:` で非 root から起動し、s6-overlay の `s6-overlay-suexec` に頼る場合)は動かなくなる。新しいサービスにも付け、起動と動作を確かめること。

**TLS チェーン(`scripts/create_certs.sh`)。** プライベート CA(`CA/default-ca.pem`)、OpenLDAP サーバー証明書(`server_cert` 拡張。`scripts/openssl.conf.template` に SAN を追記して `scripts/openssl.conf` を生成)、FreeRADIUS クライアント証明書(`client_cert` 拡張)を作成する。`compose.yaml` はこれらのファイルを個別に両コンテナへマウントし、FreeRADIUS は LDAPS で OpenLDAP に接続する(公開しているのは 636 のみ、389 はコメントアウト)。`CA/.certs.stamp` は make 用のスタンプファイル。スクリプトは無条件に CA を作り直すため、再実行すると発行済みの証明書はすべて無効になる。証明書はこのスタックのコンテナ間でしか使われないので、作り直して構わない(その後 `make down && make up` で読み込み直す)。`certs` のレシピは先に古いファイルを `rm -f` する。OpenLDAP コンテナが一部を uid 911 に chown するため、上書きではなく削除が必要。`freeradius_client.key` だけは 0644 にしている。FreeRADIUS が root から uid 101 に降りたあとで読むためで、0600 に戻すと `rlm_ldap` の設定の読み込みで止まり、起動しない。

**LDAP の初期投入。** `openldap/ldif/` は `LDAP_SEED_INTERNAL_LDIF_PATH` として読み取り専用でマウントされ、osixia/openldap が**空のデータベースでの初回起動時にのみ**ファイル名順に適用する。数字のプレフィックスがその順序を表す: `100-People`、`200-Roles`(`admin` / `operator` / `readonly` の `groupOfUniqueNames`)、`250` / `260` はテストアカウントとそのロール所属、`300-ServiceAccounts`(`FREERADIUS_SERVICE_ACCOUNT_*` による FreeRADIUS のバインド用アカウント)、`900-ACL`(`{1}mdb` の `olcAccess` を置き換え。`ou=ServiceAccounts` にツリーの読み取り権限を付与)。`LDAP_REMOVE_CONFIG_AFTER_SETUP: "false"` は外さないこと。イメージの起動スクリプトは LDIF のコピーを毎回の起動で行うが、既定(`true`)では初回起動の最後にコピー先(`assets/config`)を消すので、同じコンテナの2回目以降の起動(ホストの再起動、`docker restart`)が `cp` の失敗で終了し、`restart: unless-stopped` と合わさって再起動ループになる。LDIF や `.env` を変更して再投入するには、`openldap/data/` と `openldap/config/` の永続データを消す必要がある。ディレクトリの中身が失われるので、必ず事前に確認すること。

**FreeRADIUS。** イメージ(`cayenneryo/freeradius-server`。v4 の開発ブランチを `jolly-jive/freeradius-server-image` でビルドしたもので、タグで固定している)標準の `/etc/freeradius` をそのまま使い、Koitohan として書いたものだけを `freeradius/config/` に置いて `:ro` で重ねる。追加ファイル(`dictionary.d/`、`mods-available/ldap_openldap`、`policy.d/authz_vendor_role`、`sites-available/ldap-pap`、`clients.conf`)は個別にマウントし、`mods-enabled/` と `sites-enabled/` はディレクトリごと置き換える。この2つの中身はシンボリックリンクで、`../mods-available/xxx` はコンテナ内でイメージ側のファイルに解決される(ホスト上ではリンク切れに見えるのが正常)。イメージ標準のモジュールを有効・無効にするときは、このリンクを増減する。

設定ファイルは3種類に分かれる。
- 共通(追跡する): `Koitohan.dict`、`authz_vendor_role`、`ldap-pap`、`mods-enabled/`・`sites-enabled/` のリンク。
- 利用者が環境に合わせて書く: `clients.conf`(ignore)。`clients.conf.sample` を追跡する。
- `.env` から生成: `mods-available/ldap_openldap`(ignore)。`scripts/generate_freeradius_ldap.sh` が書き出すので、直接編集しない。

認証の流れ: 仮想サーバー `ldap-pap` が LDAP バインドで認証し、`memberOf` を `control.LDAP-Group` に取り込む。`authz_vendor_role` が `clients.conf` の `nas_type` を `Koitohan-Reply-Type`(`Koitohan.dict` で定義)に正規化し、ロール(`admin` / `operator` / `readonly`)との組み合わせでベンダー固有の応答属性を返す。新しいベンダーを足すときは、辞書の enum、`nas_type` の正規表現、各ロールの `case`、スモークテスト(`tests/clients.conf` と `tests/smoke.sh` の期待値)の4か所を揃える。

**スモークテスト(`tests/`)。** `make test` は `compose.yaml` に `tests/compose.test.yaml` を重ね、OpenLDAP と FreeRADIUS だけをプロジェクト `koitohan-test` として起動する。差し替えるのはポート(公開しない)、永続データ(匿名ボリューム)、`clients.conf`、ログの書き込み先だけで、イメージとその他のマウントは本番と同じ。テストアカウントの LDIF は `tests/ldif/` に生成し、`openldap/ldif/` には置かない(本番の初期投入に混ざらないようにするため)。要求は FreeRADIUS のコンテナ内から `radclient` で送り、`Net.Src.IP` で送信元を `127.0.0.N` に変えて `tests/clients.conf` のクライアント(= `nas_type`)を選ぶ。最後に OpenLDAP のコンテナを再起動し、`ldapwhoami` でバインドできることを確かめる(`LDAP_REMOVE_CONFIG_AFTER_SETUP` の退行の検出)。この確認は FreeRADIUS を通さない。OpenLDAP の再起動後、FreeRADIUS は再接続の途中で SIGSEGV で落ちるため(未解決)。`test` は `all` に依存させていない。`.env` がスタンプより新しいと、テストのついでに CA を作り直してしまうため。FreeRADIUS のログのマウント先を変えたときは、`tests/compose.test.yaml` の匿名ボリュームのパスも合わせること。合わせないと、テストが `freeradius/log/` に書き込む。

**syslog-ng。** コンテナ内で 1514 udp/tcp を待ち受ける(ホストの 514 として公開)。`syslog-ng/config/syslog-ng.conf` は機器ごとのファイルを `/var/log/Hosts/${HOST}/${HOST}.log`(ホスト側: `syslog-ng/log/Hosts/`)に書き出し、加えて生メッセージとホスト系マクロを記録する `debug.log` を出力する。`syslog-ng.conf.dist` はイメージのデフォルト設定。

**tftpd-hpa。** 公式イメージがないため、`tftpd-hpa/build/`(Alpine + `tftp-hpa` パッケージ)から `koitohan/tftpd-hpa` をビルドする。`in.tftpd` は uid 1000 で動き、syslog にしか出力しないので、`entrypoint.sh` が busybox の `syslogd` を並走させて標準出力へ流す(`docker compose logs tftpd-hpa` で要求元とファイル名が見える)。`syslogd` の `-t` は外さないこと。musl の `syslog()` は時刻を UTC で付けるため、これを捨てて `syslogd` に `TZ` の時刻を付け直させている。`--permissive` は外さないこと。これがないと、`--umask 022` で作った新規ファイルを「全員に書き込み可ではない」として自分で拒否し、アップロードが 0 バイトのファイルを残して失敗する。

TFTP のルートは `tftpd-hpa/tftpboot/`。`firmware/` は `:ro` でマウントする配布専用、`configs/` が唯一の書き込み先。認証がないので書き込み量を2段で制限している。1ファイルあたりは `ulimits: fsize`(`.env` の `TFTP_UPLOAD_MAX_BYTES`)。超過した転送はエラーを返さずタイムアウトし、上限サイズの書きかけのファイルが残る。総量は、固定サイズのループバックイメージ `tftpd-hpa/configs.img` を `configs/` にマウントして制限する。これはホスト側の `sudo` 作業(`/etc/fstab`)で、手順は README にあり、`make` には含めない。

## 注意点

- LDIF のターゲットは1つのスクリプトが複数ファイルを書き出すため、グループターゲット(`&:`)を使っている。GNU Make 4.3 以上が必要。
- 生成物と実行時データは gitignore 済み(`CA/*`、`openldap/data`、`openldap/config`、`openldap/ldif/*.ldif`、`tests/ldif/*.ldif`、`*/log`、`scripts/openssl.conf`、`syslog-ng/config` の `syslog-ng.conf` 以外、`tftpd-hpa/configs.img`、`tftpd-hpa/tftpboot/` の `firmware/.gitkeep` 以外)。ディレクトリは `.gitkeep` で維持している。`.gitignore` では `!.gitkeep` を末尾に置くこと(後に書いたパターンが優先されるため)。
- `CA/`、`.env`、`freeradius/config/clients.conf`、`freeradius/config/mods-available/ldap_openldap`、生成された LDIF には秘密鍵、共有シークレット、パスワードが含まれる。LDIF は `umask 077` で生成する(0600)。既存のファイルに上書きするときは元の権限が残るので、古い 0664 のファイルは `chmod 600` で直す。
- ファイル単体のバインドマウントは、ホスト側にファイルがないと Docker が同名の root 所有ディレクトリを作る。`docker compose up` を直接叩く前に `make freeradius_conf` を済ませること。
- `openldap/data/` と `openldap/config/` はコンテナが uid 911 に chown する。OpenLDAP にマウントしている `CA/` の4ファイル(`default-ca.pem`、`openldap_server.crt`、`openldap_server.key`、`dhparam.pem`)も同じく 911 に変えられる。いずれも ignore 対象なので git には影響しない。
- `freeradius/log/` は uid 101(イメージの `freerad`)の所有にしておく(`sudo chown -R 101:101 freeradius/log`)。`radius.log` は root のうちに開かれるので所有者が違っても書けるが、`radacct/` 以下の詳細ログは降格後に作るため、書けないとログインがすべて Reject になる。スモークテストは匿名ボリュームを使うので、この不備を検出できない。
- `tftpd-hpa/tftpboot/configs/` は意図して追跡していない(`.gitkeep` も置かない)。ループバックイメージのマウントポイントであり、下のディレクトリを root 所有にしておくことで、マウントが外れたときに書き込みがホストのディスクへ落ちるのを防いでいる。存在しない場合は Docker が root 所有で作るので、アップロードが失敗する側に倒れる。
- TFTP をホスト自身から試すときは、公開アドレス(`<ホストの IP>:69`)ではなくコンテナのアドレスに向ける。ホストから自分の公開アドレス宛てだと、ダウンロードがタイムアウトする(原因は未特定。`network_mode: host` では起きない)。外部のクライアントからは問題なく通る。
- `freeradius/log/radacct/<client-ip>/`、`syslog-ng/log/Hosts/<ip>/`、`tftpd-hpa/tftpboot/configs/` は実機から届いた稼働中のデータであり、テスト用のフィクスチャではない。
