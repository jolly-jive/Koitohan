# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 概要

ネットワーク機器向けの AAA とログ収集を提供する Docker Compose スタック(Raspberry Pi 上で稼働)。OpenLDAP がユーザーディレクトリ、FreeRADIUS がそれを参照して認証し、syslog-ng が機器のログを収集する。アプリケーションコードはなく、リポジトリの中身は `compose.yaml`、`Makefile`、`scripts/` の生成スクリプト、バインドマウントされる各サービスの設定のみ。

## コマンド

```sh
cp .env.sample .env          # すべてのスクリプトと compose.yaml が .env を読む
make                         # = certs + ldap_dir + freeradius_conf
make certs                   # CA、OpenLDAP サーバー証明書、FreeRADIUS クライアント証明書、dhparam -> CA/
make ldap_dir                # OU / ロール / サービスアカウント / ACL の LDIF -> openldap/ldif/
make freeradius_conf         # ldap_openldap を .env から生成、clients.conf がなければ .sample からコピー
make ldap_testaccounts       # テストユーザー admin01/operator01/readonly01 の LDIF(all には含まれない)
make up / make down          # docker compose up -d / down(up は freeradius_conf に依存)
make clean                   # 生成した証明書・鍵、LDIF、ldap_openldap を削除
docker compose run --rm --no-deps freeradius radiusd -XC   # FreeRADIUS 設定の構文チェック(スタックは起動しない)
```

生成スクリプトにはホスト側に `openssl` と `slappasswd`(`userPassword` のハッシュ化に使用)が必要。

デバッグ: FreeRADIUS のデバッグモードは `compose.yaml` でコメントアウトされている `command: ["/usr/sbin/radiusd", "-X"]`。それ以外は `docker compose logs -f <service>` を使う。

## アーキテクチャ

**`.env` が唯一の設定元。** `LDAP_DOMAIN` は `domain2dn` ヘルパーで LDAP サフィックスに変換される(`example.com` -> `dc=example,dc=com`)。このヘルパーは各スクリプトに重複して定義されている。コンテナ名(`OPENLDAP_CONTAINER_NAME`、`FREERADIUS_CONTAINER_NAME`)は証明書の subject / SAN のホスト名を兼ねるため、コンテナ名を変えたら証明書の再生成が必要。

**TLS チェーン(`scripts/create_certs.sh`)。** プライベート CA(`CA/default-ca.pem`)、OpenLDAP サーバー証明書(`server_cert` 拡張。`scripts/openssl.conf.template` に SAN を追記して `scripts/openssl.conf` を生成)、FreeRADIUS クライアント証明書(`client_cert` 拡張)を作成する。`compose.yaml` はこれらのファイルを個別に両コンテナへマウントし、FreeRADIUS は LDAPS で OpenLDAP に接続する(公開しているのは 636 のみ、389 はコメントアウト)。`CA/.certs.stamp` は make 用のスタンプファイル。スクリプトは無条件に CA を作り直すため、再実行すると発行済みの証明書はすべて無効になる。証明書はこのスタックのコンテナ間でしか使われないので、作り直して構わない(その後 `make down && make up` で読み込み直す)。`certs` のレシピは先に古いファイルを `rm -f` する。OpenLDAP コンテナが一部を uid 911 に chown するため、上書きではなく削除が必要。

**LDAP の初期投入。** `openldap/ldif/` は `LDAP_SEED_INTERNAL_LDIF_PATH` として読み取り専用でマウントされ、osixia/openldap が**空のデータベースでの初回起動時にのみ**ファイル名順に適用する。数字のプレフィックスがその順序を表す: `100-People`、`200-Roles`(`admin` / `operator` / `readonly` の `groupOfUniqueNames`)、`250` / `260` はテストアカウントとそのロール所属、`300-ServiceAccounts`(`FREERADIUS_SERVICE_ACCOUNT_*` による FreeRADIUS のバインド用アカウント)、`900-ACL`(`{1}mdb` の `olcAccess` を置き換え。`ou=ServiceAccounts` にツリーの読み取り権限を付与)。LDIF や `.env` を変更して再投入するには、`openldap/data/` と `openldap/config/` の永続データを消す必要がある。ディレクトリの中身が失われるので、必ず事前に確認すること。

**FreeRADIUS。** イメージ(`freeradius/rocky10`、v4 系)標準の `/etc/freeradius` をそのまま使い、Koitohan として書いたものだけを `freeradius/config/` に置いて `:ro` で重ねる。追加ファイル(`dictionary.d/`、`mods-available/ldap_openldap`、`policy.d/authz_vendor_role`、`sites-available/ldap-pap`、`clients.conf`)は個別にマウントし、`mods-enabled/` と `sites-enabled/` はディレクトリごと置き換える。この2つの中身はシンボリックリンクで、`../mods-available/xxx` はコンテナ内でイメージ側のファイルに解決される(ホスト上ではリンク切れに見えるのが正常)。イメージ標準のモジュールを有効・無効にするときは、このリンクを増減する。

設定ファイルは3種類に分かれる。
- 共通(追跡する): `Koitohan.dict`、`authz_vendor_role`、`ldap-pap`、`mods-enabled/`・`sites-enabled/` のリンク。
- 利用者が環境に合わせて書く: `clients.conf`(ignore)。`clients.conf.sample` を追跡する。
- `.env` から生成: `mods-available/ldap_openldap`(ignore)。`scripts/generate_freeradius_ldap.sh` が書き出すので、直接編集しない。

認証の流れ: 仮想サーバー `ldap-pap` が LDAP バインドで認証し、`memberOf` を `control.LDAP-Group` に取り込む。`authz_vendor_role` が `clients.conf` の `nas_type` を `Koitohan-Reply-Type`(`Koitohan.dict` で定義)に正規化し、ロール(`admin` / `operator` / `readonly`)との組み合わせでベンダー固有の応答属性を返す。新しいベンダーを足すときは、辞書の enum、`nas_type` の正規表現、各ロールの `case` の3か所を揃える。

**syslog-ng。** コンテナ内で 1514 udp/tcp を待ち受ける(ホストの 514 として公開)。`syslog-ng/config/syslog-ng.conf` は機器ごとのファイルを `/var/log/Hosts/${HOST}/${HOST}.log`(ホスト側: `syslog-ng/log/Hosts/`)に書き出し、加えて生メッセージとホスト系マクロを記録する `debug.log` を出力する。`syslog-ng.conf.dist` はイメージのデフォルト設定。

## 注意点

- LDIF のターゲットは1つのスクリプトが複数ファイルを書き出すため、グループターゲット(`&:`)を使っている。GNU Make 4.3 以上が必要。
- 生成物と実行時データは gitignore 済み(`CA/*`、`openldap/data`、`openldap/config`、`openldap/ldif/*.ldif`、`*/log`、`scripts/openssl.conf`、`syslog-ng/config` の `syslog-ng.conf` 以外)。ディレクトリは `.gitkeep` で維持している。`.gitignore` では `!.gitkeep` を末尾に置くこと(後に書いたパターンが優先されるため)。
- `CA/`、`.env`、`freeradius/config/clients.conf`、`freeradius/config/mods-available/ldap_openldap`、生成された LDIF には秘密鍵、共有シークレット、パスワードが含まれる。
- ファイル単体のバインドマウントは、ホスト側にファイルがないと Docker が同名の root 所有ディレクトリを作る。`docker compose up` を直接叩く前に `make freeradius_conf` を済ませること。
- `openldap/data/` と `openldap/config/` はコンテナが uid 911 に chown する。OpenLDAP にマウントしている `CA/` の4ファイル(`default-ca.pem`、`openldap_server.crt`、`openldap_server.key`、`dhparam.pem`)も同じく 911 に変えられる。いずれも ignore 対象なので git には影響しない。
- `freeradius/log/radacct/<client-ip>/` と `syslog-ng/log/Hosts/<ip>/` は実機から届いた稼働中のデータであり、テスト用のフィクスチャではない。
