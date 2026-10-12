#!/bin/sh
set -eu

RUN_DIR=/run/koitohan
CERT_DIR=/etc/koitohan/certs
NSLCD_CERT_DIR="${RUN_DIR}/nslcd-certs"

LDAP_SUFFIX="dc=$(echo "${LDAP_DOMAIN}" | sed 's/\./,dc=/g')"

# sshd、nslcd、PAM は syslog にしか出力しないので、コンテナの標準出力へ流す
# musl の syslog() は時刻を UTC で付けるので、-t で捨てて syslogd に TZ の時刻を付け直させる
syslogd -n -t -O - &

# LDAP のユーザは、あとで koitohan-update-users が足す
mkdir -p "${RUN_DIR}"
cp /etc/passwd.base "${RUN_DIR}/passwd"
cp /etc/group.base "${RUN_DIR}/group"

# nslcd は降格したあとで証明書と秘密鍵を読む。マウント元は root しか入れないので、専用のディレクトリへ写す
install -d -m 700 -o nslcd -g nslcd "${NSLCD_CERT_DIR}"
install -m 400 -o nslcd -g nslcd \
  "${CERT_DIR}/ca.crt" "${CERT_DIR}/client.crt" "${CERT_DIR}/client.key" "${NSLCD_CERT_DIR}/"

# bind 用のパスワードは、環境変数ではなくファイルで受け取る(docker inspect に出さないため)
# ldapsearch の -y は改行もパスワードに含めるので、改行を付けない
SERVICE_ACCOUNT_PASSWORD=$(cat /etc/koitohan/secrets/bindpw)
if [ -z "${SERVICE_ACCOUNT_PASSWORD}" ]; then
  echo 'the password of the service account is empty' >&2
  exit 1
fi
(umask 077; printf '%s' "${SERVICE_ACCOUNT_PASSWORD}" > "${RUN_DIR}/bindpw")

(umask 077; cat <<EOF > "${RUN_DIR}/nslcd.conf")
uid nslcd
gid nslcd

uri ${LDAP_URI}
base ou=People,${LDAP_SUFFIX}
binddn uid=${SERVICE_ACCOUNT_NAME},ou=ServiceAccounts,${LDAP_SUFFIX}
bindpw ${SERVICE_ACCOUNT_PASSWORD}

tls_reqcert demand
tls_cacertfile ${NSLCD_CERT_DIR}/ca.crt
tls_cert ${NSLCD_CERT_DIR}/client.crt
tls_key ${NSLCD_CERT_DIR}/client.key

filter passwd (objectClass=posixAccount)
nss_min_uid 10000
EOF

echo "min=${PASSWDQC_MIN}" > "${RUN_DIR}/passwdqc.conf"
# 設定の誤りは標準エラーに出る。判定の結果(標準出力)は見ない
PASSWDQC_ERROR=$(echo | pwqcheck -1 config=/etc/passwdqc.conf 2>&1 > /dev/null || true)
if [ -n "${PASSWDQC_ERROR}" ]; then
  echo "PASSWDQC_MIN is not valid: ${PASSWDQC_ERROR}" >&2
  exit 1
fi

# OpenLDAP は、初回起動では初期投入が終わるまで応答しない
TRY=0
until koitohan-update-users; do
  TRY=$((TRY + 1))
  if [ ${TRY} -ge 30 ]; then
    echo 'could not read the users from LDAP' >&2
    exit 1
  fi
  sleep 3
done

# passwd は、ユーザの権限のまま nslcd のソケットにつなぐ
install -d -m 755 -o nslcd -g nslcd /run/nslcd
nslcd -n &
/usr/sbin/sshd.pam -D &

# どちらかが終了したらコンテナごと止め、Docker に起動し直させる
trap 'exit 0' TERM INT
wait -n
exit 1
