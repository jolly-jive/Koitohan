#!/bin/bash
#
# Makes the password of a service account: secrets/<service>_service_account_password.
#
#   generate_service_account_password.sh freeradius|openssh
#
# An .env from before this script still carries the password. That one
# is taken over, as the running directory knows no other.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"

source "${ROOT_DIR}/.env"

SERVICE=${1}
case ${SERVICE} in
  freeradius|openssh) ;;
  *) echo "usage: ${0} freeradius|openssh" >&2; exit 1 ;;
esac

OUT_FILE="${ROOT_DIR}/secrets/${SERVICE}_service_account_password"
LEGACY_NAME="${SERVICE^^}_SERVICE_ACCOUNT_PASSWORD"

if [ -e "${OUT_FILE}" ]; then
  echo "${OUT_FILE} exists. Remove it first to make a new one." >&2
  exit 1
fi

if [ -n "${!LEGACY_NAME}" ]; then
  PASSWORD=${!LEGACY_NAME}
  echo "took ${LEGACY_NAME} over from .env. It is not read any more, so remove it from .env."
else
  # letters and digits only: the value goes into ldap_openldap and nslcd.conf as it is
  PASSWORD=$(openssl rand -hex 24)
  if [ ${#PASSWORD} -ne 48 ]; then
    echo 'could not make a password' >&2
    exit 1
  fi
fi

umask 077

# without a newline: ldapsearch -y and ldappasswd -T take one as a part of the password
printf '%s' "${PASSWORD}" > "${OUT_FILE}"
