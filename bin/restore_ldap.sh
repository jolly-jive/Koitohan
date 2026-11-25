#!/bin/bash
#
# Loads the directory of a backup into an empty openldap.
#
#   restore_ldap.sh ARCHIVE
#
# Runs on the Docker host. ARCHIVE is what bin/backup.sh wrote. Loads
# its cn=config and its directory with slapadd, into the persistent
# data of openldap, and marks them as seeded, so that the next start of
# openldap serves them and seeds nothing. Starts nothing: run
# 'make up' afterwards.
#
# The persistent data has to be empty, so stop the stack and delete it
# first (see docs/backup.md). If there is no openldap container, this
# makes one, without starting it. slapadd runs in a container of the
# same image with the volumes of that container, so this needs no sudo,
# and reaches the anonymous volumes of the test stack as well. If a run
# stops halfway, what it loaded is deleted, and it can be run again.
#
# COMPOSE_PROJECT_NAME and COMPOSE_FILE select another stack, as
# tests/smoke.sh does.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR%/*}"

source "${ROOT_DIR}/.env"

function die() {
  echo "$*" >&2
  exit 1
}

[[ $# -eq 1 ]] || { echo "usage: ${0##*/} ARCHIVE" >&2; exit 2; }
ARCHIVE=$(realpath -e -- "${1}" 2> /dev/null) || die "${1}: no such file"

cd "${ROOT_DIR}"

function domain2dn() {
  local DOMAIN=${1}

  echo "dc=${DOMAIN//./,dc=}"
}

CONF_DIR=/etc/openldap/slapd.d
DATA_DIR=/var/lib/openldap/openldap-data
SEEDED="${CONF_DIR}/koitohan-seeded"

umask 077
WORK=$(mktemp -d) || die 'could not make a temporary directory'
trap 'rm -rf "${WORK}"' EXIT

tar -x -z -f "${ARCHIVE}" -C "${WORK}" ldap/config.ldif ldap/data.ldif 2> /dev/null \
  || die "${ARCHIVE}: not a backup of bin/backup.sh"

# The suffix comes from LDAP_DOMAIN, in the config of FreeRADIUS and of
# OpenSSH as well. A directory under another one would find nobody.
SUFFIX=$(domain2dn ${LDAP_DOMAIN})
FIRST=$(head -n 1 "${WORK}/ldap/data.ldif")
[[ "${FIRST,,}" == "dn: ${SUFFIX,,}" ]] \
  || die "the backup holds ${FIRST#dn: }, but LDAP_DOMAIN in .env makes ${SUFFIX}"

# Docker would create a missing source of a bind mount as root
for FILE in CA/default-ca.pem CA/openldap_server.crt CA/openldap_server.key; do
  [[ -f "${FILE}" ]] || die "${FILE} is missing. Run 'make' first."
done

CONTAINER=$(docker compose ps -a -q openldap 2> /dev/null)
if [[ -z "${CONTAINER}" ]]; then
  docker compose create openldap > /dev/null 2>&1 || die 'could not make the openldap container'
  CONTAINER=$(docker compose ps -a -q openldap 2> /dev/null)
  [[ -n "${CONTAINER}" ]] || die 'could not make the openldap container'
fi
IMAGE=$(docker inspect -f '{{.Image}}' "${CONTAINER}") || die 'could not find the image of openldap'

# runs sh as root in a container of the image of openldap, with its volumes
function in_openldap() {
  docker run --rm -i --network none --volumes-from "${CONTAINER}" --entrypoint sh "${IMAGE}" -c "${1}"
}

# a running openldap is refused here as well: its directory is seeded
in_openldap "test ! -e '${CONF_DIR}/cn=config.ldif' && test ! -e '${DATA_DIR}/data.mdb'" < /dev/null \
  || die "the persistent data of openldap is not empty. Stop the stack and delete it first (see docs/backup.md)."

function undo() {
  in_openldap "rm -rf '${CONF_DIR}/cn=config' '${CONF_DIR}/cn=config.ldif' '${DATA_DIR}/data.mdb' '${DATA_DIR}/lock.mdb'" < /dev/null
  die "${1}. Nothing is left of it, so run ${0##*/} again."
}

in_openldap "slapadd -F '${CONF_DIR}' -n 0" < "${WORK}/ldap/config.ldif" \
  || undo 'could not load cn=config'
in_openldap "slapadd -F '${CONF_DIR}' -n 1" < "${WORK}/ldap/data.ldif" \
  || undo 'could not load the LDAP directory'
# the mark is what keeps the entrypoint from seeding over it
in_openldap "touch '${SEEDED}' && chown -R ldap:ldap '${CONF_DIR}' '${DATA_DIR}'" < /dev/null \
  || undo 'could not mark the LDAP directory as seeded'

echo "restored the LDAP directory of ${ARCHIVE}"

# A host of a pair. The other host has to receive everything from this
# one again. Started with its own data, it wrote that data over this
# one in a test, and the backup put back here did not last: both hosts
# ended up as they were before the restore. In an earlier trial the two
# hosts stayed different for good instead (docs/backup.md). Only a note:
# what makes the other host receive is deleting its persistent data
# there.
PEER=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${CONTAINER}" 2> /dev/null \
         | sed -n 's/^OPENLDAP_PEER_ADDRESS=//p')
if [[ -n "${PEER}" && "${PEER}" != none ]]; then
  cat <<EOF

This host is one of a pair (OPENLDAP_PEER_ADDRESS=${PEER}).
Before you start OpenLDAP here, stop it on the other host and delete
its persistent data there, so that it receives everything from this
host. Started with its own data, the other host can write that data
over this host without a word, so that the backup put back here does
not last, or the two hosts can stay different for good.
See "Restoring a pair" in docs/backup.md.
EOF
fi
exit 0
