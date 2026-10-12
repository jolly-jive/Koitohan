#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"

source "${ROOT_DIR}/.env"

OUT_DIR="${ROOT_DIR}/CA"

function domain2dn() {
  local DOMAIN=${1}

  echo ${DOMAIN} \
  | tr . '\n' \
  | awk '{print "dc="$1}' \
  | paste -s -d ','
}

LDAP_SUFFIX=$(domain2dn ${LDAP_DOMAIN})

function comma_dn2slash_dn() {
  local COMMA_DN=${1}

  echo "/$(echo ${COMMA_DN} | tr ',' '/')"
}


function set_names() {
  local SUBJ_HOSTNAME=${1}
  local SUBJ_ID=${2}
  local SUBJ_ID_LOWER=$(echo ${SUBJ_ID} | tr '[:upper:]' '[:lower:]')

  cat <<-EOF
	${SUBJ_ID}_HOSTNAME="${SUBJ_HOSTNAME}"
	${SUBJ_ID}_FQDN="${SUBJ_HOSTNAME}.${LDAP_DOMAIN}"
	${SUBJ_ID}_DN="DC=${SUBJ_HOSTNAME},${LDAP_SUFFIX}"
	${SUBJ_ID}_DN_SLASH=\$(comma_dn2slash_dn \$${SUBJ_ID}_DN)
	${SUBJ_ID}_KEY_FILE="${OUT_DIR}/${SUBJ_ID_LOWER}.key"
	${SUBJ_ID}_CSR_FILE="${OUT_DIR}/${SUBJ_ID_LOWER}.csr"
	${SUBJ_ID}_CRT_FILE="${OUT_DIR}/${SUBJ_ID_LOWER}.crt"
	EOF
}


echo -e "\n# SET NAMES"

eval $(set_names ${FREERADIUS_CONTAINER_NAME} FREERADIUS_CLIENT)

echo -e "\n## FREERADIUS_CLIENT"
echo "  FQDN     = ${FREERADIUS_CLIENT_FQDN}"
echo "  DN       = ${FREERADIUS_CLIENT_DN}"
echo "  DN_SLASH = ${FREERADIUS_CLIENT_DN_SLASH}"


eval $(set_names ${OPENSSH_CONTAINER_NAME} OPENSSH_CLIENT)

echo -e "\n## OPENSSH_CLIENT"
echo "  FQDN     = ${OPENSSH_CLIENT_FQDN}"
echo "  DN       = ${OPENSSH_CLIENT_DN}"
echo "  DN_SLASH = ${OPENSSH_CLIENT_DN_SLASH}"


eval $(set_names ${OPENLDAP_CONTAINER_NAME} OPENLDAP_SERVER)

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


CNF_FILE="${SCRIPT_DIR}/openssl.conf"

echo -e "\n# CREATE CONFIG FILE: ${CNF_FILE}"
(
  cat "${CNF_FILE}.template"
  echo "DNS.1 = ${OPENLDAP_SERVER_HOSTNAME}"
  echo "DNS.2 = ${OPENLDAP_SERVER_FQDN}"
  echo "DNS.3 = localhost"
) > ${CNF_FILE}


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


DHPARAM="${OUT_DIR}/dhparam.pem"
echo -e "\n# CREATE DH PARAM: ${DHPARAM}"
openssl dhparam -text -out ${DHPARAM} 2048


# Every run makes a new CA, so its key has no use once the certificates
# are signed. Left behind, it could sign a certificate that OpenLDAP takes.
echo -e "\n# REMOVE CA KEY AND CSRS"
rm -f ${CA_KEY_FILE} \
  ${OPENLDAP_SERVER_CSR_FILE} ${FREERADIUS_CLIENT_CSR_FILE} ${OPENSSH_CLIENT_CSR_FILE}
