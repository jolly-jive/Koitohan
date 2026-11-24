#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR%/*}"

# the environment wins over .env, as it does for docker compose. An .env
# from before the redundant pair does not have it: a single host.
FROM_ENVIRONMENT="${OPENLDAP_HOST_ADDRESS-}"
OPENLDAP_HOST_ADDRESS=none
source "${ROOT_DIR}/.env"
[[ -n "${FROM_ENVIRONMENT}" ]] && OPENLDAP_HOST_ADDRESS="${FROM_ENVIRONMENT}"

# The address of this Docker host that the other host of a pair connects
# to, as the server certificate has to name it. none for a single host.
function valid_address() {
  local OCTET
  local -a OCTETS

  [[ "${1}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  IFS=. read -r -a OCTETS <<< "${1}"
  for OCTET in "${OCTETS[@]}"; do
    (( 10#${OCTET} <= 255 )) || return 1
  done
}
if [[ "${OPENLDAP_HOST_ADDRESS}" != none ]] && ! valid_address "${OPENLDAP_HOST_ADDRESS}"; then
  echo "OPENLDAP_HOST_ADDRESS must be none or an IPv4 address: '${OPENLDAP_HOST_ADDRESS}'" >&2
  exit 1
fi

# tests/smoke.sh keeps its own generated files apart
GENERATED_ROOT="${KOITOHAN_GENERATED_ROOT:-${ROOT_DIR}}"

OUT_DIR="${GENERATED_ROOT}/CA"

# OpenLDAP maps the subjects of the client certificates to the identities
# of the services (olcAuthzRegexp in openldap/build/entrypoint.sh). It
# looks at CN and O only; OU tells in the logs which host a connection
# comes from.
SERVICE_OU=$(hostname -s)
if [[ ! "${SERVICE_OU}" =~ ^[A-Za-z0-9-]+$ ]]; then
  echo "the host name is not one to put in a certificate: ${SERVICE_OU}" >&2
  exit 1
fi

function domain2dn() {
  local DOMAIN=${1}

  echo "dc=${DOMAIN//./,dc=}"
}

# openssl req -subj knows the short names in upper case only, and skips
# "dc" with a warning: the subject would keep the first component alone
LDAP_SUFFIX=$(domain2dn ${LDAP_DOMAIN})
LDAP_SUFFIX=${LDAP_SUFFIX//dc=/DC=}

function comma_dn2slash_dn() {
  local COMMA_DN=${1}

  echo "/${COMMA_DN//,//}"
}


# The third argument, if any, is the subject in place of the one made
# from the host name.
function set_names() {
  local SUBJ_HOSTNAME=${1}
  local SUBJ_ID=${2}
  local SUBJ_DN=${3:-DC=${SUBJ_HOSTNAME},${LDAP_SUFFIX}}
  local SUBJ_ID_LOWER=${SUBJ_ID,,}

  cat <<-EOF
	${SUBJ_ID}_HOSTNAME="${SUBJ_HOSTNAME}"
	${SUBJ_ID}_FQDN="${SUBJ_HOSTNAME}.${LDAP_DOMAIN}"
	${SUBJ_ID}_DN="${SUBJ_DN}"
	${SUBJ_ID}_DN_SLASH=\$(comma_dn2slash_dn \$${SUBJ_ID}_DN)
	${SUBJ_ID}_KEY_FILE="${OUT_DIR}/${SUBJ_ID_LOWER}.key"
	${SUBJ_ID}_CSR_FILE="${OUT_DIR}/${SUBJ_ID_LOWER}.csr"
	${SUBJ_ID}_CRT_FILE="${OUT_DIR}/${SUBJ_ID_LOWER}.crt"
	EOF
}


echo -e "\n# SET NAMES"

eval $(set_names ${FREERADIUS_CONTAINER_NAME} FREERADIUS_CLIENT "O=koitohan,OU=${SERVICE_OU},CN=freeradius")

echo -e "\n## FREERADIUS_CLIENT"
echo "  FQDN     = ${FREERADIUS_CLIENT_FQDN}"
echo "  DN       = ${FREERADIUS_CLIENT_DN}"
echo "  DN_SLASH = ${FREERADIUS_CLIENT_DN_SLASH}"


eval $(set_names ${OPENSSH_CONTAINER_NAME} OPENSSH_CLIENT "O=koitohan,OU=${SERVICE_OU},CN=openssh")

echo -e "\n## OPENSSH_CLIENT"
echo "  FQDN     = ${OPENSSH_CLIENT_FQDN}"
echo "  DN       = ${OPENSSH_CLIENT_DN}"
echo "  DN_SLASH = ${OPENSSH_CLIENT_DN_SLASH}"


eval $(set_names ${OPENLDAP_CONTAINER_NAME} OPENLDAP_SERVER)

# Replication from the other host of a pair binds with this. The subject
# has to stay apart from the ones above: the other host maps it to the
# identity of replication by its subject alone.
eval $(set_names ${OPENLDAP_CONTAINER_NAME} OPENLDAP_REPLICATION "O=koitohan,OU=${SERVICE_OU},CN=replication")

echo -e "\n## OPENLDAP_REPLICATION"
echo "  DN       = ${OPENLDAP_REPLICATION_DN}"
echo "  DN_SLASH = ${OPENLDAP_REPLICATION_DN_SLASH}"

echo -e "\n## OPENLDAP_SERVER_FQDN"
echo "  FQDN     = ${OPENLDAP_SERVER_FQDN}"
echo "  DN       = ${OPENLDAP_SERVER_DN}"
echo "  DN_SLASH = ${OPENLDAP_SERVER_DN_SLASH}"

CA_HOSTNAME=ca
CA_FQDN="$CA_HOSTNAME.${LDAP_DOMAIN}"
CA_DN="DC=${CA_HOSTNAME},${LDAP_SUFFIX}"
CA_DN_SLASH=$(comma_dn2slash_dn ${CA_DN})
CA_KEY_FILE="${OUT_DIR}/default-ca-key.pem"
CA_CRT_FILE="${OUT_DIR}/default-ca.pem"
echo -e "\n## CA_FQDN"
echo "  FQDN     = ${CA_FQDN}"
echo "  DN       = ${CA_DN}"
echo "  DN_SLASH = ${CA_DN_SLASH}"


# used for the issue only, and removed with the key of the CA
CNF_FILE="${OUT_DIR}/openssl.conf"

echo -e "\n# CREATE CONFIG FILE: ${CNF_FILE}"
{
  cat "${SCRIPT_DIR}/openssl.conf.template"
  echo "DNS.1 = ${OPENLDAP_SERVER_HOSTNAME}"
  echo "DNS.2 = ${OPENLDAP_SERVER_FQDN}"
  echo "DNS.3 = localhost"
  # the other host of a pair connects by the address, not by a name
  if [[ "${OPENLDAP_HOST_ADDRESS}" != none ]]; then
    echo "IP.1 = ${OPENLDAP_HOST_ADDRESS}"
  fi
} > ${CNF_FILE}


function generate_key() {
  local KEY=${1}

  openssl genrsa -verbose -out ${KEY} 4096
}

function create_csr() {
  local KEY=${1}
  local CSR=${2}
  local DN=${3}

  openssl req \
  -config ${CNF_FILE} \
  -verbose \
  -new \
  -key ${KEY} \
  -out ${CSR} \
  -subj ${DN} \
  -text
}


function issue_cert() {
  local EXTENSION=${1}
  local CSR=${2}
  local CRT=${3}

  openssl x509 \
    -sha256 \
    -days 3650 \
    -extfile ${CNF_FILE} \
    -extensions ${EXTENSION} \
    -req \
    -in ${CSR} \
    -CA ${CA_CRT_FILE} \
    -CAkey ${CA_KEY_FILE} \
    -out ${CRT} \
    -text
}

# Every run makes a new CA, so its key has no use once the certificates
# are signed. Left behind, it could sign a certificate that OpenLDAP takes.
# Removed on the way out, also when a step below fails.
function remove_ca_key() {
  echo -e "\n# REMOVE CA KEY AND CSRS"
  rm -f ${CA_KEY_FILE} ${CNF_FILE} \
    ${OPENLDAP_SERVER_CSR_FILE} ${FREERADIUS_CLIENT_CSR_FILE} ${OPENSSH_CLIENT_CSR_FILE} \
    ${OPENLDAP_REPLICATION_CSR_FILE}
}
trap remove_ca_key EXIT

echo -e "\n# CREATE KEYS AND CERTS"

echo -e "\n## GENERATE KEY: ${CA_KEY_FILE}"
generate_key ${CA_KEY_FILE}

echo -e "\n## SIGN CERT: ${CA_CRT_FILE}"
openssl req \
  -config ${CNF_FILE} \
  -extensions ca_cert \
  -verbose -x509 -new \
  -days 3650 \
  -sha256 \
  -key ${CA_KEY_FILE}\
  -out ${CA_CRT_FILE} \
  -subj "${CA_DN_SLASH}" \
  -text


echo -e "\n## GENERATE SERVER KEY: ${OPENLDAP_SERVER_KEY_FILE}"
generate_key ${OPENLDAP_SERVER_KEY_FILE}

echo -e "\n## CREATE CSR: ${OPENLDAP_SERVER_CSR_FILE}"
create_csr ${OPENLDAP_SERVER_KEY_FILE}  ${OPENLDAP_SERVER_CSR_FILE}  ${OPENLDAP_SERVER_DN_SLASH}

echo -e "\n## SIGN CRT: ${OPENLDAP_SERVER_CRT_FILE}"
issue_cert server_cert  ${OPENLDAP_SERVER_CSR_FILE}  ${OPENLDAP_SERVER_CRT_FILE}


echo -e "\n## GENERATE FREERADIUS CLIENT KEY: ${FREERADIUS_CLIENT_KEY_FILE}"
generate_key ${FREERADIUS_CLIENT_KEY_FILE}
# FreeRADIUS reads the key after it has dropped root (uid 101 in the image)
chmod 644 ${FREERADIUS_CLIENT_KEY_FILE}

echo -e "\n## CREATE CSR: ${FREERADIUS_CLIENT_CSR_FILE}"
create_csr ${FREERADIUS_CLIENT_KEY_FILE}  ${FREERADIUS_CLIENT_CSR_FILE}  ${FREERADIUS_CLIENT_DN_SLASH}

echo -e "\n## SIGN CRT: ${FREERADIUS_CLIENT_CRT_FILE}"
issue_cert client_cert  ${FREERADIUS_CLIENT_CSR_FILE}  ${FREERADIUS_CLIENT_CRT_FILE}


echo -e "\n## GENERATE OPENSSH CLIENT KEY: ${OPENSSH_CLIENT_KEY_FILE}"
generate_key ${OPENSSH_CLIENT_KEY_FILE}

echo -e "\n## CREATE CSR: ${OPENSSH_CLIENT_CSR_FILE}"
create_csr ${OPENSSH_CLIENT_KEY_FILE}  ${OPENSSH_CLIENT_CSR_FILE}  ${OPENSSH_CLIENT_DN_SLASH}

echo -e "\n## SIGN CRT: ${OPENSSH_CLIENT_CRT_FILE}"
issue_cert client_cert  ${OPENSSH_CLIENT_CSR_FILE}  ${OPENSSH_CLIENT_CRT_FILE}


echo -e "\n## GENERATE OPENLDAP REPLICATION KEY: ${OPENLDAP_REPLICATION_KEY_FILE}"
generate_key ${OPENLDAP_REPLICATION_KEY_FILE}

echo -e "\n## CREATE CSR: ${OPENLDAP_REPLICATION_CSR_FILE}"
create_csr ${OPENLDAP_REPLICATION_KEY_FILE}  ${OPENLDAP_REPLICATION_CSR_FILE}  ${OPENLDAP_REPLICATION_DN_SLASH}

echo -e "\n## SIGN CRT: ${OPENLDAP_REPLICATION_CRT_FILE}"
issue_cert client_cert  ${OPENLDAP_REPLICATION_CSR_FILE}  ${OPENLDAP_REPLICATION_CRT_FILE}
