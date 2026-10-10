# A little and kawaii network backend server `Koitohan` 基本設計書

## 1. 目的

Raspberry Pi 5 を Docker ホストとして利用し、  
**ネットワーク機器（Cisco / Aruba / Allied Telesis など）の管理基盤を統合的に提供するサーバ**を構築する。

提供機能と実装状況：

| 機能                 | コンポーネント | 状況                                           |
| -------------------- | -------------- | ---------------------------------------------- |
| ID管理（LDAP）       | OpenLDAP       | 実装済み                                       |
| 認証・認可（RADIUS） | FreeRADIUS     | 実装済み                                       |
| ログ管理（SYSLOG）   | syslog-ng      | 受信・保存は実装済み、ローテーションは実装予定 |
| ファイル配布（TFTP） | tftpd-hpa      | 実装予定                                       |
| DHCP / DNS           | Kea / BIND9    | 未決定（10 節）                                |

本設計は「検証段階」を前提とし、可用性は後回しとするが、将来の冗長化を見据えた構成とする。

### 1.1 名称と目指す姿

「こいとはん」は大阪の言葉である。大阪の商家では、その家の娘を「いとはん」と呼ぶ。「いとしい人」あるいは「いとけない人」が元になったとされる言葉で、親にとっての大切な娘を指す。娘が二人以上いるとき、いちばん下の娘が「こ（小）いとはん」である。

大規模なネットワーク向けの高機能な管理サーバは、ほかに存在する。本プロダクトが目指すのは、そうした fat なサーバではない。

- Raspberry Pi で動くほど小さい。
- 最低限よりも少しましな管理機能を提供する。
- それでいて、可用性まで考慮する（冗長化は 11 節）。

小さくて愛しいサーバであることから、「こいとはん」と名付けた。機能を追加するときは、この規模感を保てるかどうかを判断基準とする。

---

## 2. 全体構成概要

```text
+-------------------------------------------+
|              Raspberry Pi 5               |
|               (Docker Host)               |
+-------------------------------------------+
| OpenLDAP     | Roles/Users   | 実装済み   |
| FreeRADIUS   | AuthZ/AuthN   | 実装済み   |
| syslog-ng    | Log Mgmt      | 実装済み   |
| tftpd-hpa    | TFTP          | 実装予定   |
+-------------------------------------------+
| logrotate (Docker ホスト側)  | 実装予定   |
+-------------------------------------------+
```

通信経路：

```text
ネットワーク機器 --RADIUS 1812/udp--> FreeRADIUS --LDAPS 636/tcp--> OpenLDAP
ネットワーク機器 --SYSLOG 514/udp,tcp--> syslog-ng
ネットワーク機器 <--TFTP 69/udp--> tftpd-hpa
```

設定値（ドメイン、パスワード、コンテナ名など）は `.env` に集約し、証明書・LDIF・FreeRADIUS の LDAP モジュール設定はスクリプトで `.env` から生成する。

---

## 3. コンポーネント選定理由

### 3.1 OpenLDAP（ID管理）

**選定理由:**

- Raspberry Pi 5 でも軽量に動作する。
- Docker イメージが成熟している（`osixia/openldap`）。
- FreeRADIUS との連携が容易（`rlm_ldap`）。
- ロール管理を **memberOf（グループ）** で表現できる。
- 将来 Kerberos を導入する際にも自然に統合可能。
- 389 Directory Server は大規模・Red Hat 系向けで Pi には過剰。

**採用方針:**

- `ou=People` にユーザ。
- `ou=Roles` にロール（admin/operator/readonly）。
- 認証は当面 LDAP、将来 Kerberos へ拡張可能。
- 認可（権限）は RADIUS 側で決定。
- 接続は LDAPS（636）のみを公開し、平文の 389 は公開しない。

---

### 3.2 FreeRADIUS 4.x（認証・認可）

**選定理由:**

- LDAP の `memberOf` を参照してロール判定が可能。
- Cisco / Aruba / Allied などの VSA（Vendor-Specific Attribute）返却が容易。
- `unlang` で柔軟にポリシーを記述できる。
- Docker イメージが豊富で Pi 5 上でも十分軽量。
- 現時点で v4.x は、開発バージョンだが、複雑な機能を使う予定は無いため、正式リリースに先行して選定する。

**採用方針:**

- **機器種別 × ロール → 応答属性** を基本モデルとする（5 節）。
- 機器種別は、RADIUS クライアント定義（`clients.conf`）の `nas_type` で指定する。  
  Access-Request からは機器メーカーを確実には判定できないため、初版の「Vendor-ID による判定」から変更した。
- イメージ標準の設定をそのまま使い、Koitohan として書いた設定だけを読み取り専用で重ねる。

---

### 3.3 tftpd-hpa（TFTP）【実装予定】

**選定理由:**

- 軽量で Raspberry Pi に適する。
- ネットワーク機器のファームウェア配布やコンフィグ upload/download に適した実装。
- Docker イメージが安定している。

**採用方針:**

- `/tftpboot` をホスト側ストレージに永続化。
- ファームウェア配布用ディレクトリとコンフィグバックアップ用ディレクトリを階層分け。
- PXE ブート環境は DHCP が前提となるため、10 節の判断に従う。

---

### 3.4 syslog-ng（ログ管理）

**選定理由:**

- ホスト別ログの分離が容易（フィルタ機能が強力）。
- ログローテーション・圧縮・長期保存の運用設計がしやすい。
- Docker イメージが安定しており、Pi 5 の NVMe と組み合わせて 3年保持が現実的。

**採用方針:**

- UDP/TCP 514 を開放し、ネットワーク機器からの SYSLOG を受信。
- ホスト名（または IP）ごとにログファイルを分割。
- 日次ローテーション＋圧縮＋3年間保持を基本ポリシーとする。
- ストレージは NVMe 256〜512GB を想定。

---

## 4. LDAP ディレクトリ構造（基本設計）

```text
dc=example,dc=com
 ├── ou=People
 │     ├── uid=admin01
 │     ├── uid=operator01
 │     └── uid=readonly01
 ├── ou=Roles
 │     ├── cn=admin
 │     ├── cn=operator
 │     └── cn=readonly
 └── ou=ServiceAccounts
        └── uid=radius
```

サフィックスは `.env` の `LDAP_DOMAIN` から決まる（`example.com` → `dc=example,dc=com`）。  
`admin01` / `operator01` / `readonly01` は検証用のテストアカウントであり、標準の構築手順には含めない。

### 4.1 ロール

ロールは `ou=Roles` 直下の `groupOfUniqueNames` で表現し、ユーザの所属は memberOf オーバーレイにより `memberOf` 属性として参照する。

```text
uid=admin01
memberOf: cn=admin,ou=Roles,dc=example,dc=com
```

ロールはベンダーに依存しない。ベンダーごとの権限への読み替えは FreeRADIUS が行う（5 節）。

### 4.2 ServiceAccounts OU

サービスアカウント専用 OU を設け、  
アプリケーション・ミドルウェアが利用する認証情報を People OU と分離する。

### 4.3 ServiceAccounts OU の ACL 設計

ou=ServiceAccounts 以下のアカウントには、次の権限を付与する：

- dc=example,dc=com に対する read 権限
- ただし userPassword 属性は除外（先行する ACL により、本人・管理者以外は読み取り禁止）

これにより、FreeRADIUS はユーザ情報（uid、memberOf など）を参照できるが、
パスワード値そのものを読み取ることはできない。

### 4.4 FreeRADIUS 用サービスアカウント uid=radius

FreeRADIUS が LDAP に対して検索・bind を行うための専用アカウント。

- DN: uid=radius,ou=ServiceAccounts,dc=example,dc=com
- 認証方式: simple bind
- パスワード保存形式: SSHA
- 権限: 4.3 節のとおり

FreeRADIUS はこのアカウントを用いて：

- ユーザ DN の検索
- memberOf の取得

を行う。ユーザの認証は、検索で得た DN とユーザが入力したパスワードで bind して行う。

### 4.5 TLS

LDAP の通信はプライベート CA による TLS で保護する。

- プライベート CA を構築時に作成する。
- OpenLDAP にサーバ証明書を発行する（SAN はコンテナ名、FQDN、localhost）。
- FreeRADIUS にクライアント証明書を発行する。
- 証明書の名前はコンテナ名から決まるため、コンテナ名を変えたら証明書を作り直す。

証明書はこのスタックのコンテナ間でのみ使用し、外部には配布しない。そのため、再構築時は CA ごと作り直してよい。

### 4.6 初期投入

OU、ロール、サービスアカウント、ACL は LDIF として生成し、OpenLDAP の初回起動時（データベースが空のとき）に投入する。  
投入内容を変更して再投入するには、永続化したデータベースを削除する必要がある。

---

## 5. FreeRADIUS ポリシー（基本設計）

FreeRADIUS 4.x は構成ファイルの構造が 3.x と異なるため、設定は 4.x の公式ドキュメントに基づいて作成する。

### 5.1 認証の流れ

仮想サーバ `ldap-pap` が 1812/udp で Access-Request を受け付ける。

1. サービスアカウントで LDAP を検索し、ユーザの DN と `memberOf` を取得する。
2. ユーザの DN と入力されたパスワードで LDAP に bind し、成功すれば認証成功とする。
3. `clients.conf` の `nas_type` と、ユーザのロールから、応答属性を決定する（ポリシー `authz_vendor_role`）。

パスワードは PAP で受け取る。LDAP 側のハッシュを FreeRADIUS が読み取る方式は採らない。

受け付ける送信元はプライベートアドレス（10/8、172.16/12、192.168/16）とループバックに限定する。

### 5.2 機器種別（nas_type）

`nas_type` は大文字小文字を区別せず、前方一致で機器種別に正規化する。

| 機器種別     | `nas_type` の値           | 返す属性                     |
| ------------ | ------------------------- | ---------------------------- |
| Cisco        | `cisco`                   | `Cisco-AVPair`               |
| ArubaCX      | `aruba-cx`                | `Aruba-Priv-Admin-User`      |
| ArubaAP      | `aruba-ap`                | なし                         |
| Fortinet     | `fortinet`、`fortigate`   | `Fortinet-Group-Name`        |
| Juniper      | `juniper`                 | `Juniper-Local-User-Name`    |
| PaloAlto     | `palo-alto`               | `PaloAlto-Admin-Role`        |
| Service-Type | `service-type`、`rfc2865` | `Service-Type`               |
| IETF-MPL     | `ietf-mpl`、`allied`      | `Management-Privilege-Level` |
| Nothing      | `nothing`、`no`、`none`   | なし                         |

上記のどれにも当てはまらない値は IETF-MPL として扱い、`Reply-Message` で不明な `nas_type` であることを通知する。

### 5.3 ロールと応答属性の対応

| 機器種別     | admin                 | operator           | readonly           |
| ------------ | --------------------- | ------------------ | ------------------ |
| Cisco        | `shell:priv-lvl=15`   | `shell:priv-lvl=7` | `shell:priv-lvl=1` |
| ArubaCX      | 15                    | 7                  | 1                  |
| ArubaAP      | 許可（属性なし）      | 拒否               | 拒否               |
| Fortinet     | `super_admin`         | `readonly`         | `readonly`         |
| Juniper      | `superuser`           | `operator`         | `read-only`        |
| PaloAlto     | `superuser`           | `readonly`         | `readonly`         |
| Service-Type | `Administrative-User` | `NAS-Prompt-User`  | `Login-User`       |
| IETF-MPL     | 15                    | 7                  | 1                  |
| Nothing      | 許可（属性なし）      | 許可（属性なし）   | 許可（属性なし）   |

Fortinet、Juniper、Palo Alto の値は機器側に定義されたプロファイル名・ユーザ名であり、機器側の設定と一致させる必要がある。

`ou=Roles` 直下にない、または未定義のロールは `Management-Privilege-Level = 1` として扱い、`Reply-Message` で通知する。

### 5.4 ベンダーの追加

新しいベンダーに対応するときは、次の3か所を揃える。

- 辞書（`Koitohan.dict`）の機器種別
- `nas_type` の正規化ルール
- 各ロールの応答属性

### 5.5 設定ファイルの区分

| 区分     | ファイル                                               | 扱い                                |
| -------- | ------------------------------------------------------ | ----------------------------------- |
| 共通     | 辞書、ポリシー、仮想サーバ、有効化するモジュールの一覧 | リポジトリで管理する                |
| 環境ごと | `clients.conf`                                         | 利用者が書く。サンプルのみ管理する  |
| 生成     | LDAP モジュール設定                                    | `.env` から生成する。直接編集しない |

### 5.6 課題

- **ロール未所属のユーザ**: LDAP の認証に成功すれば、応答属性なしで許可される。拒否するかどうかを決める必要がある。
- **複数ロールに所属するユーザ**: 優先順位を定義していない。現状は `memberOf` の並び順で後のロールが有効になる。
- **アカウンティング**: 1813/udp を公開しているが、受け付ける仮想サーバは未定義。

---

## 6. ログポリシー（基本設計）

### 6.1 syslog-ng

ネットワーク機器からのログは、

```
/var/log/Hosts/<host>/<host>.log
```

に置く（ホスト側では `syslog-ng/log/Hosts/<host>/<host>.log`）。

日次ローテーション×3年間の場合、一つのネットワーク機器に対して、約1100ファイルが作成されることになる。複数のネットワーク機器のログファイルを一つのディレクトリに保存すると、数万のファイルを一つのディレクトリに置くことになる可能性がある。この場合、

- `ls` が遅い
- `rm` が遅い
- logrotate の glob が重くなる
- 運用上の視認性が悪い

という問題が出る。

これらの問題を避けるため、ネットワーク機器毎にディレクトリを分けるものとする。

ログファイルの所有者は、コンテナの実行ユーザ（uid/gid 1000）とする。

**syslog-ng の設定**

```
destination d_host_logs {
    file("/var/log/Hosts/${HOST}/${HOST}.log"
         create-dirs(yes)
         owner(1000)
         group(1000)
         perm(0644));
};
```

コンテナ内では 1514（udp/tcp）で待ち受け、ホストの 514 として公開する。  
送信元が名乗るホスト名をそのまま `${HOST}` として使う（`keep-hostname(yes)`）。

**デバッグログ**

検証段階では、受信した生メッセージとホスト系マクロを `/var/log/debug.log` にも記録する。  
全機器のログが1ファイルに集まり続けるため、6.2 節のローテーション対象に含めるか、検証完了時に出力を止める。

### 6.2 ログローテーション【実装予定】

ログのローテーションは、Docker ホスト側で行う。

- Dockerコンテナには、cron/systemd が組み込まれていない事が多い。
- コンテナを軽量化できる
- コンテナの再起動や再デプロイに影響されない
- ホスト側の cron/systemd-timer が使える

日次ローテーション・日付に基づいた拡張子を使用する。

syslog-ng はログファイルを開いたまま書き込むため、ローテーション後にファイルの再オープンを指示する。再オープン時に syslog-ng が新しいファイルを作成するので、logrotate 側では作成しない。

**logrotate の設定例**

```
/srv/docker/syslog-ng/log/Hosts/*/*.log {
    daily
    dateext
    dateformat -%Y-%m-%d
    rotate 1096
    compress
    delaycompress
    missingok
    notifempty
    nocreate
    sharedscripts
    postrotate
        docker exec syslog-ng syslog-ng-ctl reopen --control=/config/syslog-ng.ctl
    endscript
}
```

`rotate 1096` は3年分にあたる。`delaycompress` は、再オープンまでの間に書き込まれる直前のファイルを圧縮しないために指定する。

FreeRADIUS の認証ログ（`freeradius/log/`）も同じ仕組みでローテーションする。

---

## 7. Docker Compose 構成方針

### コンテナ一覧

| コンテナ     | イメージ                | 公開ポート         | 状況     |
| ------------ | ----------------------- | ------------------ | -------- |
| `openldap`   | `osixia/openldap`       | 636/tcp            | 実装済み |
| `freeradius` | `freeradius/rocky10`    | 1812/udp、1813/udp | 実装済み |
| `syslog-ng`  | `linuxserver/syslog-ng` | 514/udp、514/tcp   | 実装済み |
| `tftpd-hpa`  | 未選定                  | 69/udp             | 実装予定 |

コンテナ名は `.env` で指定する。

### ネットワーク

コンテナは Compose のデフォルトネットワーク（ブリッジ）1つに接続し、互いをコンテナ名で解決する。  
サブネットは `.env` の `DOCKER_SUBNET` で指定する。Docker に自動で割り当てさせると、管理対象のネットワークと重なる範囲が選ばれることがあるためである。  
コンテナごとの IP アドレスは固定しない。

### 永続化対象

- LDAP データベースと LDAP の設定（`slapd.d`）
- FreeRADIUS のログ
- SYSLOG ログディレクトリ（NVMe）
- TFTP ディレクトリ（`/tftpboot`）【実装予定】

FreeRADIUS の設定と証明書は永続化対象ではなく、ホスト側のファイルを読み取り専用でマウントする。

### 課題

- `freeradius` と `syslog-ng` のイメージは `latest` を参照している。再現性のため、バージョンを固定する。

---

## 8. Raspberry Pi 5 リソース設計

- **CPU:** 全サービス軽量のため余裕あり。RADIUS / LDAP は CPU負荷ほぼゼロ、SYSLOG がログ量に応じて多少負荷。
- **メモリ:** 4GB で十分、8GB なら余裕。
- **ストレージ:** NVMe 256〜512GB を推奨（SYSLOG 3年保持を考慮）。

---

## 9. フォルダ構成

```text
/srv/docker/
  ├── compose.yaml
  ├── Makefile
  ├── .env                 ← 唯一の設定元
  ├── scripts/             ← 証明書・LDIF・設定の生成スクリプト
  ├── CA/                  ← 生成した CA と証明書
  ├── docs/
  ├── openldap/
  ├── freeradius/
  ├── syslog-ng/
  └── tftpboot/            ← 実装予定
```

---

## 10. 未決定事項: DHCP と DNS

Kea DHCP と BIND9 を追加するかどうかは未決定である。

**論点:**

- DHCP と DNS を提供するには、ネットワーク機器の台帳（MAC アドレス、IP アドレス、ホスト名など）が必要になる。
- 台帳のために別のデータベースを配置するのは、本プロダクトの規模に対して重い。
- 既にある LDAP に機器情報を置けば、データベースを追加せずに済む。

**検討メモ:**

- 機器の IP アドレス、共有シークレット、機器種別は、既に `clients.conf` に書いている。LDAP に台帳を置く場合、`clients.conf` がその最初の利用者になる。
- Kea と BIND9 は LDAP を直接は参照できない見込みであり、LDAP から設定ファイルを生成して反映する仕組みが必要になる。これは `.env` から設定を生成する現在の方式の延長にあたる。
- TFTP とログローテーションは台帳に依存しないため、この判断を待たずに実装できる。

---

## 11. 将来拡張

- 冗長化による可用性の向上
  - Raspberry Pi 5 複数台によるクラスタ化。
  - FreeRADIUS 冗長化（複数 Pi 間で構成共有）。
  - syslog-ng → 外部ログ基盤／SIEM 連携。
- Kerberos 認証（LDAP＋FreeRADIUS＋SSSD）。
- DHCP と DNS を採用した場合は、Kea DHCP の HA 構成と BIND9 セカンダリによる冗長化。

---

## 12. まとめ

本設計は、  
**「ネットワーク機器管理バックエンドを Raspberry Pi 5 上に構築する」**  
という目的に対して、機能・拡張性・保守性のバランスを取った構成である。

- OpenLDAP → 軽量でロール管理に適した ID 基盤。
- FreeRADIUS → 機器種別 × ロールによる柔軟な認可モデル。
- syslog-ng → 長期ログ保持とホスト別管理に強いログ基盤。
- tftpd-hpa → ファームウェア・コンフィグ配布に適した TFTP。

認証・認可とログ収集は実装済みであり、TFTP とログローテーションを次に実装する。DHCP と DNS は、機器台帳の持ち方とあわせて判断する。
