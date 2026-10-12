#!/bin/bash
#
# Gives a service account a new password, on the running stack.
#
#   change_service_account_password.sh freeradius|openssh
#
# Runs on the Docker host. Makes a password, writes it into the
# directory through ldapi:/// of openldap, puts it into secrets/,
# generates the files that carry it again and recreates the container
# that binds with it. Recreating openssh cuts the sessions of the users.
#
# The old password is not asked for, so this also mends a secrets/ that
# the directory does not agree with. If a run stops halfway, run it again.
#
# COMPOSE_PROJECT_NAME and COMPOSE_FILE select another stack, and
# KOITOHAN_GENERATED_ROOT the generated files of that stack, as
# tests/smoke.sh does.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"

source "${ROOT_DIR}/.env"

function die() {
  echo "$*" >&2
  exit 1
}

# the generating scripts read this too
KOITOHAN_GENERATED_ROOT=$(cd "${KOITOHAN_GENERATED_ROOT:-${ROOT_DIR}}" && pwd) \
  || die 'KOITOHAN_GENERATED_ROOT: no such directory'
export KOITOHAN_GENERATED_ROOT

cd "${ROOT_DIR}"

function domain2dn() {
  local DOMAIN=${1}

  echo ${DOMAIN} \
  | tr . '\n' \
  | awk '{print "dc="$1}' \
  | paste -s -d ','
}

SERVICE=${1:-}
case ${SERVICE} in
  freeradius|openssh) ;;
  *) echo "usage: $(basename "${0}") freeradius|openssh" >&2; exit 2 ;;
esac
[ $# -eq 1 ] || { echo "usage: $(basename "${0}") freeradius|openssh" >&2; exit 2; }

NAME_VAR="${SERVICE^^}_SERVICE_ACCOUNT_NAME"
DN="uid=${!NAME_VAR},ou=ServiceAccounts,$(domain2dn ${LDAP_DOMAIN})"

PASSWORD_FILE="${KOITOHAN_GENERATED_ROOT}/secrets/${SERVICE}_service_account_password"
NEW_FILE="${PASSWORD_FILE}.new"

# the file that the container reads the password from
case ${SERVICE} in
  freeradius) MOUNTED="${KOITOHAN_GENERATED_ROOT}/freeradius/config/mods-available/ldap_openldap" ;;
  openssh)    MOUNTED="${PASSWORD_FILE}" ;;
esac

function openldap() {
  docker compose exec -T openldap "$@"
}

# A stack that reads other files must not get its password changed: the
# directory and the files would part, and nobody could log in.
CONTAINER=$(docker compose ps -a -q "${SERVICE}" 2> /dev/null)
[ -n "${CONTAINER}" ] || die "${SERVICE}: no such container in this stack. Start the stack first."
docker inspect -f '{{range .Mounts}}{{println .Source}}{{end}}' "${CONTAINER}" \
| grep -q -x -F -- "${MOUNTED}" \
  || die "${SERVICE} does not read ${MOUNTED}. For another stack, set KOITOHAN_GENERATED_ROOT."

openldap ldapsearch -Q -Y EXTERNAL -H ldapi:/// -LLL -b "${DN}" -s base dn < /dev/null > /dev/null 2>&1 \
  || die "${DN}: no such account, or openldap is not running"

trap 'rm -f "${NEW_FILE}"' EXIT
rm -f "${NEW_FILE}"
"${ROOT_DIR}/scripts/generate_service_account_password.sh" "${SERVICE}" "${NEW_FILE}" || exit 1

# In clear text: ppolicy refuses a hash. Nothing is changed if this fails.
openldap ldappasswd -Q -Y EXTERNAL -H ldapi:/// -T /dev/stdin "${DN}" < "${NEW_FILE}" \
  || die "could not set the password of ${DN}"

# From here on the directory knows the new password only.
AGAIN="Run $(basename "${0}") ${SERVICE} again."
mv "${NEW_FILE}" "${PASSWORD_FILE}" || die "could not write ${PASSWORD_FILE}. ${AGAIN}"

openldap ldapwhoami -x -H ldapi:/// -D "${DN}" -y /dev/stdin < "${PASSWORD_FILE}" > /dev/null \
  || die "the directory does not take the new password. ${AGAIN}"

# the seed LDIF, for the next empty database
"${ROOT_DIR}/scripts/generate_ldap_base.sh" || die "could not generate the LDIFs. ${AGAIN}"
if [ "${SERVICE}" = 'freeradius' ]; then
  "${ROOT_DIR}/scripts/generate_freeradius_ldap.sh" || die "could not generate ldap_openldap. ${AGAIN}"
fi

# restart would not do: openssh has the file itself mounted, and would
# go on seeing the old one
docker compose up -d --force-recreate --no-deps "${SERVICE}" > /dev/null 2>&1 \
  || die "could not recreate ${SERVICE}. ${AGAIN}"

echo "changed the password of ${DN} and recreated ${SERVICE}"
