# バックアップと復元

[English](backup.md)

`bin/backup.sh` は、Koitohan が作り直せないもの(設定、パスワードと鍵、OpenLDAP のディレクトリ、機器がアップロードしたコンフィグ)を、1つのアーカイブにまとめます。アーカイブとリポジトリがあれば、たとえば Raspberry Pi のストレージが壊れたときに、新しいホストで Koitohan を組み直せます。

## バックアップに入るもの

| アーカイブの中                         | 中身                                                         |
| -------------------------------------- | ------------------------------------------------------------ |
| `.env`                                 | 設定                                                         |
| `freeradius/config/clients.conf`       | RADIUS のクライアントと共有シークレット                      |
| `secrets/`                             | サービスアカウントと OpenLDAP の管理者のパスワード           |
| `openssh/hostkeys/`                    | OpenSSH のコンテナのホスト鍵                                 |
| `ldap/config.ldif`、`ldap/data.ldif`   | ディレクトリの設定と中身(ユーザー、ロール、パスワード、ロック) |
| `tftp-configs.tar`                     | `tftpd-hpa/tftpboot/configs/` のファイル(所有者とパーミッションを含む) |
| `koitohan-backup.txt`                  | バックアップを取った日時とホスト、リポジトリのコミット       |

次のものは入れません。

- **ログ**(`syslog-ng/log/`、`freeradius/log/`、`tftpd-hpa/log/`)。Koitohan は2台の冗長構成を前提にしていて、機器は両方のサーバーにログを送ります。失ったサーバーのログは、もう片方に残っています。
- **`tftpd-hpa/tftpboot/firmware/`**。ファームウェアはベンダーから取り直せます。
- **`make` が作り直すもの**: `CA/` の証明書、LDIF、FreeRADIUS の LDAP 設定、syslog-ng の機器のネットワーク、logrotate の設定。証明書はスタックのコンテナ間でしか使わないので、CA が新しくなっても外には影響しません。
- **Docker ホストでの `sudo` の作業**(`configs/` のイメージファイルや `/etc/fstab` など)。新しいホストでやり直します。

ディレクトリと `secrets/` は、同じバックアップのものを使ってください。ディレクトリはサービスアカウントのパスワードを覚えていて、FreeRADIUS と OpenSSH は `secrets/` のパスワードで bind します。

## バックアップを取る

スタックが起動している状態で、Docker ホストで `bin/backup.sh` を実行します。書き出す先のディレクトリを渡します。

```sh
bin/backup.sh /var/backups/koitohan
```

`koitohan-<ホスト名>-<日付>-<時刻>.tar.gz` を、パーミッション 0600 で書き出します。スタックは止まりません。ディレクトリは `slapcat` で書き出していて、OpenLDAP が動いたままでも一貫した状態を読めます。

`-k` を付けると、新しいアーカイブを書き終えたあとで、同じディレクトリにある同じホストの古いアーカイブを消し、指定した数だけ残します。

```sh
bin/backup.sh -k 14 /var/backups/koitohan
```

### アーカイブの扱い

アーカイブは暗号化していません。機器の共有シークレット、サービスアカウントと OpenLDAP の管理者のパスワード、ホスト鍵、ユーザーのパスワードのハッシュが、そのまま入っています。手に入れた人は、機器やユーザーに対して Koitohan になりすませます。

- こいとはん管理者だけが読める場所に置いてください。コピーするときも、パーミッション 0600 を保ってください。
- 暗号化された経路でコピーしてください(SSH を通した `scp` や `rsync` など)。
- Docker ホストの外にも置いてください。同じストレージにあるバックアップは、ストレージと一緒に失われます。

### 毎日実行する

`docker` を実行できるこいとはん管理者の crontab(`crontab -e`)に1行足します。`/path/to/koitohan` はリポジトリのディレクトリに書き換えてください。毎日 3 時 30 分にバックアップを取り、14 個を残し、出力をホストのジャーナルに送る例です。

```sh
# ディレクトリは最初に1回だけ用意する
sudo install -d -m 700 -o "$USER" -g "$USER" /var/backups/koitohan
```

```
30 3 * * * /path/to/koitohan/bin/backup.sh -k 14 /var/backups/koitohan 2>&1 | logger -t koitohan-backup
```

結果は `journalctl -t koitohan-backup` で確かめます。成功すると `wrote <アーカイブ>` と出ます。

3 時 45 分にアーカイブを別のホストへコピーするなら、次のような行を足します。使う SSH の鍵はパスフレーズなしで使えるものになるので、相手のホストでできることを絞っておいてください。

```
45 3 * * * rsync -a /var/backups/koitohan/ backup-host:koitohan/ 2>&1 | logger -t koitohan-backup
```

## 新しいホストに復元する

リポジトリのディレクトリで、スタックを動かすユーザーとして実行します。`<アーカイブ>` はバックアップのパスです。

1. リポジトリを clone し、アーカイブに書いてあるコミットに切り替えます。新しいコミットでは、ディレクトリの組み立て方がバックアップのものと違う場合があります。

   ```sh
   git clone <repository-url> koitohan
   cd koitohan
   tar -x -O -z -f <アーカイブ> koitohan-backup.txt
   git checkout <コミット>
   ```

2. アーカイブから設定、パスワード、ホスト鍵を取り出し、`make` を実行します。`make` は、すでにあるパスワードとホスト鍵をそのまま使い、証明書は新しく作ります。

   ```sh
   tar -x -z -f <アーカイブ> .env freeradius/config/clients.conf secrets openssh/hostkeys
   make
   ```

3. [クイックスタート](../README.ja.md#クイックスタート)と [TFTP](tftp.ja.md#アップロード先の容量を制限する強く推奨) の `sudo` の作業をして、確かめます。

   ```sh
   make host_check
   ```

4. ディレクトリを読み込み、スタックを起動します。`bin/restore_ldap.sh` は、OpenLDAP のコンテナを起動せずに作り、空の永続データにディレクトリを読み込んで、OpenLDAP が初期投入をやり直さないよう目印を置きます。

   ```sh
   bin/restore_ldap.sh <アーカイブ>
   make up
   ```

5. `configs/` のファイルを戻します。tftpd-hpa のコンテナを通して戻すので、所有者も元のとおりになります。

   ```sh
   tar -x -O -z -f <アーカイブ> tftp-configs.tar | docker compose exec -T tftpd-hpa tar -x -f - -C /tftpboot
   ```

6. 機器から RADIUS でログインできること、ユーザーが SSH でログインできることを確かめます。ホスト鍵は以前と同じなので、ユーザーの手元で警告は出ません。

手順 1 で古いコミットに切り替えたときは、`git switch main` で追っているブランチに戻り、それ以降の変更を、稼働中の Koitohan と同じ手順で反映してください。

## ディレクトリだけを復元する

ディレクトリが壊れたときや、大きな部分を誤って消したときは、空の OpenLDAP にバックアップのディレクトリを読み込みます。いまのディレクトリの中身はすべて失われるので、必ず事前に確認してください。

```sh
make down
sudo find openldap/data openldap/config -mindepth 1 ! -name .gitkeep -delete
bin/restore_ldap.sh <アーカイブ>
make up
```

`openldap/data/` か `openldap/config/` に何かが残っていると、`bin/restore_ldap.sh` は実行を断ります。

バックアップのあとでサービスアカウントのパスワードを変えていた場合、`bin/restore_ldap.sh` は、`secrets/` がバックアップと食い違っていると警告します。このままでは FreeRADIUS か OpenSSH が bind できません。`make up` のあと、警告に出たアカウントのパスワードを変えてください。

```sh
bin/change_service_account_password.sh freeradius
```

OpenLDAP の管理者のパスワードは何もしなくて構いません。OpenLDAP は起動のたびに `secrets/` のパスワードを設定します。

## `configs/` だけを復元する

```sh
tar -x -O -z -f <アーカイブ> tftp-configs.tar | docker compose exec -T tftpd-hpa tar -x -f - -C /tftpboot
```

`configs/` に同じ名前のファイルがあれば上書きします。バックアップにないファイルは残ります。

## 知っておくこと

- 復元すると、ディレクトリはバックアップの時点に戻ります。そのあとのユーザーの追加と削除、ロールの変更、パスワードの変更は失われ、ロックもその時点の状態になります。バックアップのあとでパスワードを変えたユーザーには、古いパスワードに戻ったことを伝えてください。
- `make up` がユーザーを読み直すので、`koitohan-update-users` を実行しなくても、SSH のログインは復元したディレクトリに従います。
- `bin/restore_ldap.sh` は、ディレクトリの設定(`cn=config`)もバックアップから戻します。パスワードポリシーとアクセス制御も含まれます。
- アーカイブにはディレクトリのエントリを入れていないので、展開しても、リポジトリのディレクトリのパーミッションは変わりません。
