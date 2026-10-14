#!/bin/sh
set -eu

# A limit in the config of sshd would turn the client away only after it
# has tried to authenticate, so the packets are dropped by a filter before
# that. Without the filter the container does not start (it does not
# listen without the limit).
if [ "${1:-}" != filtered ]; then
  networks=$(printf '%s' "${OPENSSH_ALLOWED_NETWORKS:-}" | tr -s ' \t\n' ',,,' | sed 's/^,//; s/,$//')
  if [ -z "$networks" ]; then
    echo "OPENSSH_ALLOWED_NETWORKS is empty" >&2
    exit 1
  fi
  if ! printf '%s' "$networks" | grep -Eq '^[0-9./,]+$'; then
    echo "OPENSSH_ALLOWED_NETWORKS must be IPv4 addresses or prefixes separated by spaces: $OPENSSH_ALLOWED_NETWORKS" >&2
    exit 1
  fi

  # the replies from OpenLDAP pass as established, and the embedded DNS of
  # Docker as loopback. The table is inet, so this drops IPv6 as well.
  nft -f - <<EOF
table inet koitohan {
	chain input {
		type filter hook input priority filter; policy drop;
		iif "lo" accept
		ct state established,related accept
		ip saddr { $networks } tcp dport 22 accept
	}
}
EOF

  # Nothing from here on keeps NET_ADMIN. sshd and nslcd start as root and
  # could change the rules otherwise. Starting this script again drops it
  # from every process that follows.
  # The setpriv of busybox has no --bounding-set; this is the one of
  # util-linux.
  exec setpriv --bounding-set -net_admin "$0" filtered
fi

RUN_DIR=/run/koitohan
CERT_DIR=/etc/koitohan/certs
NSLCD_CERT_DIR="${RUN_DIR}/nslcd-certs"

LDAP_SUFFIX="dc=$(echo "${LDAP_DOMAIN}" | sed 's/\./,dc=/g')"

# sshd, nslcd and PAM write to syslog only, so pass it on to the stdout of
# the container. The syslog() of musl stamps the time in UTC; -t drops it,
# and syslogd stamps it again in TZ.
syslogd -n -t -O - &

# koitohan-update-users adds the users of LDAP later
mkdir -p "${RUN_DIR}"
cp /etc/passwd.base "${RUN_DIR}/passwd"
cp /etc/group.base "${RUN_DIR}/group"

# nslcd reads the certificate and the key after it drops root. Only root
# can enter where they are mounted, so copy them into a directory of its own.
install -d -m 700 -o nslcd -g nslcd "${NSLCD_CERT_DIR}"
install -m 400 -o nslcd -g nslcd \
  "${CERT_DIR}/ca.crt" "${CERT_DIR}/client.crt" "${CERT_DIR}/client.key" "${NSLCD_CERT_DIR}/"

# The password to bind with comes in a file, not in the environment, so
# that docker inspect does not show it. The -y of ldapsearch takes a newline
# as part of the password, so none is written.
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
# an error in the config goes to stderr. The verdict (stdout) is ignored.
PASSWDQC_ERROR=$(echo | pwqcheck -1 config=/etc/passwdqc.conf 2>&1 > /dev/null || true)
if [ -n "${PASSWDQC_ERROR}" ]; then
  echo "PASSWDQC_MIN is not valid: ${PASSWDQC_ERROR}" >&2
  exit 1
fi

# on its first start OpenLDAP does not answer until the seed is done
TRY=0
until koitohan-update-users; do
  TRY=$((TRY + 1))
  if [ ${TRY} -ge 30 ]; then
    echo 'could not read the users from LDAP' >&2
    exit 1
  fi
  sleep 3
done

# passwd connects to the socket of nslcd as the user
install -d -m 755 -o nslcd -g nslcd /run/nslcd
nslcd -n &
/usr/sbin/sshd.pam -D &

# when either one exits, stop the container and let Docker start it again
trap 'exit 0' TERM INT
wait -n
exit 1
