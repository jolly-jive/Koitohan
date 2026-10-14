#!/bin/bash
#
# Makes the password of a service account: secrets/<service>_service_account_password.
#
#   generate_service_account_password.sh freeradius|openssh [<file>]
#
# <file> is another place to write to. bin/change_service_account_password.sh
# uses it, to hold the new password until the directory has taken it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR%/*}"

# tests/smoke.sh keeps its own generated files apart
GENERATED_ROOT="${KOITOHAN_GENERATED_ROOT:-${ROOT_DIR}}"

SERVICE=${1:-}
case ${SERVICE} in
  freeradius|openssh) ;;
  *) echo "usage: ${0} freeradius|openssh [<file>]" >&2; exit 1 ;;
esac

OUT_FILE=${2:-${GENERATED_ROOT}/secrets/${SERVICE}_service_account_password}

if [[ -e "${OUT_FILE}" ]]; then
  echo "${OUT_FILE} exists. bin/change_service_account_password.sh makes a new one on a running stack." >&2
  exit 1
fi

# letters and digits only: the value goes into ldap_openldap and nslcd.conf as it is
PASSWORD=$(openssl rand -hex 24)
if [[ ${#PASSWORD} -ne 48 ]]; then
  echo 'could not make a password' >&2
  exit 1
fi

umask 077

# without a newline: ldapsearch -y and ldappasswd -T take one as a part of the password
printf '%s' "${PASSWORD}" > "${OUT_FILE}"
