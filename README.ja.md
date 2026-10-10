# Koitohan

A little and kawaii network backend server.

[English](README.md)

Koitohan は、ネットワーク機器にログイン認証の基盤、ログ収集、ファイル配布を提供する Docker Compose スタックです。Raspberry Pi 5 と、小規模なネットワークや検証環境を想定しています。

- **OpenLDAP** がユーザーとロールを保持します。
- **FreeRADIUS** が機器へのログインを LDAP で認証し、ベンダーごとに決まった権限属性を返します。
- **syslog-ng** が機器の syslog を収集し、ホストごとのディレクトリに保存します。
- **tftpd-hpa** がファームウェアを機器へ配布し、機器のコンフィグのバックアップを受け取ります。

ユーザーとロール(`admin`、`operator`、`readonly`)は1か所で管理します。Koitohan がロールを各機器の流儀に読み替えます。たとえば Cisco には `shell:priv-lvl=15`、ArubaOS-CX には `Aruba-Priv-Admin-User = 15` を返します。

## 名前について

「こいとはん」は大阪の土地言葉です。大阪の商家では、その家の娘を「いとはん」と呼びます。「いとしい人」あるいは「いとけない人」が元になったとされる言葉で、親にとっての大切な娘を指します。娘が二人以上いるとき、いちばん下の娘が「こ(小)いとはん」です。

大規模なネットワーク向けの高機能な管理サーバーは、ほかにあります。Koitohan が目指すのは、そうした fat なサーバーではありません。Raspberry Pi で動くほど小さく、最低限よりも少しましな管理機能を備え、それでいて可用性まで考慮したサーバーです。小さくて愛しいサーバーなので、「こいとはん」と名付けました。

可用性のための冗長化は、まだ実装していません。

## 状況

Koitohan は検証段階です。本番利用に耐える堅牢化はしていません。

| 機能               | コンポーネント                       | 状況     |
| ------------------ | ------------------------------------ | -------- |
| ディレクトリ       | OpenLDAP(`osixia/openldap`)          | 動作中   |
| 認証・認可         | FreeRADIUS 4.x(`freeradius/rocky10`) | 動作中   |
| ログ収集           | syslog-ng(`linuxserver/syslog-ng`)   | 動作中   |
| ファイル配布       | tftpd-hpa(Alpine から自前でビルド)   | 動作中   |
| ログローテーション | Docker ホスト側の logrotate          | 実装予定 |
| DHCP と DNS        | Kea、BIND9                           | 未決定   |

FreeRADIUS 4.x は開発バージョンです。Koitohan は正式リリースに先行して採用しています。

## 必要なもの

- Docker と Compose プラグイン
- GNU Make 4.3 以上
- `openssl`
- `slappasswd`(Debian と Raspberry Pi OS では `slapd` パッケージに含まれます)

## クイックスタート

```sh
git clone <repository-url> koitohan
cd koitohan

cp .env.sample .env    # その後 .env を編集
make                   # 証明書、LDIF、FreeRADIUS の LDAP 設定を生成
$EDITOR freeradius/config/clients.conf
make up
```

`make` を実行する前に、`.env` のパスワードをすべて変更してください。`.env.sample` の値は公開されています。

`make` は `clients.conf.sample` から `freeradius/config/clients.conf` を作ります。`make up` の前に、サンプルのクライアントを自分の機器に書き換えてください。

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
| `FREERADIUS_SERVICE_ACCOUNT_PASSWORD` | そのアカウントのパスワード。                                                          |
| `OPENLDAP_CONTAINER_NAME`             | OpenLDAP のコンテナ名。                                                               |
| `FREERADIUS_CONTAINER_NAME`           | FreeRADIUS のコンテナ名。                                                             |
| `SYSLOG_CONTAINER_NAME`               | syslog-ng のコンテナ名。                                                              |
| `TFTP_CONTAINER_NAME`                 | tftpd-hpa のコンテナ名。                                                              |
| `TFTP_UPLOAD_MAX_BYTES`               | TFTP でアップロードできる1ファイルあたりの上限(バイト数)。「[TFTP](#tftp)」を参照。   |
| `DOCKER_SUBNET`                       | コンテナ同士をつなぐ Docker ネットワークのサブネット(CIDR 表記)。                     |
| `TZ`                                  | 全コンテナのタイムゾーン。`Asia/Tokyo` のような tz database の名前で指定します。      |

OpenLDAP と FreeRADIUS のコンテナ名は、証明書のホスト名を兼ねています。変更したら `make clean && make` で証明書を作り直してください。

`DOCKER_SUBNET` には、機器のいるネットワークやホストから到達するネットワークと重ならない範囲を指定してください。変更は `make down && make up` で反映されます。

`DOCKER_SUBNET` にはプライベートアドレスの範囲を指定してください。FreeRADIUS はプライベートアドレスとループバックからの要求だけを受け付けるため(「[RADIUS クライアント](#radius-クライアント)」を参照)、それ以外の範囲を指定すると、Docker ホスト自身から送った RADIUS 要求が拒否されることがあります。

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

ユーザーは `ou=People` の下に置きます。ロールは `ou=Roles` の下の `groupOfUniqueNames` です。ユーザーをロールに所属させるには、ロールの `uniqueMember` にユーザーの DN を追加します。

Koitohan にユーザー管理用のツールは含まれていません。任意の LDAP クライアントで `ldaps://<ホスト>:636` に接続してください。CA 証明書は `CA/default-ca.pem` です。

手早く試すには、`make ldap_testaccounts` でテストユーザー3名(`admin01`、`operator01`、`readonly01`)を各ロールに1名ずつ生成できます。パスワードは `scripts/generate_ldap_test_accounts.sh` に書いてあります。最初の `make up` の前に実行してください。検証環境以外では使わないでください。

### ディレクトリの初期データを変更する

OpenLDAP が生成済みの LDIF を読み込むのは、データベースが空の状態での初回起動時だけです。その後に `.env` や LDIF の変更を反映するには、`openldap/data/` と `openldap/config/` を削除して起動し直す必要があります。このとき、ディレクトリ内のユーザーとロールはすべて失われます。

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
sudo chown 1000:1000 tftpd-hpa/tftpboot/configs
```

`chown` は必ず `mount` の後に実行してください。所有者を変えるのはイメージの中のディレクトリで、マウント前のディレクトリは root の所有のままにしておきます。こうしておくと、イメージがマウントされていないときはアップロードが失敗するだけで、ホストのディスクには書き込まれません。

スタックの起動後にマウントした場合は、`docker compose restart tftpd-hpa` でコンテナに反映してください。

この手順を行わずに起動すると、Docker が `configs/` を root の所有で作るため、アップロードは失敗します。`sudo chown 1000:1000 tftpd-hpa/tftpboot/configs` で書き込みを許可できますが、容量の制限がなくなるので推奨しません。

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

## ポート

| ポート           | サービス    |
| ---------------- | ----------- |
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

これらのファイルは、まだローテーションされません。特に `debug.log` は際限なく大きくなります。

TFTP の転送の記録はファイルには保存されません。`docker compose logs tftpd-hpa` で確認します。

## コマンド

```sh
make                    # certs + ldap_dir + freeradius_conf
make certs              # プライベート CA、サーバー証明書、クライアント証明書
make ldap_dir           # OU、ロール、サービスアカウント、ACL の LDIF
make freeradius_conf    # FreeRADIUS の LDAP モジュール設定と clients.conf
make ldap_testaccounts  # テストユーザーの LDIF
make up                 # スタックを起動
make down               # スタックを停止
make clean              # 生成した証明書、LDIF、設定を削除
```

スタックを起動せずに FreeRADIUS の設定を検査する:

```sh
docker compose run --rm --no-deps freeradius radiusd -XC
```

tftpd-hpa のイメージは、最初の `make up` で自動的にビルドされます。`tftpd-hpa/build/` を変更したときは、ビルドし直してから起動します。

```sh
docker compose build tftpd-hpa
make up
```

サービスのログを追う:

```sh
docker compose logs -f freeradius
```

## 既知の制限

- どのロールにも所属していないユーザーも、権限属性なしで認証に成功します。その後の扱いは機器によって異なります。
- 複数のロールに所属するユーザーについて、優先順位を定めていません。
- `freeradius` と `syslog-ng` のイメージは、バージョンを固定していません。
- TFTP サーバーは、接続元のアドレスを制限していません。

## セキュリティ上の注意

次のファイルには、秘密鍵、共有シークレット、パスワードが含まれます。いずれも git の管理対象外です。他人が読めるバックアップやコピーに含めないでください。

- `.env`
- `CA/`
- `freeradius/config/clients.conf`
- `freeradius/config/mods-available/ldap_openldap`
- `openldap/ldif/*.ldif`
- `tftpd-hpa/tftpboot/configs/`(機器のコンフィグ。パスワードのハッシュや共有シークレットを含むことがあります)

RADIUS のログインは PAP を使うため、通信経路上でユーザーのパスワードを守るのは、各クライアントの共有シークレットです。機器ごとに長いランダムなシークレットを使ってください。

TFTP には認証も暗号化もありません。69/udp に到達できる相手は、ファイル名がわかれば `firmware/` と `configs/` のファイルを取得でき、`configs/` のファイルを上書きできます。バックアップしたコンフィグも取得の対象です。69/udp は、信頼できる管理用のネットワークにだけ公開してください。

## ドキュメント

- [基本設計書](docs/basic-design.md)

## ライセンス

Apache License 2.0 です。[LICENSE](LICENSE) と [NOTICE](NOTICE) を参照してください。
