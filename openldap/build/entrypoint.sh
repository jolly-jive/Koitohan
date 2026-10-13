#!/bin/sh
set -eu

CONF_DIR=/etc/openldap/slapd.d
DATA_DIR=/var/lib/openldap/openldap-data
SOCKET_DIR=/var/lib/openldap/run
RUN_DIR=/run/koitohan
CERT_DIR=/etc/koitohan/certs
SLAPD_CERT_DIR="${RUN_DIR}/certs"
SEED_DIR=/etc/koitohan/ldif
SECRETS_DIR=/etc/koitohan/secrets

# 初期投入が最後まで済んだ目印。途中で止まった設定とデータで待ち受けないために置く
SEEDED="${CONF_DIR}/koitohan-seeded"

if [ -z "${LDAP_DOMAIN:-}" ]; then
  echo 'LDAP_DOMAIN is empty' >&2
  exit 1
fi
LDAP_SUFFIX="dc=$(echo "${LDAP_DOMAIN}" | sed 's/\./,dc=/g')"

# slappasswd の -T は改行もパスワードに含めるので、ファイルには改行を付けない
for WHICH in admin config; do
  if [ ! -s "${SECRETS_DIR}/ldap_${WHICH}_password" ]; then
    echo "the password of the administrator (${WHICH}) is missing or empty" >&2
    exit 1
  fi
done

# slapd は syslog に出力するので、コンテナの標準出力へ流す(-d で標準エラーに出すと、時刻が 16 進数になる)
# musl の syslog() は時刻を UTC で付けるので、-t で捨てて syslogd に TZ の時刻を付け直させる
syslogd -n -t -O - &

# slapd は降格したあとで証明書と秘密鍵を読む。マウント元は root しか入れないので、専用のディレクトリへ写す
install -d -m 700 -o ldap -g ldap "${SLAPD_CERT_DIR}"
install -m 400 -o ldap -g ldap \
  "${CERT_DIR}/ca.crt" "${CERT_DIR}/ldap.crt" "${CERT_DIR}/ldap.key" "${CERT_DIR}/dhparam.pem" "${SLAPD_CERT_DIR}/"

chown ldap:ldap "${SOCKET_DIR}"

if [ ! -e "${SEEDED}" ]; then
  # 目印がないのに中身があるのは、途中で止まった初期投入か、別のイメージが作ったもの
  # どちらも続きからは使えない。消すかどうかは、こいとはん管理者が決める
  if [ -e "${CONF_DIR}/cn=config.ldif" ] || [ -e "${DATA_DIR}/data.mdb" ]; then
    echo 'openldap/config or openldap/data holds a directory that this image did not finish making.' >&2
    echo 'Delete what is in both (everything in the directory is lost), then start again.' >&2
    exit 1
  fi

  echo 'seeding the empty directory'

  # 待ち受けは ldaps:/// と ldapi:/// だけにする(389 は開けない)
  # クライアント証明書を必ず求め、TLS は 1.2 以上に限る
  slapadd -n 0 -F "${CONF_DIR}" <<EOF
dn: cn=config
objectClass: olcGlobal
cn: config
olcArgsFile: ${SOCKET_DIR}/slapd.args
olcPidFile: ${SOCKET_DIR}/slapd.pid
olcLocalSSF: 128
olcSecurity: ssf=128
olcTLSCACertificateFile: ${SLAPD_CERT_DIR}/ca.crt
olcTLSCertificateFile: ${SLAPD_CERT_DIR}/ldap.crt
olcTLSCertificateKeyFile: ${SLAPD_CERT_DIR}/ldap.key
olcTLSDHParamFile: ${SLAPD_CERT_DIR}/dhparam.pem
olcTLSProtocolMin: 3.3
olcTLSVerifyClient: demand

dn: cn=module{0},cn=config
objectClass: olcModuleList
cn: module{0}
olcModulePath: /usr/lib/openldap
olcModuleLoad: back_mdb
olcModuleLoad: memberof
olcModuleLoad: refint

dn: cn=schema,cn=config
objectClass: olcSchemaConfig
cn: schema

include: file:///etc/openldap/schema/core.ldif
include: file:///etc/openldap/schema/cosine.ldif
include: file:///etc/openldap/schema/inetorgperson.ldif
include: file:///etc/openldap/schema/nis.ldif

dn: olcDatabase={-1}frontend,cn=config
objectClass: olcDatabaseConfig
objectClass: olcFrontendConfig
olcDatabase: {-1}frontend
olcAccess: {0}to * by dn.exact=gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth manage by * break
olcAccess: {1}to dn.exact="" by * read
olcAccess: {2}to dn.base="cn=Subschema" by * read
olcSizeLimit: 500

dn: olcDatabase={0}config,cn=config
objectClass: olcDatabaseConfig
olcDatabase: {0}config
olcAccess: {0}to * by dn.exact=gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth manage by * break
olcRootDN: cn=admin,cn=config

dn: olcDatabase={1}mdb,cn=config
objectClass: olcDatabaseConfig
objectClass: olcMdbConfig
olcDatabase: {1}mdb
olcDbDirectory: ${DATA_DIR}
olcSuffix: ${LDAP_SUFFIX}
olcRootDN: cn=admin,${LDAP_SUFFIX}
olcAccess: {0}to * by dn.exact=gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth manage by * break
olcDbCheckpoint: 512 30
olcDbIndex: objectClass eq
olcDbIndex: uid eq
olcDbIndex: memberOf eq
olcDbIndex: entryCSN eq
olcDbIndex: entryUUID eq
olcDbMaxSize: 1073741824

dn: olcOverlay={0}memberof,olcDatabase={1}mdb,cn=config
objectClass: olcOverlayConfig
objectClass: olcMemberOf
olcOverlay: {0}memberof
olcMemberOfDangling: ignore
olcMemberOfRefInt: TRUE
olcMemberOfGroupOC: groupOfUniqueNames
olcMemberOfMemberAD: uniqueMember
olcMemberOfMemberOfAD: memberOf

dn: olcOverlay={1}refint,olcDatabase={1}mdb,cn=config
objectClass: olcOverlayConfig
objectClass: olcRefintConfig
olcOverlay: {1}refint
olcRefintAttribute: owner
olcRefintAttribute: manager
olcRefintAttribute: uniqueMember
olcRefintAttribute: member
olcRefintAttribute: memberOf
EOF

  slapadd -n 1 -F "${CONF_DIR}" <<EOF
dn: ${LDAP_SUFFIX}
objectClass: top
objectClass: dcObject
objectClass: organization
o: ${LDAP_ORGANISATION:-${LDAP_DOMAIN}}
dc: ${LDAP_DOMAIN%%.*}
EOF

  chown -R ldap:ldap "${CONF_DIR}" "${DATA_DIR}"

  # LDIF はソケットだけで待ち受ける slapd に入れる。投入の途中のディレクトリには、外から届かない
  slapd -u ldap -g ldap -F "${CONF_DIR}" -h 'ldapi:///' -d 0 &
  SEED_PID=$!
  TRY=0
  until ldapwhoami -Q -Y EXTERNAL -H ldapi:/// > /dev/null 2>&1; do
    TRY=$((TRY + 1))
    if [ ${TRY} -ge 100 ] || ! kill -0 ${SEED_PID} 2> /dev/null; then
      echo 'slapd did not start for the seed' >&2
      exit 1
    fi
    sleep 0.1
  done

  # ファイル名の順に入れる。1つでも失敗したら起動しない(欠けたディレクトリで待ち受けない)
  for LDIF in "${SEED_DIR}"/*.ldif; do
    echo "seeding ${LDIF}"
    if ! ldapadd -Q -Y EXTERNAL -H ldapi:/// -f "${LDIF}"; then
      echo "could not load ${LDIF}" >&2
      kill ${SEED_PID}
      wait ${SEED_PID} || true
      # いま空から作ったものなので、消して次の起動でやり直せるようにする
      rm -rf "${CONF_DIR}/cn=config" "${CONF_DIR}/cn=config.ldif" "${DATA_DIR}/data.mdb" "${DATA_DIR}/lock.mdb"
      exit 1
    fi
  done

  kill ${SEED_PID}
  wait ${SEED_PID} || true
  touch "${SEEDED}"
  echo 'seeded'
fi

# 管理者のパスワードとログのレベルは、起動のたびに入れ直す。正はファイルと環境変数にある
slapmodify -n 0 -F "${CONF_DIR}" <<EOF
dn: cn=config
changetype: modify
replace: olcLogLevel
olcLogLevel: ${LDAP_LOG_LEVEL:-stats}

dn: olcDatabase={0}config,cn=config
changetype: modify
replace: olcRootPW
olcRootPW: $(slappasswd -T "${SECRETS_DIR}/ldap_config_password")

dn: olcDatabase={1}mdb,cn=config
changetype: modify
replace: olcRootPW
olcRootPW: $(slappasswd -T "${SECRETS_DIR}/ldap_admin_password")
EOF

# slapmodify は root で書くので、slapd が読み書きできるように戻す
chown -R ldap:ldap "${CONF_DIR}" "${DATA_DIR}"

exec slapd -u ldap -g ldap -F "${CONF_DIR}" -h 'ldaps:/// ldapi:///' -d 0
