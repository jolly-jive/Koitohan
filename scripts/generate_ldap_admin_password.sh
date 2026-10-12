#!/bin/bash
#
# Makes the password of an administrator of OpenLDAP: secrets/ldap_<which>_password.
#
#   generate_ldap_admin_password.sh admin|config [<file>]
#
# admin is the administrator of the data (cn=admin,<suffix>), config the
# one of the configuration (cn=admin,cn=config). <file> is another place
# to write to. bin/change_ldap_admin_password.sh uses it, to hold the
# new passwords until both are made.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"

# tests/smoke.sh keeps its own generated files apart
GENERATED_ROOT="${KOITOHAN_GENERATED_ROOT:-${ROOT_DIR}}"

WHICH=${1}
case ${WHICH} in
  admin|config) ;;
  *) echo "usage: ${0} admin|config [<file>]" >&2; exit 1 ;;
esac

OUT_FILE=${2:-${GENERATED_ROOT}/secrets/ldap_${WHICH}_password}

if [ -e "${OUT_FILE}" ]; then
  echo "${OUT_FILE} exists. bin/change_ldap_admin_password.sh makes a new one on a running stack." >&2
  exit 1
fi

# letters and digits only: the image puts the hash of the value into sed
PASSWORD=$(openssl rand -hex 24)
if [ ${#PASSWORD} -ne 48 ]; then
  echo 'could not make a password' >&2
  exit 1
fi

umask 077

# without a newline: ldapsearch -y takes one as a part of the password
printf '%s' "${PASSWORD}" > "${OUT_FILE}"
