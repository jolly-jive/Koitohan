FROM alpine:3.24

# パッケージの slapd.conf と slapd.ldif は使わない。設定は entrypoint.sh が slapd.d に作る
RUN apk add --no-cache \
      openldap \
      openldap-back-mdb \
      openldap-clients \
      openldap-overlay-memberof \
      openldap-overlay-ppolicy \
      openldap-overlay-refint \
      tzdata \
 && rm -f /etc/openldap/slapd.conf /etc/openldap/slapd.ldif

COPY entrypoint.sh /entrypoint.sh

# ルートファイルシステムは読み取り専用で使う。起動時に書くものは、マウントされた
# 設定(/etc/openldap/slapd.d)とデータ(/var/lib/openldap/openldap-data)、tmpfs の
# /run と /var/lib/openldap/run(ldapi:/// のソケット。場所はパッケージのビルドで決まっている)
# /etc/koitohan は証明書、初期投入の LDIF、管理者のパスワードのマウント先で、root しか入れない
RUN mkdir -m 700 /etc/koitohan \
 && mkdir /etc/koitohan/certs /etc/koitohan/ldif /etc/koitohan/secrets \
 && mkdir -p /etc/openldap/slapd.d /var/lib/openldap/openldap-data /var/lib/openldap/run

EXPOSE 636/tcp

ENTRYPOINT ["/entrypoint.sh"]
