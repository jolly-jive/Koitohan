# Koitohan

A little and kawaii network backend server.

[English](README.md)

Koitohan は、ネットワーク機器にログイン認証の基盤、ログ収集、ファイル配布を提供する Docker Compose スタックです。Raspberry Pi 5 と、小規模なネットワークや検証環境を想定しています。

- **OpenLDAP** がユーザーとロールを保持します。
- **FreeRADIUS** が機器へのログインを LDAP で認証し、ベンダーごとに決まった権限属性を返します。
- **syslog-ng** が機器の syslog を収集し、ホストごとのディレクトリに保存します。
- **tftpd-hpa** がファームウェアを機器へ配布し、機器のコンフィグのバックアップを受け取ります。
- **OpenSSH** がユーザーに作業用のシェルを提供します。ログの閲覧と取得、TFTP のファイルの出し入れ、パスワードの変更に使います。

ユーザーとロール(`admin`、`operator`、`readonly`)は1か所で管理します。Koitohan がロールを各機器の流儀に読み替えます。たとえば Cisco には `shell:priv-lvl=15`、ArubaOS-CX には `Aruba-Priv-Admin-User = 15` を返します。

## 名前について

「こいとはん」は大阪の土地言葉です。大阪の商家では、その家の娘を「いとはん」と呼びます。「いとしい人」あるいは「いとけない人」が元になったとされる言葉で、親にとっての大切な娘を指します。娘が二人以上いるとき、いちばん下の娘が「こ(小)いとはん」です。

大規模なネットワーク向けの高機能な管理サーバーは、ほかにあります。Koitohan が目指すのは、そうした fat なサーバーではありません。Raspberry Pi で動くほど小さく、最低限よりも少しましな管理機能を備え、それでいて可用性まで考慮したサーバーです。小さくて愛しいサーバーなので、「こいとはん」と名付けました。

可用性のための冗長化は、まだ実装していません。

## 状況

Koitohan は検証段階です。本番利用に耐える堅牢化はしていません。

| 機能               | コンポーネント                                 | 状況     |
| ------------------ | ---------------------------------------------- | -------- |
| ディレクトリ       | OpenLDAP(`osixia/openldap`)                    | 動作中   |
| 認証・認可         | FreeRADIUS 4.x(`cayenneryo/freeradius-server`) | 動作中   |
| ログ収集           | syslog-ng(`linuxserver/syslog-ng`)             | 動作中   |
| ファイル配布       | tftpd-hpa(Alpine から自前でビルド)             | 動作中   |
| ユーザーの作業環境 | OpenSSH(Alpine から自前でビルド)               | 動作中   |
| ログローテーション | Docker ホスト側の logrotate                    | 実装予定 |
| DHCP と DNS        | Kea、BIND9                                     | 未決定   |

FreeRADIUS 4.x は開発バージョンです。Koitohan は正式リリースに先行して採用しています。イメージは [freeradius-server-image](https://github.com/jolly-jive/freeradius-server-image) で開発ブランチからビルドしたもので、`compose.yaml` では特定のビルドに固定しています。

## 必要なもの

- Docker と Compose プラグイン
- GNU Make 4.3 以上
- `openssl`
- `slappasswd`(Debian と Raspberry Pi OS では `slapd` パッケージに含まれます)
- `ssh-keygen`。`make test` は OpenSSH 8.4 以降の `ssh` も使います。

## クイックスタート

```sh
git clone <repository-url> koitohan
cd koitohan

cp .env.sample .env    # その後 .env を編集
make                   # 証明書、サービスアカウントのパスワード、LDIF、FreeRADIUS の LDAP 設定、sshd のホスト鍵を生成
$EDITOR freeradius/config/clients.conf
sudo chown -R 101:101 freeradius/log
sudo chown 1000:10001 tftpd-hpa/tftpboot/firmware
sudo chmod 2770 tftpd-hpa/tftpboot/firmware
make up
```

`make` を実行する前に、`.env` のパスワードをすべて変更してください。`.env.sample` の値は公開されています。FreeRADIUS と OpenSSH のサービスアカウントのパスワードは `.env` にはなく、`make` が生成します(「[サービスアカウントのパスワード](#サービスアカウントのパスワード)」を参照)。

`make` は `clients.conf.sample` から `freeradius/config/clients.conf` を作ります。`make up` の前に、サンプルのクライアントを自分の機器に書き換えてください。

FreeRADIUS は uid 101 で動作し、`freeradius/log/` にログを書き込みます。`chown` をしないと、ログインを記録できず、すべての要求を拒否します。

`firmware/` の `chown` と `chmod` は、SSH でログインしたユーザーのうち、ロール `admin` のユーザーにだけこのディレクトリを開きます(「[SSH での作業](#ssh-での作業)」を参照)。`configs/` の同じ設定は、「[TFTP](#tftp)」の手順に含まれています。

クローン直後は、`docker compose up` を直接実行せずに `make up` を使ってください。Docker がマウントする前に、生成ファイルが揃っていることを保証します。

## 設定

### `.env`

`.env` が唯一の設定元です。スクリプトも `compose.yaml` もこのファイルを読みます。

| 変数                                  | 意味                                                                                  |
| ------------------------------------- | ------------------------------------------------------------------------------------- |
| `LDAP_DOMAIN`                         | ディレクトリのドメイン。`example.com` はサフィックス `dc=example,dc=com` になります。 |
| `LDAP_ORGANISATION`                   | ディレクトリに保存する組織名。                                                        |
| `LDAP_ADMIN_PASSWORD`                 | LDAP のデータ管理者(`cn=admin,<サフィックス>`)のパスワード。                          |
| `LDAP_CONFIG_PASSWORD`                | LDAP の設定管理者のパスワード。                                                       |
| `FREERADIUS_SERVICE_ACCOUNT_NAME`     | FreeRADIUS がディレクトリの検索に使うアカウント。                                     |
| `OPENLDAP_CONTAINER_NAME`             | OpenLDAP のコンテナ名。                                                               |
| `FREERADIUS_CONTAINER_NAME`           | FreeRADIUS のコンテナ名。                                                             |
| `SYSLOG_CONTAINER_NAME`               | syslog-ng のコンテナ名。                                                              |
| `TFTP_CONTAINER_NAME`                 | tftpd-hpa のコンテナ名。                                                              |
| `TFTP_UPLOAD_MAX_BYTES`               | TFTP でアップロードできる1ファイルあたりの上限(バイト数)。「[TFTP](#tftp)」を参照。   |
| `OPENSSH_CONTAINER_NAME`              | OpenSSH のコンテナ名。                                                                |
| `OPENSSH_HOSTNAME`                    | OpenSSH のコンテナのホスト名。ログインしたシェルのプロンプトに表示されます。          |
| `OPENSSH_PORT`                        | SSH を公開する Docker ホストのポート番号。ホスト自身の sshd とは別の番号にします。    |
| `OPENSSH_SUBNET`                      | OpenSSH と OpenLDAP だけをつなぐ Docker ネットワークのサブネット(CIDR 表記)。         |
| `OPENSSH_SERVICE_ACCOUNT_NAME`        | OpenSSH のコンテナがディレクトリの検索に使うアカウント。                              |
| `PASSWDQC_MIN`                        | `passwd` が受け付けるパスワードの最小の長さ。「[パスワードの変更](#パスワードの変更)」を参照。 |
| `PPOLICY_MIN_LENGTH`                  | OpenLDAP が受け付けるパスワードの最小の長さ。「[パスワードポリシー](#パスワードポリシー)」を参照。 |
| `PPOLICY_MAX_FAILURE`                 | ユーザーをロックするまでの、認証の失敗の回数。                                        |
| `PPOLICY_FAILURE_WINDOW`              | 失敗を数える期間(秒)。                                                                |
| `PPOLICY_LOCKOUT_DURATION`            | ロックする時間(秒)。                                                                  |
| `DOCKER_SUBNET`                       | コンテナ同士をつなぐ Docker ネットワークのサブネット(CIDR 表記)。                     |
| `TZ`                                  | 全コンテナのタイムゾーン。`Asia/Tokyo` のような tz database の名前で指定します。      |

OpenLDAP、FreeRADIUS、OpenSSH のコンテナ名は、証明書のホスト名を兼ねています。変更したら `make clean && make` で証明書を作り直してください。

`DOCKER_SUBNET` と `OPENSSH_SUBNET` には、機器のいるネットワークやホストから到達するネットワークと重ならない範囲を、互いにも重ならないように指定してください。変更は `make down && make up` で反映されます。

`DOCKER_SUBNET` にはプライベートアドレスの範囲を指定してください。FreeRADIUS はプライベートアドレスとループバックからの要求だけを受け付けるため(「[RADIUS クライアント](#radius-クライアント)」を参照)、それ以外の範囲を指定すると、Docker ホスト自身から送った RADIUS 要求が拒否されることがあります。

`OPENSSH_HOSTNAME` は、ユーザーがどのサーバーにログインしているかを見分けるための名前です。プロンプトは `alice@koitohan:/logs/Hosts$` の形になります。Koitohan を複数台で動かすときは、台ごとに別の名前にしてください。変更は `make up` で反映されます。

`TZ` は、各コンテナが書き出すログの時刻のタイムゾーンを決めます。変更は `make up` で反映されます。

### RADIUS クライアント

ネットワーク機器を `freeradius/config/clients.conf` に1台ずつ記述します。クライアントの `nas_type` が、その機器に返す応答属性を決めます。

```
client core-switch {
	ipaddr = 192.168.1.1
	secret = changeme
	nas_type = cisco
}
```

`nas_type` は大文字小文字を区別せず、前方一致で判定します。

| `nas_type`                | 属性                         | admin                 | operator           | readonly           |
| ------------------------- | ---------------------------- | --------------------- | ------------------ | ------------------ |
| `cisco`                   | `Cisco-AVPair`               | `shell:priv-lvl=15`   | `shell:priv-lvl=7` | `shell:priv-lvl=1` |
| `aruba-cx`                | `Aruba-Priv-Admin-User`      | 15                    | 7                  | 1                  |
| `aruba-ap`                | なし                         | 許可                  | 拒否               | 拒否               |
| `fortinet`、`fortigate`   | `Fortinet-Group-Name`        | `super_admin`         | `readonly`         | `readonly`         |
| `juniper`                 | `Juniper-Local-User-Name`    | `superuser`           | `operator`         | `read-only`        |
| `palo-alto`               | `PaloAlto-Admin-Role`        | `superuser`           | `readonly`         | `readonly`         |
| `service-type`、`rfc2865` | `Service-Type`               | `Administrative-User` | `NAS-Prompt-User`  | `Login-User`       |
| `ietf-mpl`、`allied`      | `Management-Privilege-Level` | 15                    | 7                  | 1                  |
| `nothing`、`no`、`none`   | なし                         | 許可                  | 許可               | 許可               |

これ以外の値は `Management-Privilege-Level` として扱います。

Fortinet、Juniper、Palo Alto の値は、機器側のプロファイル名やユーザー名です。機器側に同じ名前のものを定義してください。

FreeRADIUS は、プライベートアドレス(`10.0.0.0/8`、`172.16.0.0/12`、`192.168.0.0/16`)とループバックからの要求だけを受け付けます。

### ユーザーとロール

ユーザーの登録、削除、ロールの変更、パスワードの再発行、ロックの解除は、Docker ホストで `bin/manage_users.sh` を使って行います。スタックが起動している状態で実行してください。

```sh
bin/manage_users.sh add alice operator            # 登録。3つ目の引数に氏名を付けられます
bin/manage_users.sh role alice admin              # ロールの変更
bin/manage_users.sh passwd alice                  # パスワードの再発行
bin/manage_users.sh unlock alice                  # ロックの解除
bin/manage_users.sh delete alice                  # 削除
```

- ユーザーに割り当てるロールは、`admin`、`operator`、`readonly` のうちの1つです。どのロールにも所属していないユーザーは、すべての機器で拒否されます。
- `add` と `passwd` は、パスワードを端末から尋ねます。パスワードは、ユーザーが `passwd` で変更するときと同じ規則で判定します(「[パスワードの変更](#パスワードの変更)」を参照)。発行したパスワードは、ユーザー本人に SSH でログインして変更してもらってください。
- ユーザー名に使えるのは、英小文字、数字、`_`、`-` で、32 文字までです。
- `uidNumber` は 10000 から順に割り当てます。一度使った番号は、ユーザーを削除したあとも再利用しません。ユーザーが置いたファイルの所有者は、番号で残るためです。次に割り当てる番号は、ディレクトリの `cn=nextUidNumber` に記録しています。
- 変更は、SSH のログインにもすぐに反映されます。`delete` と `role` は、そのユーザーのログイン中のセッションを切ります。
- `unlock` は、認証の失敗が続いてロックされたユーザーを、時間を待たずに解除します(「[パスワードポリシー](#パスワードポリシー)」を参照)。`passwd` でパスワードを再発行しても、ロックは解除されます。

ディレクトリの中では、ユーザーは `ou=People` の下にあり、ロールは `ou=Roles` の下の `groupOfUniqueNames` です。ロールへの所属は、ロールの `uniqueMember` にユーザーの DN があることで表します。

スクリプトを使わずに登録したユーザーも、`delete`、`role`、`passwd`、`unlock` で扱えます。そうしたユーザーに SSH でログインさせるには、`posixAccount` を持たせます。`uidNumber` は 10000〜59999 の範囲で、ほかのユーザーと重ならず、過去に使っていない番号にします。`gidNumber` は 10000 にします。スクリプトを初めて `add` で使うとき、次に割り当てる番号は、その時点で使われている最大の番号の次から始まります。

既存のユーザーに持たせる例:

```sh
docker compose exec -T openldap ldapmodify -Q -Y EXTERNAL -H ldapi:/// <<'EOF'
dn: uid=alice,ou=People,dc=example,dc=com
changetype: modify
add: objectClass
objectClass: posixAccount
-
add: uidNumber
uidNumber: 10000
-
add: gidNumber
gidNumber: 10000
-
add: homeDirectory
homeDirectory: /home/alice
-
add: loginShell
loginShell: /bin/sh
EOF
```

### パスワードポリシー

パスワードの規則は、2か所で強制しています。

| 場所                                             | 強制する内容                                   |
| ------------------------------------------------ | ---------------------------------------------- |
| `passwd` と `bin/manage_users.sh`                | 文字の種類に応じた最小の長さ(`PASSWDQC_MIN`。「[パスワードの変更](#パスワードの変更)」を参照) |
| OpenLDAP(ppolicy オーバーレイ)                   | 最小の長さ(`PPOLICY_MIN_LENGTH`)と、ロック     |

認証に続けて失敗したユーザーは、しばらくロックされます。`.env.sample` の値では、5 分(`PPOLICY_FAILURE_WINDOW`)のあいだに 10 回(`PPOLICY_MAX_FAILURE`)失敗すると、5 分(`PPOLICY_LOCKOUT_DURATION`)ロックされます。

- 失敗の回数は、ネットワーク機器へのログインと SSH のログインで共通に数えます。認証に成功すると 0 に戻ります。
- ロックされているあいだは、正しいパスワードでも拒否されます。応答はパスワードを誤ったときと同じで、ロックされていることは相手に伝わりません。
- ロックは時間が過ぎると解除されます。すぐに解除するには `bin/manage_users.sh unlock <ユーザー>` を使います。
- FreeRADIUS と OpenSSH のサービスアカウントは、ロックの対象から外しています。

`PPOLICY_*` の値を変えたときは、LDIF を生成し直して、稼働中の OpenLDAP に適用します。ディレクトリのデータを消す必要はありません。

```sh
make ldap_dir
docker compose exec -T openldap ldapmodify -c -Q -Y EXTERNAL -H ldapi:/// < openldap/ldif/400-PPolicy.ldif
```

すでにあるモジュール、オーバーレイ、エントリには `Type or value exists`、`overlay "ppolicy" already in list`、`Already exists` と表示されますが、問題ありません。値だけが置き換わります。

ppolicy がなかったバージョンから更新するときも、同じ手順で追加できます。先に、`.env.sample` の `PPOLICY_*` を `.env` に書き足してください。このときはエラーは表示されません。すでにあるユーザーのパスワードは、そのまま使えます。

適用したあとの OpenLDAP は、ハッシュ済みのパスワードの書き込みを受け付けません(長さを確かめられないためです)。ユーザーのパスワードは `bin/manage_users.sh` か `passwd` で設定してください。

### サービスアカウントのパスワード

FreeRADIUS と OpenSSH のコンテナは、それぞれのサービスアカウントでディレクトリを検索します。そのパスワードは `make`(`make secrets`)が生成し、`secrets/` に置きます。

| ファイル                                      | アカウント                         |
| --------------------------------------------- | ---------------------------------- |
| `secrets/freeradius_service_account_password` | `FREERADIUS_SERVICE_ACCOUNT_NAME`  |
| `secrets/openssh_service_account_password`    | `OPENSSH_SERVICE_ACCOUNT_NAME`     |

通常の運用で、このパスワードを入力することはありません。値を確かめるときは、ファイルを読んでください。ファイルの末尾に改行はありません。

```sh
cat secrets/freeradius_service_account_password; echo
```

すでにあるファイルは作り直されず、`make clean` でも消えません。ディレクトリが覚えているパスワードと食い違うと、すべてのユーザーの認証が止まるためです。

パスワードを変えるときは、Docker ホストで `bin/change_service_account_password.sh` を使います。スタックが起動している状態で実行してください。

```sh
bin/change_service_account_password.sh freeradius
bin/change_service_account_password.sh openssh
```

スクリプトは、新しいパスワードを生成してディレクトリに書き込み、`secrets/` のファイルを差し替え、LDIF と FreeRADIUS の LDAP 設定を生成し直して、そのコンテナを作り直します。OpenSSH のコンテナを作り直すと、ログイン中のセッションは切れます。

途中で止まったときは、もう一度実行してください。いまのパスワードを必要としないので、`secrets/` のファイルとディレクトリが食い違ってしまったときも、同じコマンドで直せます。

`.env` にこのパスワードを書いていたバージョンから更新するときも、このスクリプトを使います。`.env` の値は読まれなくなり、`make` が生成したパスワードはディレクトリと食い違うので、スクリプトで書き込み直します。終わるまでのあいだ、SSH のログインは失敗します。

```sh
# 先に、.env から FREERADIUS_SERVICE_ACCOUNT_PASSWORD と OPENSSH_SERVICE_ACCOUNT_PASSWORD の行を消す
make
docker compose build openssh
make up
bin/change_service_account_password.sh freeradius
bin/change_service_account_password.sh openssh
```

### ディレクトリの初期データを変更する

OpenLDAP が生成済みの LDIF を読み込むのは、データベースが空の状態での初回起動時だけです。その後に `.env` や LDIF の変更を反映するには、`openldap/data/` と `openldap/config/` を削除して起動し直す必要があります。このとき、ディレクトリ内のユーザーとロールはすべて失われます。`PPOLICY_*` の変更は例外で、データを消さずに反映できます(「[パスワードポリシー](#パスワードポリシー)」を参照)。

## TFTP

tftpd-hpa が、`tftpd-hpa/tftpboot/` を TFTP のルートとして公開します。役割の違うディレクトリが2つあります。

| ディレクトリ                   | 用途                                           | 機器からの操作     |
| ------------------------------ | ---------------------------------------------- | ------------------ |
| `tftpd-hpa/tftpboot/firmware/` | ファームウェアなど、機器へ配布するファイル     | 取得のみ           |
| `tftpd-hpa/tftpboot/configs/`  | 機器がアップロードするコンフィグのバックアップ | 取得とアップロード |

配布するファイルは、Docker ホスト上で `firmware/` に置きます。機器からは `firmware/<ファイル名>`、`configs/<ファイル名>` というパスで指定します。Cisco IOS での例:

```
copy running-config tftp://<ホスト>/configs/core-switch.cfg
copy tftp://<ホスト>/firmware/image.bin flash:
```

### アップロード先の容量を制限する(強く推奨)

TFTP には認証がありません。69/udp に到達できる相手は、誰でも `configs/` に書き込めます。何も対策しないと、書き込まれたデータは Docker ホストのディスクを消費します。ディスクがいっぱいになれば、ログの保存も LDAP のデータベースも、ホスト自体も止まります。

これを防ぐため、最初の `make up` の前に、固定サイズのイメージファイルを作って `configs/` にマウントすることを強く推奨します。書き込める総量とファイル数がイメージの中に収まり、いっぱいになっても影響は `configs/` だけで済みます。

リポジトリのディレクトリで、次を実行します。256MB のイメージを作る例です。

```sh
sudo fallocate -l 256M tftpd-hpa/configs.img
sudo mkfs.ext4 -m 0 tftpd-hpa/configs.img
sudo mkdir -p tftpd-hpa/tftpboot/configs
echo "$PWD/tftpd-hpa/configs.img $PWD/tftpd-hpa/tftpboot/configs ext4 loop,noatime,nodev,nosuid,noexec 0 2" | sudo tee -a /etc/fstab
sudo systemctl daemon-reload
sudo mount "$PWD/tftpd-hpa/tftpboot/configs"
sudo chown 1000:10001 tftpd-hpa/tftpboot/configs
sudo chmod 2770 tftpd-hpa/tftpboot/configs
```

`chown` と `chmod` は必ず `mount` の後に実行してください。所有者の 1000 は tftpd-hpa、グループの 10001 は SSH でログインしたロール `admin` のユーザーです。所有者を変えるのはイメージの中のディレクトリで、マウント前のディレクトリは root の所有のままにしておきます。こうしておくと、イメージがマウントされていないときはアップロードが失敗するだけで、ホストのディスクには書き込まれません。

スタックの起動後にマウントした場合は、`docker compose restart tftpd-hpa` でコンテナに反映してください。

この手順を行わずに起動すると、Docker が `configs/` を root の所有で作るため、アップロードは失敗します。上の `chown` と `chmod` で書き込みを許可できますが、容量の制限がなくなるので推奨しません。

### 1ファイルあたりの上限

`.env` の `TFTP_UPLOAD_MAX_BYTES` は、アップロードする1ファイルあたりの上限をバイト数で指定します。`.env.sample` の値は 16MB です。変更は `make up` で反映されます。

- これは総量の上限ではありません。小さなファイルを多数書き込まれることは防げないので、上のイメージファイルと併用してください。
- 上限を超えたアップロードは、エラーにならず、機器側でタイムアウトになります。`configs/` には上限のサイズで途切れたファイルが残るので、手で削除してください。サーバーのログにも、打ち切ったことは記録されません。
- `firmware/` からの取得には、この上限はかかりません。

### 使うときの注意

- バイナリモードで転送してください。Linux の `tftp` コマンドのように、既定がテキスト(netascii)モードのクライアントがあります。
- サーバーは、69 番とは別の UDP ポートから応答します。PC から試して失敗するときは、PC 側のファイアウォールがその応答を遮断していないか確認してください。
- `firmware/` は Docker ホストのディスクにそのまま置かれます。大きなファームウェアを置く前に、空き容量を確認してください。
- 転送の記録は `docker compose logs tftpd-hpa` で確認できます。要求元のアドレスとファイル名が残ります。

## SSH での作業

ユーザーは、ネットワーク機器へのログインと同じユーザー名とパスワードで、OpenSSH のコンテナに SSH でログインできます。ポートは `.env` の `OPENSSH_PORT` です(`.env.sample` では 2222)。公開鍵認証には、まだ対応していません。

```sh
ssh -p 2222 alice@<ホスト>

# 全機器のログから、特定のメッセージだけを取り出す
ssh -p 2222 alice@<ホスト> 'grep -h LINK-3 /logs/Hosts/*/*.log' > link.txt

# ファームウェアを配置する(ロール admin のみ)
scp -P 2222 image.bin alice@<ホスト>:/tftpboot/firmware/
```

| コンテナ内のパス      | 内容                             | admin    | operator | readonly |
| --------------------- | -------------------------------- | -------- | -------- | -------- |
| `/logs/Hosts/`        | 各機器の syslog                  | 読み取り | 読み取り | 読み取り |
| `/tftpboot/firmware/` | 機器へ配布するファイル           | 読み書き | なし     | なし     |
| `/tftpboot/configs/`  | 機器がアップロードしたコンフィグ | 読み書き | なし     | なし     |
| `/tmp/`               | 作業用の置き場所(32MB)           | 読み書き | 読み書き | 読み書き |

- ログインできるのは、`posixAccount` を持ち、ロールに所属するユーザーだけです(「[ユーザーとロール](#ユーザーとロール)」を参照)。
- ホームディレクトリはありません。`scp` と `sftp` では、コンテナ側のパスを絶対パスで指定します。
- ユーザーが書き込めるのは、上の表で「読み書き」とした場所だけです。`/tmp/` の内容は、コンテナを作り直すと消えます。
- ロール `admin` のユーザーが置いたファームウェアを機器が取得するには、ファイルに「その他」の読み取り権限が要ります。0600 で置いたファイルは、`chmod 644` で直してください。
- 機器がアップロードしたコンフィグは、ロール `admin` のユーザーが読み、複製し、削除できます。その場での書き換えはできません。
- ポートフォワーディングは無効にしています。
- 同じ接続元から認証の失敗が続くと、sshd はその接続元からの接続をしばらく拒否します(OpenSSH の `PerSourcePenalties` の既定の動作)。

### パスワードの変更

ログインしたシェルで `passwd` を実行します。変更したパスワードは、ネットワーク機器へのログインにも使われます。

新しいパスワードは passwdqc が判定します。`.env` の `PASSWDQC_MIN` は、文字の種類(大文字、小文字、数字、その他)に応じた最小の長さです。`.env.sample` の `12,10,10,8,8` は、次の意味になります。

| 含む文字の種類 | 最小の長さ |
| -------------- | ---------- |
| 3種類以上      | 8          |
| 2種類          | 10         |
| 1種類          | 12         |

先頭の大文字と末尾の数字は、種類に数えません。たとえば `Password1` は1種類として扱われます。変更は `make up` で反映されます。

これとは別に、OpenLDAP 自身も最小の長さを確かめます(「[パスワードポリシー](#パスワードポリシー)」を参照)。`PASSWDQC_MIN` のいちばん小さい値は、`PPOLICY_MIN_LENGTH` 以上にしてください。

### ユーザーとロールの変更を反映する

OpenSSH のコンテナは、起動時にディレクトリを読んで、ログインできるユーザーの一覧を作ります。`bin/manage_users.sh` は、変更のたびにこの一覧を作り直すので、ふだんは何もしなくて構いません。スクリプトを使わずにディレクトリを書き換えたときは、一覧を作り直してください。

```sh
docker compose exec openssh koitohan-update-users
```

ロールの変更は、ログイン中のセッションには及びません。すぐに効かせるには、一覧を作り直したあとで、そのユーザーのセッションを切ります。`<uidNumber>` はユーザーの `uidNumber` です。

```sh
docker compose exec openssh pkill -KILL -u <uidNumber>
```

### メモリの上限を有効にする(任意)

OpenSSH のコンテナには、プロセス数、メモリ、CPU の上限を設けています。このうちメモリの上限は、Docker ホストで cgroup のメモリコントローラが有効なときにだけ効きます。Raspberry Pi OS の既定では無効で、`docker info` が `No memory limit support` と警告します。

有効にするには、`/boot/firmware/cmdline.txt` の行の末尾に `cgroup_enable=memory` を加えて、Docker ホストを再起動します。

### 稼働中の環境に追加する

OpenSSH のコンテナがなかったバージョンから更新するときは、ディレクトリのデータを消さずに、次の手順で追加できます。

```sh
# 先に、.env.sample の OPENSSH_* と PASSWDQC_MIN を .env に書き足す
make                   # CA と証明書を作り直し、sshd のホスト鍵を生成
docker compose exec -T openldap ldapadd -c -Q -Y EXTERNAL -H ldapi:/// < openldap/ldif/300-ServiceAccounts.ldif
sudo chown 1000:10001 tftpd-hpa/tftpboot/firmware tftpd-hpa/tftpboot/configs
sudo chmod 2770 tftpd-hpa/tftpboot/firmware tftpd-hpa/tftpboot/configs
chmod -R go+rX syslog-ng/log/Hosts
make down && make up
```

- `ldapadd` は、OpenSSH 用のサービスアカウントを追加します。すでにあるエントリには `Already exists` と表示されますが、問題ありません。パスワードポリシーは、このあとで適用してください(「[パスワードポリシー](#パスワードポリシー)」を参照)。先に適用すると、この LDIF のハッシュ済みのパスワードが拒否されます。
- 最後の `chmod` は、これまでに作られたログのディレクトリを、SSH でログインしたユーザーが読めるようにします。以前のバージョンは、所有者しか入れないディレクトリを作っていました。
- そのあと、SSH でログインさせるユーザーに `posixAccount` を持たせ(「[ユーザーとロール](#ユーザーとロール)」を参照)、`koitohan-update-users` を実行してください。

## ポート

| ポート           | サービス    |
| ---------------- | ----------- |
| 2222/tcp         | SSH(番号は `OPENSSH_PORT` で指定) |
| 1812/udp         | RADIUS 認証 |
| 514/udp、514/tcp | syslog      |
| 69/udp           | TFTP        |
| 636/tcp          | LDAPS       |

1813/udp も公開していますが、RADIUS アカウンティングは未実装です。

## ログ

| パス                                    | 内容                         |
| --------------------------------------- | ---------------------------- |
| `syslog-ng/log/Hosts/<host>/<host>.log` | 各機器の syslog              |
| `syslog-ng/log/debug.log`               | すべての生メッセージ(調査用) |
| `freeradius/log/`                       | FreeRADIUS の認証ログ        |

`freeradius/log/` のファイルは uid 101 の所有です。読むときは `sudo` を使ってください。

これらのファイルは、まだローテーションされません。特に `debug.log` は際限なく大きくなります。

TFTP の転送の記録はファイルには保存されません。`docker compose logs tftpd-hpa` で確認します。SSH のログインの記録も同様で、`docker compose logs openssh` で確認します。

## コマンド

```sh
make                    # certs + secrets + ldap_dir + freeradius_conf + ssh_hostkeys
make certs              # プライベート CA、サーバー証明書、クライアント証明書
make secrets            # サービスアカウントのパスワード(すでにあれば作り直さない)
make ldap_dir           # OU、ロール、サービスアカウント、パスワードポリシー、ACL の LDIF
make freeradius_conf    # FreeRADIUS の LDAP モジュール設定と clients.conf
make ssh_hostkeys       # sshd のホスト鍵(すでにあれば作り直さない)
make test               # スモークテスト
make up                 # スタックを起動
make down               # スタックを停止
make clean              # 生成した証明書、LDIF、設定を削除
bin/manage_users.sh     # ユーザーの登録、削除、ロールの変更、パスワードの再発行、ロックの解除
bin/change_service_account_password.sh   # サービスアカウントのパスワードの変更
```

スタックを起動せずに FreeRADIUS の設定を検査する:

```sh
docker compose run --rm --no-deps freeradius radiusd -XC
```

認証と認可を通しで確かめる:

```sh
make test
```

`make test` は、OpenLDAP、FreeRADIUS、OpenSSH を別のプロジェクト(`koitohan-test`)として起動し、`bin/manage_users.sh` でテストユーザーを登録して認証し、機器種別とロールの組み合わせごとに応答属性を照合します。続いて、各ロールのユーザーで SSH でログインし、ディレクトリの権限とパスワードの変更を確かめます。そのあと、`bin/manage_users.sh` の各操作と、パスワードポリシー(最小の長さ、ロックとその解除)、サービスアカウントのパスワードの変更を確かめます。最後に OpenLDAP のコンテナを再起動し、起動し直せることを確かめます。ポートを公開せず、データも残さず、サービスアカウントのパスワードもテスト用に生成する(`tests/generated/`)ので、稼働中のスタックには影響しません。事前に `make` を済ませておいてください。失敗した項目は `KEEP=1 tests/smoke.sh` でテスト用のスタックを残して調べられます。

tftpd-hpa と OpenSSH のイメージは、最初の `make up` で自動的にビルドされます。`tftpd-hpa/build/` や `openssh/build/` を変更したときは、ビルドし直してから起動します。

```sh
docker compose build tftpd-hpa openssh
make up
```

`make clean` は、sshd のホスト鍵(`openssh/hostkeys/`)を消しません。ホスト鍵が変わると、すべてのユーザーの手元で警告が出るためです。サービスアカウントのパスワード(`secrets/`)も消しません(「[サービスアカウントのパスワード](#サービスアカウントのパスワード)」を参照)。

サービスのログを追う:

```sh
docker compose logs -f freeradius
```

## 既知の制限

- 複数のロールに所属するユーザーについて、優先順位を定めていません。
- TFTP サーバーは、接続元のアドレスを制限していません。
- `bin/manage_users.sh` を使わずに行ったユーザーとロールの変更は、`koitohan-update-users` を実行するまで、SSH のログインに反映されません。
- `passwd` によるパスワードの判定は、ログインしたユーザーが迂回できます。この判定は、不注意で弱いパスワードを設定することを防ぐためのものです。迂回しても、OpenLDAP 自身が確かめる最小の長さ(`PPOLICY_MIN_LENGTH`)は守られます。
- ネットワーク機器のログイン画面や SSH のポートに到達できる相手は、誤ったパスワードを送り続けることで、名前を知っているユーザーをロックできます。ロックは時間が過ぎると解除されます(「[パスワードポリシー](#パスワードポリシー)」を参照)。
- SSH でログインしたユーザーは、OpenSSH のコンテナから、Docker ホストや外部のネットワークへ接続できます。Docker のネットワークで届かなくしているのは、OpenLDAP 以外のコンテナだけです。
- FreeRADIUS を動かしたまま OpenLDAP が再起動すると(`docker compose restart openldap` など)、FreeRADIUS はその後のログインを拒否し、やがてセグメンテーション違反で異常終了します。Docker が起動し直すので、それ以降のログインは通ります。開発バージョンである FreeRADIUS 4.x の不具合です。ログインが拒否される時間をなくすには、OpenLDAP の再起動に続けて `docker compose restart freeradius` で FreeRADIUS も再起動してください。FreeRADIUS 側で修正されたら、この項目は削除します。

## セキュリティ上の注意

次のファイルには、秘密鍵、共有シークレット、パスワードが含まれます。いずれも git の管理対象外です。他人が読めるバックアップやコピーに含めないでください。

- `.env`
- `CA/`
- `freeradius/config/clients.conf`
- `freeradius/config/mods-available/ldap_openldap`
- `openldap/ldif/*.ldif`
- `openssh/hostkeys/`
- `secrets/`
- `tftpd-hpa/tftpboot/configs/`(機器のコンフィグ。パスワードのハッシュや共有シークレットを含むことがあります)

`CA/freeradius_client.key` は、Docker ホストのすべてのユーザーが読めます。FreeRADIUS がこの鍵を uid 101 で読み、ホスト側にはその uid が所有するものがないためです。

`syslog-ng/log/Hosts/` 以下の機器のログは、Docker ホストのすべてのユーザーが読めます。SSH でログインしたユーザーに読ませるためです。

RADIUS のログインは PAP を使うため、通信経路上でユーザーのパスワードを守るのは、各クライアントの共有シークレットです。機器ごとに長いランダムなシークレットを使ってください。

TFTP には認証も暗号化もありません。69/udp に到達できる相手は、ファイル名がわかれば `firmware/` と `configs/` のファイルを取得でき、`configs/` のファイルを上書きできます。バックアップしたコンフィグも取得の対象です。69/udp は、信頼できる管理用のネットワークにだけ公開してください。

## ドキュメント

- [基本設計書](docs/basic-design.md)

## ライセンス

Apache License 2.0 です。[LICENSE](LICENSE) と [NOTICE](NOTICE) を参照してください。
