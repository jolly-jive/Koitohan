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
  # Contents without the mark come from a seed that stopped halfway, or
  # from another image. Neither can be carried on from. Whether to delete
  # them is for the administrator of Koitohan to decide.
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

# The passwords of the administrators and the log level are written on
# every start. The files and the environment are where they are kept.
# The two of TLS mend the config that earlier seeds made (the minimum was
# 1.2, and it named a file of DH parameters).
# A replace without a value deletes the attribute if there is one, and
# does nothing otherwise.
slapmodify -n 0 -F "${CONF_DIR}" <<EOF
dn: cn=config
changetype: modify
replace: olcLogLevel
olcLogLevel: ${LDAP_LOG_LEVEL:-stats}
-
replace: olcTLSProtocolMin
olcTLSProtocolMin: 3.4
-
replace: olcTLSDHParamFile

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
