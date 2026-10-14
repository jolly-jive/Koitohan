#!/bin/bash
#
# Gives the administrators of OpenLDAP new passwords, on the running
# stack: the one of the data (cn=admin,<suffix>) and the one of the
# configuration (cn=admin,cn=config), both at once.
#
#   change_ldap_admin_password.sh
#
# Runs on the Docker host. Makes the passwords, puts them into secrets/
# and recreates openldap, which sets the passwords it is given on every
# start. Nobody can log in until openldap is back.
#
# The old passwords are not asked for, so this also mends a secrets/
# that the directory does not agree with. If a run stops halfway, run
# it again.
#
# COMPOSE_PROJECT_NAME and COMPOSE_FILE select another stack, and
# KOITOHAN_GENERATED_ROOT the generated files of that stack, as
# tests/smoke.sh does.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR%/*}"

source "${ROOT_DIR}/.env"

function die() {
  echo "$*" >&2
  exit 1
}

# the generating script reads this too
KOITOHAN_GENERATED_ROOT=$(cd "${KOITOHAN_GENERATED_ROOT:-${ROOT_DIR}}" && pwd) \
  || die 'KOITOHAN_GENERATED_ROOT: no such directory'
export KOITOHAN_GENERATED_ROOT

cd "${ROOT_DIR}"

function domain2dn() {
  local DOMAIN=${1}

  echo "dc=${DOMAIN//./,dc=}"
}

[[ $# -eq 0 ]] || { echo "usage: ${0##*/}" >&2; exit 2; }

WAIT_TRIES=40

function password_file() {
  echo "${KOITOHAN_GENERATED_ROOT}/secrets/ldap_${1}_password"
}

function dn_of() {
  case ${1} in
    admin)  echo "cn=admin,$(domain2dn ${LDAP_DOMAIN})" ;;
    config) echo 'cn=admin,cn=config' ;;
  esac
}

function openldap() {
  docker compose exec -T openldap "$@"
}

function binds() {
  openldap ldapwhoami -x -H ldapi:/// -D "$(dn_of ${1})" -y /dev/stdin < "$(password_file ${1})" > /dev/null 2>&1
}

# A stack that reads other files must not get them replaced: the next
# start of its openldap would set passwords that nobody meant.
CONTAINER=$(docker compose ps -a -q openldap 2> /dev/null)
[[ -n "${CONTAINER}" ]] || die 'openldap: no such container in this stack. Start the stack first.'
for WHICH in admin config; do
  docker inspect -f '{{range .Mounts}}{{println .Source}}{{end}}' "${CONTAINER}" \
  | grep -q -x -F -- "$(password_file ${WHICH})" \
    || die "openldap does not read $(password_file ${WHICH}). For another stack, set KOITOHAN_GENERATED_ROOT."
done

trap 'rm -f "$(password_file admin).new" "$(password_file config).new"' EXIT
for WHICH in admin config; do
  rm -f "$(password_file ${WHICH}).new"
  "${ROOT_DIR}/scripts/generate_ldap_admin_password.sh" ${WHICH} "$(password_file ${WHICH}).new" || exit 1
done

# From here on the files and the directory do not agree, until openldap
# has started again.
AGAIN="Run ${0##*/} again."
for WHICH in admin config; do
  mv "$(password_file ${WHICH}).new" "$(password_file ${WHICH})" \
    || die "could not write $(password_file ${WHICH}). ${AGAIN}"
done

# restart would not do: openldap has the files themselves mounted, and
# would go on seeing the old ones
docker compose up -d --force-recreate --no-deps openldap > /dev/null 2>&1 \
  || die "could not recreate openldap. ${AGAIN}"

for (( TRY = 1; TRY <= WAIT_TRIES; TRY++ )); do
  if binds admin && binds config; then
    echo "changed the passwords of $(dn_of admin) and $(dn_of config) and recreated openldap"
    exit 0
  fi
  sleep 3
done

die "the directory does not take the new passwords. Look at 'docker compose logs openldap'. ${AGAIN}"
