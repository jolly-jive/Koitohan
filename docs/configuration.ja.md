# 設定

[English](configuration.md)

## `.env`

`.env` が唯一の設定元です。スクリプトも `compose.yaml` もこのファイルを読みます。

| 変数                                  | 意味                                                                                  |
| ------------------------------------- | ------------------------------------------------------------------------------------- |
| `LDAP_DOMAIN`                         | ディレクトリのドメイン。`example.com` はサフィックス `dc=example,dc=com` になります。 |
| `LDAP_ORGANISATION`                   | ディレクトリに保存する組織名。                                                        |
| `FREERADIUS_SERVICE_ACCOUNT_NAME`     | FreeRADIUS がディレクトリの検索に使うアカウント。                                     |
| `OPENLDAP_CONTAINER_NAME`             | OpenLDAP のコンテナ名。                                                               |
| `FREERADIUS_CONTAINER_NAME`           | FreeRADIUS のコンテナ名。                                                             |
| `SYSLOG_CONTAINER_NAME`               | syslog-ng のコンテナ名。                                                              |
| `TFTP_CONTAINER_NAME`                 | tftpd-hpa のコンテナ名。                                                              |
| `TFTP_UPLOAD_MAX_BYTES`               | TFTP でアップロードできる1ファイルあたりの上限(バイト数)。「[TFTP](tftp.ja.md)」を参照。   |
| `OPENSSH_CONTAINER_NAME`              | OpenSSH のコンテナ名。                                                                |
| `OPENSSH_HOSTNAME`                    | OpenSSH のコンテナのホスト名。ログインしたシェルのプロンプトに表示されます。          |
| `OPENSSH_PORT`                        | SSH を公開する Docker ホストのポート番号。ホスト自身の sshd とは別の番号にします。    |
| `OPENSSH_SUBNET`                      | OpenSSH と OpenLDAP だけをつなぐ Docker ネットワークのサブネット(CIDR 表記)。         |
| `OPENSSH_ALLOWED_NETWORKS`            | SSH の接続を受け付ける送信元のネットワーク。「[SSH の接続元](ssh.ja.md#ssh-の接続元)」を参照。 |
| `OPENSSH_EGRESS`                      | OpenSSH のコンテナからユーザーが接続できる先。`none`、`any`、または `ssh` と `icmp`(空白で区切る)。「[コンテナから外への接続](ssh.ja.md#コンテナから外への接続)」を参照。 |
| `OPENSSH_SERVICE_ACCOUNT_NAME`        | OpenSSH のコンテナがディレクトリの検索に使うアカウント。                              |
| `PASSWDQC_MIN`                        | `passwd` が受け付けるパスワードの最小の長さ。「[パスワードの規則](ssh.ja.md#パスワードの規則)」を参照。 |
| `PPOLICY_MIN_LENGTH`                  | OpenLDAP が受け付けるパスワードの最小の長さ。「[パスワードポリシー](#パスワードポリシー)」を参照。 |
| `PPOLICY_MAX_FAILURE`                 | ユーザーをロックするまでの、認証の失敗の回数。                                        |
| `PPOLICY_FAILURE_WINDOW`              | 失敗を数える期間(秒)。                                                                |
| `PPOLICY_LOCKOUT_DURATION`            | ロックする時間(秒)。                                                                  |
| `DOCKER_SUBNET`                       | コンテナ同士をつなぐ Docker ネットワークのサブネット(CIDR 表記)。                     |
| `DEVICE_NETWORKS`                     | RADIUS、syslog、TFTP を受け付ける送信元のネットワーク。「[機器のネットワーク](#機器のネットワーク)」を参照。 |
| `TZ`                                  | 全コンテナのタイムゾーン。`Asia/Tokyo` のような tz database の名前で指定します。      |

OpenLDAP、FreeRADIUS、OpenSSH のコンテナ名は、証明書のホスト名を兼ねています。変更したら `make clean && make` で証明書を作り直してください。

`DOCKER_SUBNET` と `OPENSSH_SUBNET` には、機器のいるネットワークやホストから到達するネットワークと重ならない範囲を、互いにも重ならないように指定してください。変更は `make down && make up` で反映されます。

## 機器のネットワーク

FreeRADIUS、syslog-ng、TFTP サーバーは、`DEVICE_NETWORKS` に書いたネットワークからの通信だけを受け付けます。IPv4 のアドレスかプレフィックスを、空白で区切って並べます。

```sh
DEVICE_NETWORKS='10.0.0.0/8 172.16.0.0/12 192.168.0.0/16'
```

既定はプライベートアドレスの全体です。機器の管理用のネットワークが決まっているなら、その範囲だけにしてください。範囲の外から届いたものは、応答を返さずに捨てます。

- RADIUS は、この範囲に加えて `clients.conf` にも登録された機器だけが使えます(「[RADIUS クライアント](#radius-クライアント)」を参照)。
- TFTP は、機器がブートローダーからファームウェアを取りにくるときのアドレスも、範囲に含めてください。
- Docker ホスト自身から送ったものは、コンテナからは `DOCKER_SUBNET` のゲートウェイから届いたように見えます。ホストから動作を確かめるなら、`DOCKER_SUBNET` も範囲に含めてください。
- SSH(利用者作業用コンテナ)の接続元は、別の変数で指定します(「[SSH の接続元](ssh.ja.md#ssh-の接続元)」を参照)。

変更は `make down && make up` で反映されます。

`OPENSSH_HOSTNAME` は、ユーザーがどのサーバーにログインしているかを見分けるための名前です。プロンプトは `alice@koitohan:/logs/Hosts$` の形になります。Koitohan を複数台で動かすときは、台ごとに別の名前にしてください。変更は `make up` で反映されます。

`TZ` は、各コンテナが書き出すログの時刻のタイムゾーンを決めます。変更は `make up` で反映されます。

## RADIUS クライアント

ネットワーク機器を `freeradius/config/clients.conf` に記述します。`ipaddr` には、1台のアドレスのほかに、`192.168.10.0/24` のようなネットワークの範囲も書けます。範囲で書いた機器は、共有シークレットと `nas_type` が同じになります。クライアントの `nas_type` が、その機器に返す応答属性を決めます。

```
client core-switch {
	ipaddr = 192.168.1.1
	secret = changeme
	nas_type = cisco
}

client access-switches {
	ipaddr = 192.168.10.0/24
	secret = changeme
	nas_type = aruba-cx
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

FreeRADIUS は、`DEVICE_NETWORKS` のネットワーク(「[機器のネットワーク](#機器のネットワーク)」を参照)とループバックからの要求だけを受け付けます。

### 機器のローカル認証との関係

RADIUS で認証するように設定したネットワーク機器が、RADIUS とローカル認証をどう使い分けるかは、機器と設定によって異なります。これまでに確かめた範囲では、RADIUS サーバーから応答がないときだけローカル認証に回り、RADIUS サーバーが拒否したとき(許可したときも)はローカル認証を試さない機器がありました。ただし、すべての機器がこう振る舞うとは限りません。認証の順序を設定でき、ローカル認証を先に試すようにできる機器もあると考えられます。お使いの機器のマニュアルと実際の動作で確かめてください。

上のように振る舞う機器では、次のことに気をつけてください。

- 機器には、ローカルの非常用アカウントを残してください。Koitohan が止まっているときは、これでログインします。
- ロックされたユーザーや、ロールのないユーザーは拒否されるので、機器のローカル認証には回りません。
- FreeRADIUS は、`clients.conf` にない機器や、`DEVICE_NETWORKS` の外からの要求に応答しません。このとき機器はローカル認証に回るので、ローカルのパスワードではログインできてしまい、RADIUS が使われていないことに気づきにくくなります。機器を登録したら、Koitohan のアカウントでログインできることと、`freeradius/log/radacct/<機器のアドレス>/` に記録が残ることを確かめてください。

ローカル認証を先に試す設定にした機器では、機器にローカルのアカウントがあるユーザーは、Koitohan のロックやロールに関係なくログインできます。

## ユーザーとロール

ユーザーの登録、削除、ロールの変更、パスワードの再発行、ロックの解除は、Docker ホストで `bin/manage_users.sh` を使って行います。スタックが起動している状態で実行してください。

```sh
bin/manage_users.sh add alice operator            # 登録。3つ目の引数に氏名を付けられます
bin/manage_users.sh role alice admin              # ロールの変更
bin/manage_users.sh passwd alice                  # パスワードの再発行
bin/manage_users.sh unlock alice                  # ロックの解除
bin/manage_users.sh delete alice                  # 削除
```

- ユーザーに割り当てるロールは、`admin`、`operator`、`readonly` のうちの1つです。どのロールにも所属していないユーザーは、すべての機器で拒否されます。スクリプトを使わずに複数のロールに所属させたユーザーは、そのうちいちばん弱いロール(`readonly`、`operator`、`admin` の順)として扱われます。機器へのログインでも、SSH でも同じです。
- `add` と `passwd` は、パスワードを端末から尋ねます。パスワードは、ユーザーが `passwd` で変更するときと同じ規則で判定します(「[パスワードの規則](ssh.ja.md#パスワードの規則)」を参照)。発行したパスワードは、ユーザー本人に SSH でログインして変更してもらってください。
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

## パスワードポリシー

パスワードの規則は、2か所で強制しています。

| 場所                                             | 強制する内容                                   |
| ------------------------------------------------ | ---------------------------------------------- |
| `passwd` と `bin/manage_users.sh`                | 文字の種類に応じた最小の長さ(`PASSWDQC_MIN`。「[パスワードの規則](ssh.ja.md#パスワードの規則)」を参照) |
| OpenLDAP(ppolicy オーバーレイ)                   | 最小の長さ(`PPOLICY_MIN_LENGTH`)と、ロック     |

OpenLDAP は、ハッシュ済みのパスワードの書き込みを受け付けません(長さを確かめられないためです)。ユーザーのパスワードは `bin/manage_users.sh` か `passwd` で設定してください。

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

## サービスアカウントのパスワード

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

## OpenLDAP の管理者のパスワード

OpenLDAP には、パスワードで入る管理者が2つあります。どちらも、アクセス制御とパスワードポリシーの判定を受けません。パスワードは `make`(`make secrets`)が生成し、`secrets/` に置きます。

| ファイル                       | 管理者                                        |
| ------------------------------ | --------------------------------------------- |
| `secrets/ldap_admin_password`  | データの管理者(`cn=admin,<サフィックス>`)     |
| `secrets/ldap_config_password` | 設定の管理者(`cn=admin,cn=config`)            |

このスタックのスクリプトは、どちらのパスワードも使いません。Docker ホストからの作業は、パスワードなしで管理者になれる、コンテナ内の `ldapi:///` で行います(`docker compose exec openldap ldapsearch -Q -Y EXTERNAL -H ldapi:/// ...`)。パスワードが要るのは、LDAP のクライアントを 636 番につなぐときだけで、そのときはファイルのまま渡せます(`ldapsearch -y secrets/ldap_admin_password`)。ファイルの末尾に改行はありません。

OpenLDAP のコンテナは、起動するたびに、ファイルのパスワードを設定し直します。ディレクトリの側だけを書き換えても、次の起動で元に戻ります。

すでにあるファイルは作り直されず、`make clean` でも消えません。

パスワードを変えるときは、Docker ホストで `bin/change_ldap_admin_password.sh` を使います。スタックが起動している状態で実行してください。

```sh
bin/change_ldap_admin_password.sh
docker compose restart freeradius
```

スクリプトは、2つのパスワードを生成して `secrets/` のファイルを差し替え、OpenLDAP のコンテナを作り直し、新しいパスワードで入れることを確かめます。OpenLDAP が起動し直すまでのあいだ、ログインはすべて失敗します。続けて FreeRADIUS を再起動するのは、OpenLDAP の再起動のあと、FreeRADIUS がしばらくログインを拒否するためです(「[既知の制限](../README.ja.md#既知の制限)」を参照)。

途中で止まったときは、もう一度実行してください。いまのパスワードを必要としません。

## ディレクトリの初期データを変更する

OpenLDAP が生成済みの LDIF を読み込むのは、データベースが空の状態での初回起動時だけです。その後に `.env` や LDIF の変更を反映するには、`openldap/data/` と `openldap/config/` を削除して起動し直す必要があります。このとき、ディレクトリ内のユーザーとロールはすべて失われます。`PPOLICY_*` の変更は例外で、データを消さずに反映できます(「[パスワードポリシー](#パスワードポリシー)」を参照)。

LDIF の読み込みが途中で失敗したときは、OpenLDAP は起動しません。`docker compose logs openldap` で原因を確かめ、LDIF を直してから起動し直してください。
