#!/bin/sh
set -eu

# LDAPS is published on the Docker host, and outside the host only the
# addresses in OPENLDAP_ALLOWED_NETWORKS reach it: the other host of a
# pair, or none (the default, for a single host). FreeRADIUS and OpenSSH
# come from the networks of the container, which are always let in.
# Without the filter the container does not start (it does not listen
# without the limit).
if [ "${1:-}" != filtered ]; then
  words=0
  none=''
  # a word must not expand as a pattern of file names
  set -f
  for word in ${OPENLDAP_ALLOWED_NETWORKS:-}; do
    words=$((words + 1))
    [ "$word" = none ] && none=yes
  done
  set +f
  if [ "$words" -eq 0 ]; then
    echo "OPENLDAP_ALLOWED_NETWORKS is empty" >&2
    exit 1
  fi
  if [ -n "$none" ]; then
    if [ "$words" -gt 1 ]; then
      echo "OPENLDAP_ALLOWED_NETWORKS must be none, or IPv4 addresses or prefixes separated by spaces: $OPENLDAP_ALLOWED_NETWORKS" >&2
      exit 1
    fi
    networks=''
  else
    networks=$(printf '%s' "$OPENLDAP_ALLOWED_NETWORKS" | tr -s ' \t\n' ',,,' | sed 's/^,//; s/,$//')
    if ! printf '%s' "$networks" | grep -Eq '^[0-9./,]+$'; then
      echo "OPENLDAP_ALLOWED_NETWORKS must be none, or IPv4 addresses or prefixes separated by spaces: $OPENLDAP_ALLOWED_NETWORKS" >&2
      exit 1
    fi
  fi

  # the subnets that Docker gave the networks of the container (the
  # default one and the one of openssh), so that no address need be fixed.
  # What the Docker host itself sends comes from the gateway of one of
  # them.
  subnets=$(ip -4 route show scope link | awk '{ print $1 }' | paste -s -d , -)
  if [ -z "$subnets" ]; then
    echo 'the container has no network for FreeRADIUS and OpenSSH to come from' >&2
    exit 1
  fi

  # ldapi:/// is a socket, not on the network. The table is inet, so this
  # drops IPv6 as well.
  nft -f - <<EOF
table inet koitohan {
	chain input {
		type filter hook input priority filter; policy drop;
		iif "lo" accept
		ct state established,related accept
		ip saddr { ${subnets}${networks:+,$networks} } tcp dport 636 accept
	}
}
EOF

  # Nothing from here on keeps NET_ADMIN. slapd starts as root, and could
  # change the rules otherwise. Starting this script again drops it from
  # every process that follows.
  # The setpriv of busybox has no --bounding-set; this is the one of
  # util-linux.
  exec setpriv --bounding-set -net_admin "$0" filtered
fi

CONF_DIR=/etc/openldap/slapd.d
DATA_DIR=/var/lib/openldap/openldap-data
SOCKET_DIR=/var/lib/openldap/run
RUN_DIR=/run/koitohan
CERT_DIR=/etc/koitohan/certs
SLAPD_CERT_DIR="${RUN_DIR}/certs"
SEED_DIR=/etc/koitohan/ldif
SECRETS_DIR=/etc/koitohan/secrets

# marks a seed that ran to the end, so that slapd does not serve a config
# and data that were left halfway
SEEDED="${CONF_DIR}/koitohan-seeded"

if [ -z "${LDAP_DOMAIN:-}" ]; then
  echo 'LDAP_DOMAIN is empty' >&2
  exit 1
fi
LDAP_SUFFIX="dc=$(echo "${LDAP_DOMAIN}" | sed 's/\./,dc=/g')"

# the -T of slappasswd takes a newline as part of the password, so the
# files have none
for WHICH in admin config; do
  if [ ! -s "${SECRETS_DIR}/ldap_${WHICH}_password" ]; then
    echo "the password of the administrator (${WHICH}) is missing or empty" >&2
    exit 1
  fi
done

# slapd writes to syslog, so pass it on to the stdout of the container
# (with -d it writes to stderr, but stamps the time in hexadecimal).
# The syslog() of musl stamps the time in UTC; -t drops it, and syslogd
# stamps it again in TZ.
syslogd -n -t -O - &

# slapd reads the certificate and the key after it drops root. Only root
# can enter where they are mounted, so copy them into a directory of its own.
install -d -m 700 -o ldap -g ldap "${SLAPD_CERT_DIR}"
install -m 400 -o ldap -g ldap \
  "${CERT_DIR}/ca.crt" "${CERT_DIR}/ldap.crt" "${CERT_DIR}/ldap.key" "${SLAPD_CERT_DIR}/"

chown ldap:ldap "${SOCKET_DIR}"

if [ ! -e "${SEEDED}" ]; then
  # Contents without the mark come from a seed that stopped halfway, and
  # cannot be carried on from. Whether to delete them is for the
  # administrator of Koitohan to decide.
  if [ -e "${CONF_DIR}/cn=config.ldif" ] || [ -e "${DATA_DIR}/data.mdb" ]; then
    echo 'openldap/config or openldap/data holds a directory that this image did not finish making.' >&2
    echo 'Delete what is in both (everything in the directory is lost), then start again.' >&2
    exit 1
  fi

  echo 'seeding the empty directory'

  # Listens on ldaps:/// and ldapi:/// only (not on 389). Demands a client
  # certificate, and takes TLS 1.3 only.
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
olcTLSProtocolMin: 3.4
olcTLSVerifyClient: demand

dn: cn=module{0},cn=config
objectClass: olcModuleList
cn: module{0}
olcModulePath: /usr/lib/openldap
olcModuleLoad: back_mdb
olcModuleLoad: memberof
olcModuleLoad: refint
olcModuleLoad: argon2

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
olcPasswordHash: {ARGON2}

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

  # load the LDIF into a slapd that listens on the socket only, so that the
  # directory cannot be reached from outside while it is half seeded
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

  # in the order of the file names. If any one fails, do not start (do not
  # serve a directory with parts missing).
  for LDIF in "${SEED_DIR}"/*.ldif; do
    echo "seeding ${LDIF}"
    if ! ldapadd -Q -Y EXTERNAL -H ldapi:/// -f "${LDIF}"; then
      echo "could not load ${LDIF}" >&2
      kill ${SEED_PID}
      wait ${SEED_PID} || true
      # all of it was made just now from nothing, so delete it and let the
      # next start try again
      rm -rf "${CONF_DIR}/cn=config" "${CONF_DIR}/cn=config.ldif" "${DATA_DIR}/data.mdb" "${DATA_DIR}/lock.mdb"
      exit 1
    fi
  done

  kill ${SEED_PID}
  wait ${SEED_PID} || true
  touch "${SEEDED}"
  echo 'seeded'
fi

# A directory that was seeded before the passwords were hashed with
# Argon2 does not load the module. It has to be there before the scheme
# below is written: slapmodify writes the scheme unchecked, and slapd
# cannot read a config that names a scheme it has no module for.
MODULES=$(slapcat -n 0 -F "${CONF_DIR}" -a '(objectClass=olcModuleList)')
if ! echo "${MODULES}" | grep -q '^olcModuleLoad: {[0-9]*}argon2$'; then
  echo 'loading the module of Argon2'
  slapmodify -n 0 -F "${CONF_DIR}" <<EOF
dn: cn=module{0},cn=config
changetype: modify
add: olcModuleLoad
olcModuleLoad: argon2
EOF
fi

# The passwords of the administrators, the log level, the minimum of TLS
# and the scheme of the password hashes are written on every start. The
# files and the environment are where they are kept, and a change made
# over ldapi:/// does not outlive a start. The scheme is for the
# passwords that are set from now on: a hash that is there stays as it
# is, and still verifies, until its password is changed.
slapmodify -n 0 -F "${CONF_DIR}" <<EOF
dn: cn=config
changetype: modify
replace: olcLogLevel
olcLogLevel: ${LDAP_LOG_LEVEL:-stats}
-
replace: olcTLSProtocolMin
olcTLSProtocolMin: 3.4

dn: olcDatabase={-1}frontend,cn=config
changetype: modify
replace: olcPasswordHash
olcPasswordHash: {ARGON2}

dn: olcDatabase={0}config,cn=config
changetype: modify
replace: olcRootPW
olcRootPW: $(slappasswd -T "${SECRETS_DIR}/ldap_config_password")

dn: olcDatabase={1}mdb,cn=config
changetype: modify
replace: olcRootPW
olcRootPW: $(slappasswd -T "${SECRETS_DIR}/ldap_admin_password")
EOF

# slapmodify writes as root, so hand the files back to slapd
chown -R ldap:ldap "${CONF_DIR}" "${DATA_DIR}"

exec slapd -u ldap -g ldap -F "${CONF_DIR}" -h 'ldaps:/// ldapi:///' -d 0
