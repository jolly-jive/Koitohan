# SSH での作業

[English](ssh.md)

## パスワードの変更

新しいパスワードは passwdqc が判定します。`.env` の `PASSWDQC_MIN` は、文字の種類(大文字、小文字、数字、その他)に応じた最小の長さです。`.env.sample` の `12,10,10,8,8` は、次の意味になります。

| 含む文字の種類 | 最小の長さ |
| -------------- | ---------- |
| 3種類以上      | 8          |
| 2種類          | 10         |
| 1種類          | 12         |

先頭の大文字と末尾の数字は、種類に数えません。たとえば `Password1` は1種類として扱われます。変更は `make up` で反映されます。

これとは別に、OpenLDAP 自身も最小の長さを確かめます(「[パスワードポリシー](configuration.ja.md#パスワードポリシー)」を参照)。`PASSWDQC_MIN` のいちばん小さい値は、`PPOLICY_MIN_LENGTH` 以上にしてください。

## ユーザーとロールの変更を反映する

OpenSSH のコンテナは、起動時にディレクトリを読んで、ログインできるユーザーの一覧を作ります。`bin/manage_users.sh` は、変更のたびにこの一覧を作り直すので、ふだんは何もしなくて構いません。スクリプトを使わずにディレクトリを書き換えたときは、一覧を作り直してください。

```sh
docker compose exec openssh koitohan-update-users
```

ロールの変更は、ログイン中のセッションには及びません。すぐに効かせるには、一覧を作り直したあとで、そのユーザーのセッションを切ります。`<uidNumber>` はユーザーの `uidNumber` です。

```sh
docker compose exec openssh pkill -KILL -u <uidNumber>
```

## SSH の接続元

OpenSSH のコンテナは、`OPENSSH_ALLOWED_NETWORKS` に書いたネットワークからの接続だけを受け付けます。書き方は `DEVICE_NETWORKS` と同じです。

```sh
OPENSSH_ALLOWED_NETWORKS='10.0.0.0/8 172.16.0.0/12 192.168.0.0/16'
```

既定はプライベートアドレスの全体です。ユーザーの端末がいるネットワーク(執務室の LAN、VPN の払い出し範囲、踏み台)が決まっているなら、その範囲だけにしてください。機器のネットワークを含める必要はありません。

範囲の外からの接続は、応答を返さずに捨てます。パスワードを試すところまで進めないので、外からの総当たりでユーザーがロックされることもありません(「[パスワードポリシー](configuration.ja.md#パスワードポリシー)」を参照)。

Docker ホスト自身からの接続は、コンテナからは `OPENSSH_SUBNET` のゲートウェイから届いたように見えます。ホストから試すなら、`OPENSSH_SUBNET` も範囲に含めてください。

変更は `make up` で反映されます(OpenSSH のコンテナが作り直され、ログイン中のセッションは切れます)。

## メモリの上限を有効にする(任意)

OpenSSH のコンテナには、プロセス数、メモリ、CPU の上限を設けています。このうちメモリの上限は、Docker ホストで cgroup のメモリコントローラが有効なときにだけ効きます。Raspberry Pi OS の既定では無効で、`docker info` が `No memory limit support` と警告します。

有効にするには、`/boot/firmware/cmdline.txt` の行の末尾に `cgroup_enable=memory` を加えて、Docker ホストを再起動します。
