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
- 転送の記録は `tftpd-hpa/log/tftpd.log` に保存されます。要求の種類(取得は `RRQ`、アップロードは `WRQ`)、要求元のアドレス、ファイル名が残ります。同じものを `docker compose logs tftpd-hpa` でも確認できます。
