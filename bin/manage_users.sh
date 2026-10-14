#!/bin/bash
#
# Manages the users of Koitohan: add, delete, change the role, set a new
# password, unlock.
#
# Runs on the Docker host and works inside the containers: LDAP goes
# through ldapi:/// of openldap, the passwords are judged by pwqcheck of
# openssh. Every change is followed by koitohan-update-users, and a
# delete or a change of role cuts the sessions of the user.
#
# The password is asked for on the terminal. Without a terminal, it is
# the first line of the standard input.
#
# COMPOSE_PROJECT_NAME and COMPOSE_FILE select another stack, as
# tests/smoke.sh does.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR%/*}"

source "${ROOT_DIR}/.env"

cd "${ROOT_DIR}"

function domain2dn() {
  local DOMAIN=${1}

  echo "dc=${DOMAIN//./,dc=}"
}

LDAP_SUFFIX=$(domain2dn ${LDAP_DOMAIN})
PEOPLE_DN="ou=People,${LDAP_SUFFIX}"
ROLES_DN="ou=Roles,${LDAP_SUFFIX}"
# the next uidNumber to hand out. A number is never used twice, so
# "the highest in use + 1" would not do.
COUNTER_DN="cn=nextUidNumber,${LDAP_SUFFIX}"

ROLES=(admin operator readonly)
UID_NUMBER_MIN=10000
UID_NUMBER_MAX=59999
GID_NUMBER=10000

function usage() {
  cat <<EOF
usage: ${0##*/} add <user> <role> [<full name>]
       ${0##*/} delete <user>
       ${0##*/} role <user> <role>
       ${0##*/} passwd <user>
       ${0##*/} unlock <user>

roles: ${ROLES[*]}
EOF
  exit 2
}

function die() {
  echo "$*" >&2
  exit 1
}

# the root of the container is the manager of the directory over ldapi:///
function ldap() {
  local TOOL=${1}
  shift

  docker compose exec -T openldap "${TOOL}" -Q -Y EXTERNAL -H ldapi:/// "$@"
}

function ldap_search() {
  ldap ldapsearch -LLL -o ldif-wrap=no "$@" < /dev/null
}

# the values of one attribute in the output of ldap_search
function values_of() {
  awk -v prefix="${1}: " 'index($0, prefix) == 1 { print substr($0, length(prefix) + 1) }'
}

function openssh() {
  docker compose exec -T openssh "$@"
}

function is_role() {
  local ROLE

  for ROLE in "${ROLES[@]}"; do
    [[ "${ROLE}" == "${1}" ]] && return 0
  done
  return 1
}

function user_dn() {
  echo "uid=${1},${PEOPLE_DN}"
}

function user_exists() {
  local OUT

  OUT=$(ldap_search -b "${PEOPLE_DN}" -s one "(uid=${1})" dn) || die 'could not search the directory'
  [[ -n "${OUT}" ]]
}

# keeps the name out of the DNs and the filters as it is. Users made by
# hand may have names that "add" would not take.
function require_user() {
  [[ "${1}" =~ ^[A-Za-z0-9._-]+$ ]] || die "${1}: not a user name"
  user_exists "${1}" || die "${1}: no such user"
}

# The helpers below search before they pipe, so that a failed search
# fails them too: the status of a pipe is the one of its last command.
function uid_number_of() {
  local OUT

  OUT=$(ldap_search -b "$(user_dn "${1}")" -s base uidNumber) || return 1
  values_of uidNumber <<< "${OUT}"
}

# cn comes in base64 when it is not plain ASCII
function full_name_of() {
  local OUT

  OUT=$(ldap_search -b "$(user_dn "${1}")" -s base cn) || return 1
  values_of cn <<< "${OUT}" | head -n 1
  values_of cn: <<< "${OUT}" | head -n 1 | base64 -d 2> /dev/null
}

function roles_of() {
  local OUT

  OUT=$(ldap_search -b "${ROLES_DN}" -s one "(uniqueMember=$(user_dn "${1}"))" cn) || return 1
  values_of cn <<< "${OUT}"
}

function read_password() {
  local AGAIN

  if [[ -t 0 ]]; then
    read -r -s -p 'New password: ' PASSWORD; echo
    read -r -s -p 'Retype new password: ' AGAIN; echo
    [[ "${PASSWORD}" == "${AGAIN}" ]] || die 'the passwords do not match'
  else
    read -r PASSWORD
  fi
  [[ -n "${PASSWORD}" ]] || die 'the password is empty'
}

# the same rules as passwd in the openssh container (PASSWDQC_MIN).
# pwqcheck takes the new password, the old one and a passwd entry.
function check_password() {
  local USER=${1}
  local FULL_NAME=${2}
  local OUT

  OUT=$(printf '%s\n\n%s:x:0:0:%s:/:/bin/sh\n' "${PASSWORD}" "${USER}" "${FULL_NAME//:/ }" \
        | openssh pwqcheck config=/etc/passwdqc.conf 2>&1)
  [[ "${OUT}" == 'OK' ]] || die "the password was refused: ${OUT}"
}

# In clear text and from the standard input: OpenLDAP hashes it and
# applies its own policy, and it stays out of ps.
function set_password() {
  printf '%s' "${PASSWORD}" | ldap ldappasswd -T /dev/stdin "$(user_dn "${1}")"
}

function highest_uid_number() {
  local OUT

  OUT=$(ldap_search -b "${PEOPLE_DN}" -s one '(uidNumber=*)' uidNumber) || return 1
  values_of uidNumber <<< "${OUT}" \
  | awk -v min=${UID_NUMBER_MIN} -v max=${UID_NUMBER_MAX} '
      BEGIN { top = min - 1 }
      $1 ~ /^[0-9]+$/ && $1 + 0 <= max && $1 + 0 > top { top = $1 + 0 }
      END { print top }'
}

# Takes the next number and moves the counter on. The delete of the old
# value fails if another run has taken the number in between.
function allocate_uid_number() {
  local TRY NEXT

  for TRY in 1 2 3 4 5; do
    NEXT=$(ldap_search -b "${COUNTER_DN}" -s base serialNumber 2> /dev/null | values_of serialNumber)
    if [[ -z "${NEXT}" ]]; then
      # the first run on this directory: start after the users made by hand
      NEXT=$(highest_uid_number) || return 1
      ldap ldapadd > /dev/null 2>&1 <<EOF
dn: ${COUNTER_DN}
objectClass: device
cn: nextUidNumber
serialNumber: $((NEXT + 1))
EOF
      continue
    fi
    [[ "${NEXT}" =~ ^[0-9]+$ ]] || die "${COUNTER_DN}: serialNumber is not a number"
    [[ "${NEXT}" -le ${UID_NUMBER_MAX} ]] || die "no uidNumber is left (${UID_NUMBER_MIN}-${UID_NUMBER_MAX})"
    if ldap ldapmodify > /dev/null 2>&1 <<EOF
dn: ${COUNTER_DN}
changetype: modify
delete: serialNumber
serialNumber: ${NEXT}
-
add: serialNumber
serialNumber: $((NEXT + 1))
EOF
    then
      echo "${NEXT}"
      return 0
    fi
  done
  return 1
}

# /etc/passwd and /etc/group of the openssh container
function update_users() {
  openssh koitohan-update-users < /dev/null \
  || echo "the change is made, but not shown to ssh yet. Run: docker compose exec openssh koitohan-update-users" >&2
}

# the UID is a number, as the name may be gone by now
function cut_sessions() {
  [[ -n "${1}" ]] || return 0
  openssh pkill -KILL -u "${1}" < /dev/null
  return 0
}

function cmd_add() {
  local USER=${1}
  local ROLE=${2}
  local FULL_NAME=${3:-${1}}
  local DN UID_NUMBER

  [[ "${USER}" =~ ^[a-z_][a-z0-9_-]*$ && ${#USER} -le 32 ]] \
    || die "${USER}: not usable as a login name (a-z, 0-9, _ and -, up to 32 characters)"
  is_role "${ROLE}" || die "${ROLE}: no such role (${ROLES[*]})"
  [[ "${FULL_NAME}" != *$'\n'* ]] || die 'the full name has a line break'
  user_exists "${USER}" && die "${USER}: the user exists"
  openssh cut -d: -f1 /etc/passwd.base < /dev/null | grep -q -x -F -- "${USER}" \
    && die "${USER}: the name belongs to an account of the openssh container"

  read_password
  check_password "${USER}" "${FULL_NAME}"

  UID_NUMBER=$(allocate_uid_number) || die 'could not allocate a uidNumber'
  DN=$(user_dn "${USER}")

  # without userPassword: set_password is the one way a password gets in
  ldap ldapadd > /dev/null <<EOF || die "could not add ${USER}"
dn: ${DN}
objectClass: inetOrgPerson
objectClass: posixAccount
uid: ${USER}
uidNumber: ${UID_NUMBER}
gidNumber: ${GID_NUMBER}
homeDirectory: /home/${USER}
loginShell: /bin/sh
cn:: $(printf '%s' "${FULL_NAME}" | base64 -w 0)
sn: ${USER}
EOF

  # a user without a role is not a state of the model, so take it back
  if ! set_password "${USER}" || ! ldap ldapmodify > /dev/null <<EOF
dn: cn=${ROLE},${ROLES_DN}
changetype: modify
add: uniqueMember
uniqueMember: ${DN}
EOF
  then
    ldap ldapdelete "${DN}" < /dev/null
    die "could not add ${USER}"
  fi

  update_users
  echo "added ${USER} (${ROLE}, uidNumber ${UID_NUMBER})"
}

function cmd_delete() {
  local USER=${1}
  local DN UID_NUMBER ROLES_NOW ROLE

  require_user "${USER}"
  DN=$(user_dn "${USER}")
  # read before the delete, to cut the sessions after it
  UID_NUMBER=$(uid_number_of "${USER}") || die 'could not search the directory'
  ROLES_NOW=$(roles_of "${USER}") || die 'could not search the directory'

  for ROLE in ${ROLES_NOW}; do
    ldap ldapmodify > /dev/null <<EOF || die "could not take ${USER} out of ${ROLE}"
dn: cn=${ROLE},${ROLES_DN}
changetype: modify
delete: uniqueMember
uniqueMember: ${DN}
EOF
  done
  ldap ldapdelete "${DN}" < /dev/null || die "could not delete ${USER}"

  update_users
  cut_sessions "${UID_NUMBER}"
  echo "deleted ${USER}"
}

function cmd_role() {
  local USER=${1}
  local ROLE=${2}
  local DN UID_NUMBER CURRENT OLD LDIF=''

  require_user "${USER}"
  is_role "${ROLE}" || die "${ROLE}: no such role (${ROLES[*]})"
  DN=$(user_dn "${USER}")
  UID_NUMBER=$(uid_number_of "${USER}") || die 'could not search the directory'
  # a failed search must not pass for "no role": the old roles would stay
  CURRENT=$(roles_of "${USER}") || die 'could not search the directory'

  if [[ "${CURRENT}" == "${ROLE}" ]]; then
    echo "${USER} is ${ROLE} already"
    return 0
  fi

  # into the new role first, so that a failure leaves the user with a role
  if ! grep -q -x -F -- "${ROLE}" <<< "${CURRENT}"; then
    LDIF+="dn: cn=${ROLE},${ROLES_DN}"$'\n'"changetype: modify"$'\n'
    LDIF+="add: uniqueMember"$'\n'"uniqueMember: ${DN}"$'\n\n'
  fi
  for OLD in ${CURRENT}; do
    [[ "${OLD}" == "${ROLE}" ]] && continue
    LDIF+="dn: cn=${OLD},${ROLES_DN}"$'\n'"changetype: modify"$'\n'
    LDIF+="delete: uniqueMember"$'\n'"uniqueMember: ${DN}"$'\n\n'
  done
  printf '%s' "${LDIF}" | ldap ldapmodify > /dev/null || die "could not change the role of ${USER}"

  update_users
  cut_sessions "${UID_NUMBER}"
  echo "${USER} is ${ROLE} now"
}

function cmd_passwd() {
  local USER=${1}
  local FULL_NAME

  require_user "${USER}"
  FULL_NAME=$(full_name_of "${USER}") || die 'could not search the directory'
  FULL_NAME=${FULL_NAME//$'\n'/ }

  read_password
  check_password "${USER}" "${FULL_NAME}"
  set_password "${USER}" || die "could not set the password of ${USER}"
  echo "set the password of ${USER}"
}

# the lock of ppolicy. It also ends by itself, and with a new password.
function cmd_unlock() {
  local USER=${1}
  local STATE ATTR LDIF=''

  require_user "${USER}"
  STATE=$(ldap_search -b "$(user_dn "${USER}")" -s base pwdAccountLockedTime pwdFailureTime) \
    || die 'could not search the directory'

  if [[ -z "$(values_of pwdAccountLockedTime <<< "${STATE}")" ]]; then
    echo "${USER} is not locked"
    return 0
  fi
  # The count of the failures goes too, or the next one would lock again.
  # It is not open to changes, so this needs the relax control.
  for ATTR in pwdAccountLockedTime pwdFailureTime; do
    if [[ -n "$(values_of ${ATTR} <<< "${STATE}")" ]]; then
      [[ -n "${LDIF}" ]] && LDIF+="-"$'\n'
      LDIF+="delete: ${ATTR}"$'\n'
    fi
  done

  printf 'dn: %s\nchangetype: modify\n%s' "$(user_dn "${USER}")" "${LDIF}" \
  | ldap ldapmodify -e relax > /dev/null || die "could not unlock ${USER}"
  echo "unlocked ${USER}"
}

[[ $# -ge 1 ]] || usage
COMMAND=${1}
shift

case ${COMMAND} in
  add)    [[ $# -eq 2 || $# -eq 3 ]] || usage; cmd_add "$@" ;;
  delete) [[ $# -eq 1 ]] || usage; cmd_delete "$@" ;;
  role)   [[ $# -eq 2 ]] || usage; cmd_role "$@" ;;
  passwd) [[ $# -eq 1 ]] || usage; cmd_passwd "$@" ;;
  unlock) [[ $# -eq 1 ]] || usage; cmd_unlock "$@" ;;
  *)      usage ;;
esac
