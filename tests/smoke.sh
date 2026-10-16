#!/bin/bash
#
# Smoke test for the AAA path (FreeRADIUS -> LDAPS -> OpenLDAP) and for
# the workspace container (ssh -> OpenSSH -> LDAPS -> OpenLDAP).
#
# Starts the stack as a separate compose project
# on an empty directory, and makes the test accounts with
# bin/manage_users.sh. Checks the reply for every combination of reply
# type and role, then that the detail logs survive a rotation, then
# that FreeRADIUS, syslog-ng and tftpd-hpa take nothing from outside the
# networks of the devices, and that tftpd-hpa records a transfer in a file, then
# logs in over ssh as each role, then manages a user
# with bin/manage_users.sh, then runs into the password policy of
# OpenLDAP, then changes the passwords of the service accounts and of
# the administrators of OpenLDAP, then takes a backup and restores it
# into an openldap made again. The running stack is left alone: the
# test generates its own passwords, LDIFs and ldap_openldap into
# tests/generated.
#
#   KEEP=1 tests/smoke.sh    leave the test stack up for a closer look

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR%/*}"

cd "${ROOT_DIR}"

COMPOSE=(docker compose -p koitohan-test -f compose.yaml -f tests/compose.test.yaml)
# the scripts under scripts/, bin/change_service_account_password.sh
# and bin/change_ldap_admin_password.sh write here instead of secrets/,
# openldap/ldif/ and freeradius/config/
export KOITOHAN_GENERATED_ROOT="${ROOT_DIR}/tests/generated"
SECRET='testing123'
# The networks of the devices, whatever .env has: the test sends from
# the Docker host, which the containers see as the gateway of their
# network. Docker takes that from the private addresses.
ALLOWED_NETWORKS='10.0.0.0/8 172.16.0.0/12 192.168.0.0/16'
# a network the test never sends from (TEST-NET-1)
OTHER_NETWORKS='192.0.2.0/24'
export DEVICE_NETWORKS="${ALLOWED_NETWORKS}"
# the same for the networks of the terminals: ssh goes from the Docker host
export OPENSSH_ALLOWED_NETWORKS="${ALLOWED_NETWORKS}"
WAIT_TRIES=40

function cleanup() {
  rm -f "${ASKPASS}"
  if [[ -n "${KEEP}" ]]; then
    echo "test stack left up: ${COMPOSE[*]} down -v && rm -rf tests/generated"
  else
    "${COMPOSE[@]}" down -v > /dev/null 2>&1
    rm -rf "${KOITOHAN_GENERATED_ROOT}"
  fi
}

# The test accounts. The passwords have to pass passwdqc (PASSWDQC_MIN).
# They go into the tables of cases and into quoted commands, so keep
# them free of quotes, backslashes, '$' and '|'.
PASS_ADMIN='Kd7-wPq2.Xm9+Rt4z'
PASS_OPERATOR='Vb3_hJy8=Ns5.Lc6w'
PASS_READONLY='Tz6+mGf4-Qr9_Hk2x'
PASS_NOROLE='Wn8.cDs3+Yp7=Fj5v'

function password_of() {
  case ${1} in
    admin01)    echo "${PASS_ADMIN}" ;;
    operator01) echo "${PASS_OPERATOR}" ;;
    readonly01) echo "${PASS_READONLY}" ;;
    norole01)   echo "${PASS_NOROLE}" ;;
    *)          echo 'nopass' ;;
  esac
}

# send an Access-Request from the given source address
function send_request() {
  local SRC=${1}
  local USER=${2}
  local PASS=${3}

  "${COMPOSE[@]}" exec -T freeradius radclient -x -t 5 -r 1 127.0.0.1:1812 auth ${SECRET} 2>&1 \
    <<< "User-Name = \"${USER}\", User-Password = \"${PASS}\", Net.Src.IP = ${SRC}"
}

# the attributes of the reply, without Message-Authenticator
function reply_attrs() {
  sed -n '/^Received /,$p' \
  | grep -v -e '^Received ' -e '^(' -e 'Message-Authenticator'
}

# OpenLDAP listens on LDAPS once it has loaded the seed LDIFs, and the
# openssh container can read the users from then on
function wait_ldap_ready() {
  local TRY

  for (( TRY = 1; TRY <= WAIT_TRIES; TRY++ )); do
    if "${COMPOSE[@]}" exec -T openssh koitohan-update-users > /dev/null 2>&1; then
      return 0
    fi
    sleep 3
  done
  return 1
}

# FreeRADIUS answers once it has started and reached OpenLDAP
function wait_ready() {
  local TRY

  for (( TRY = 1; TRY <= WAIT_TRIES; TRY++ )); do
    if send_request 127.0.0.1 admin01 "${PASS_ADMIN}" | grep -q '^Received Access-Accept'; then
      return 0
    fi
    sleep 3
  done
  return 1
}

FAILED=0
COUNT=0

# for sh in the openldap container, which has LDAP_DOMAIN
LDAP_SUFFIX_SET='SUFFIX="dc=$(echo "${LDAP_DOMAIN}" | sed "s/\./,dc=/g")"'

# EXPECT is a fixed string to find in the reply. '-' means that the
# reply carries no attributes.
function check() {
  local NAME=${1}
  local SRC=${2}
  local USER=${3}
  local PASS=${4}
  local CODE=${5}
  local EXPECT=${6}
  local OUT ATTRS WHY=''

  OUT=$(send_request ${SRC} ${USER} ${PASS})
  ATTRS=$(reply_attrs <<< "${OUT}")

  if ! grep -q "^Received Access-${CODE}" <<< "${OUT}"; then
    WHY="expected Access-${CODE}"
  elif [[ "${EXPECT}" == '-' ]]; then
    [[ -z "${ATTRS}" ]] || WHY='expected no attributes'
  elif ! grep -q -F -- "${EXPECT}" <<< "${ATTRS}"; then
    WHY="expected ${EXPECT}"
  fi

  COUNT=$((COUNT + 1))
  if [[ -z "${WHY}" ]]; then
    printf 'ok    %-13s %-11s %s\n' "${NAME}" "${USER}" "Access-${CODE}"
  else
    FAILED=$((FAILED + 1))
    printf 'FAIL  %-13s %-11s %s\n' "${NAME}" "${USER}" "${WHY}"
    sed 's/^/      | /' <<< "${OUT}"
  fi
}

# The test stack publishes no ports, so ssh goes to the address of the
# container. ssh takes the password from SSH_ASKPASS (OpenSSH 8.4 or later).
SSH_OPTS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o PreferredAuthentications=password
  -o PubkeyAuthentication=no
  -o NumberOfPasswordPrompts=1
  -o ConnectTimeout=5
  -o LogLevel=ERROR
)

function ssh_run() {
  local USER=${1}
  local PASS=${2}
  shift 2

  SSH_TEST_PASS="${PASS}" SSH_ASKPASS="${ASKPASS}" SSH_ASKPASS_REQUIRE=force \
  ssh "${SSH_OPTS[@]}" "${USER}@${SSH_ADDR}" "$@" 2>&1
}

# sshd starts once the container has read the users from OpenLDAP
function wait_ssh_ready() {
  local TRY

  for (( TRY = 1; TRY <= WAIT_TRIES; TRY++ )); do
    SSH_ADDR=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
      "$("${COMPOSE[@]}" ps -q openssh)" 2> /dev/null)
    if [[ -n "${SSH_ADDR}" ]] && ssh_run admin01 "${PASS_ADMIN}" true < /dev/null > /dev/null; then
      return 0
    fi
    sleep 3
  done
  return 1
}

# Runs COMMAND over ssh. EXPECT is a fixed string to find in the output.
# 'denied' means that the login itself has to fail. INPUT goes to the
# standard input of the command.
function check_ssh() {
  local NAME=${1}
  local USER=${2}
  local PASS=${3}
  local EXPECT=${4}
  local COMMAND=${5}
  local INPUT=${6}
  local OUT WHY=''

  OUT=$(printf '%b' "${INPUT}" | ssh_run ${USER} "${PASS}" "${COMMAND}")

  if [[ "${EXPECT}" == 'denied' ]]; then
    grep -q -F 'Permission denied (password)' <<< "${OUT}" || WHY='expected the login to fail'
  elif ! grep -q -F -- "${EXPECT}" <<< "${OUT}"; then
    WHY="expected ${EXPECT}"
  fi

  COUNT=$((COUNT + 1))
  if [[ -z "${WHY}" ]]; then
    printf 'ok    %-13s %-11s %s\n' "${NAME}" "${USER}" "${EXPECT}"
  else
    FAILED=$((FAILED + 1))
    printf 'FAIL  %-13s %-11s %s\n' "${NAME}" "${USER}" "${WHY}"
    sed 's/^/      | /' <<< "${OUT}"
  fi
}

# The files in the openssh container that hold a password or a private
# key. A user who logs in must not read any of them.
SECRET_FILES=(
  /run/koitohan/bindpw
  /etc/koitohan/secrets/bindpw
  /etc/koitohan/certs/client.key
  /run/koitohan/nslcd-certs/client.key
  /etc/nslcd.conf
  /etc/koitohan/hostkeys/ssh_host_ed25519_key
  /etc/koitohan/hostkeys/ssh_host_rsa_key
)

# Checks that USER can read none of SECRET_FILES. It asks only whether
# a file is readable, so nothing of a file comes into the output. The
# files have to be there, or a file that has moved would pass.
function check_secrets() {
  local USER=${1}
  local PASS=${2}
  local OUT WHY=''

  OUT=$("${COMPOSE[@]}" exec -T openssh sh -c "
    for F in ${SECRET_FILES[*]}; do [ -e \"\${F}\" ] || echo \"\${F}: missing\"; done" 2>&1)
  if [[ -n "${OUT}" ]]; then
    WHY='expected the files to be there'
  else
    OUT=$(ssh_run ${USER} "${PASS}" "
      for F in ${SECRET_FILES[*]}; do [ -r \"\${F}\" ] && echo \"\${F}: readable\"; done; echo checked" < /dev/null)
    if grep -q -F ': readable' <<< "${OUT}"; then
      WHY='expected no file to be readable'
    elif ! grep -q -x checked <<< "${OUT}"; then
      WHY='expected to log in'
    fi
  fi

  COUNT=$((COUNT + 1))
  if [[ -z "${WHY}" ]]; then
    printf 'ok    %-13s %-11s %s\n' 'secrets' "${USER}" 'none readable'
  else
    FAILED=$((FAILED + 1))
    printf 'FAIL  %-13s %-11s %s\n' 'secrets' "${USER}" "${WHY}"
    sed 's/^/      | /' <<< "${OUT}"
  fi
}

# The root file system of SERVICE is read-only (read_only: true). root
# writes there, so nothing but the mount can stop it.
function check_read_only() {
  local SERVICE=${1}
  local OUT WHY=''

  OUT=$("${COMPOSE[@]}" exec -T "${SERVICE}" sh -c '
    touch /koitohan-smoke; rm -f /koitohan-smoke' 2>&1)
  grep -q -F 'Read-only file system' <<< "${OUT}" || WHY='expected a read-only file system'

  COUNT=$((COUNT + 1))
  if [[ -z "${WHY}" ]]; then
    printf 'ok    %-13s %-11s %s\n' 'root fs' "${SERVICE}" 'read-only'
  else
    FAILED=$((FAILED + 1))
    printf 'FAIL  %-13s %-11s %s\n' 'root fs' "${SERVICE}" "${WHY}"
    sed 's/^/      | /' <<< "${OUT}"
  fi
}

# Runs bin/manage_users.sh against the test stack. EXPECT is a fixed
# string to find in the output. INPUT is the password it reads.
function check_users() {
  local NAME=${1}
  local EXPECT=${2}
  local INPUT=${3}
  shift 3
  local OUT WHY=''

  OUT=$(COMPOSE_PROJECT_NAME=koitohan-test COMPOSE_FILE=compose.yaml:tests/compose.test.yaml \
        bin/manage_users.sh "$@" 2>&1 <<< "${INPUT}")
  grep -q -F -- "${EXPECT}" <<< "${OUT}" || WHY="expected ${EXPECT}"

  COUNT=$((COUNT + 1))
  if [[ -z "${WHY}" ]]; then
    printf 'ok    %-13s %-11s %s\n' "${NAME}" "${2}" "${EXPECT}"
  else
    FAILED=$((FAILED + 1))
    printf 'FAIL  %-13s %-11s %s\n' "${NAME}" "${2}" "${WHY}"
    sed 's/^/      | /' <<< "${OUT}"
  fi
}

# Runs COMMAND with sh in the openldap container, where SUFFIX is the
# suffix of the directory. EXPECT is a fixed string to find in the
# output. INPUT goes to the standard input of the command.
function check_ldap() {
  local NAME=${1}
  local USER=${2}
  local EXPECT=${3}
  local COMMAND=${4}
  local INPUT=${5}
  local OUT WHY=''

  OUT=$(printf '%b' "${INPUT}" \
        | "${COMPOSE[@]}" exec -T openldap sh -c "${LDAP_SUFFIX_SET}; ${COMMAND}" 2>&1)
  grep -q -F -- "${EXPECT}" <<< "${OUT}" || WHY="expected ${EXPECT}"

  COUNT=$((COUNT + 1))
  if [[ -z "${WHY}" ]]; then
    printf 'ok    %-13s %-11s %s\n' "${NAME}" "${USER}" "${EXPECT}"
  else
    FAILED=$((FAILED + 1))
    printf 'FAIL  %-13s %-11s %s\n' "${NAME}" "${USER}" "${WHY}"
    sed 's/^/      | /' <<< "${OUT}"
  fi
}

# Runs bin/change_service_account_password.sh against the test stack.
# EXPECT is a fixed string to find in the output.
function check_service_password() {
  local SERVICE=${1}
  local EXPECT=${2}
  local OUT WHY=''

  OUT=$(COMPOSE_PROJECT_NAME=koitohan-test COMPOSE_FILE=compose.yaml:tests/compose.test.yaml \
        bin/change_service_account_password.sh "${SERVICE}" 2>&1 < /dev/null)
  grep -q -F -- "${EXPECT}" <<< "${OUT}" || WHY="expected ${EXPECT}"

  COUNT=$((COUNT + 1))
  if [[ -z "${WHY}" ]]; then
    printf 'ok    %-13s %-11s %s\n' 'service pass' "${SERVICE}" "${EXPECT}"
  else
    FAILED=$((FAILED + 1))
    printf 'FAIL  %-13s %-11s %s\n' 'service pass' "${SERVICE}" "${WHY}"
    sed 's/^/      | /' <<< "${OUT}"
  fi
}

# Binds as an administrator of OpenLDAP (admin or config). EXPECT is a
# fixed string to find in the output.
function check_admin_bind() {
  local NAME=${1}
  local WHICH=${2}
  local PASS=${3}
  local EXPECT=${4}
  local DN='cn=admin,${SUFFIX}'

  [[ "${WHICH}" == 'config' ]] && DN='cn=admin,cn=config'
  check_ldap "${NAME}" "${WHICH}" "${EXPECT}" \
    "ldapwhoami -x -H ldapi:/// -D \"${DN}\" -y /dev/stdin" "${PASS}"
}

# The same container has to start a second time, as it does after a
# reboot of the host. This asks slapd itself and leaves FreeRADIUS out.
function check_restart() {
  local TRY WHY='expected a bind to succeed'
  local DN='uid=admin01,ou=People,${SUFFIX}'
  local BIND="${LDAP_SUFFIX_SET}; ldapwhoami -x -H ldapi:/// -w '${PASS_ADMIN}' -D \"${DN}\""

  "${COMPOSE[@]}" restart openldap > /dev/null 2>&1
  for (( TRY = 1; TRY <= WAIT_TRIES; TRY++ )); do
    if [[ -z "$("${COMPOSE[@]}" ps --status running -q openldap)" ]]; then
      WHY='openldap exited'
      break
    fi
    if "${COMPOSE[@]}" exec -T openldap sh -c "${BIND}" > /dev/null 2>&1; then
      WHY=''
      break
    fi
    sleep 3
  done

  COUNT=$((COUNT + 1))
  if [[ -z "${WHY}" ]]; then
    printf 'ok    %-13s %-11s %s\n' 'ldap restart' admin01 'bind'
  else
    FAILED=$((FAILED + 1))
    printf 'FAIL  %-13s %-11s %s\n' 'ldap restart' admin01 "${WHY}"
    "${COMPOSE[@]}" logs --tail 5 openldap 2>&1 | sed 's/^/      | /'
  fi
}

# sshd has to listen (seen from inside, over the loopback) and still
# take no connection from the Docker host. Not even a wrong password
# gets through, which would count against the lock of the user.
function check_ssh_other_network() {
  local OUT TRY WHY='sshd did not start'

  OPENSSH_ALLOWED_NETWORKS="${OTHER_NETWORKS}" "${COMPOSE[@]}" up -d --force-recreate openssh > /dev/null 2>&1
  for (( TRY = 1; TRY <= WAIT_TRIES; TRY++ )); do
    if "${COMPOSE[@]}" exec -T openssh nc -z -w 1 127.0.0.1 22 > /dev/null 2>&1; then
      WHY=''
      break
    fi
    sleep 3
  done
  if [[ -z "${WHY}" ]]; then
    SSH_ADDR=$(address_of openssh)
    OUT=$(ssh_run admin01 "${PASS_ADMIN}" true < /dev/null)
    grep -q -F 'timed out' <<< "${OUT}" || WHY='expected the connection to time out'
  fi

  COUNT=$((COUNT + 1))
  if [[ -z "${WHY}" ]]; then
    printf 'ok    %-13s %-11s %s\n' 'networks' 'other' 'ssh timed out'
  else
    FAILED=$((FAILED + 1))
    printf 'FAIL  %-13s %-11s %s\n' 'networks' 'other' "${WHY}"
    sed 's/^/      | /' <<< "${OUT}"
    "${COMPOSE[@]}" logs --tail 5 openssh 2>&1 | sed 's/^/      | /'
  fi
}

function address_of() {
  docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
    "$("${COMPOSE[@]}" ps -q ${1})" 2> /dev/null
}

# Sends an Access-Request to the address of the freeradius container
# from another container of the same image, on the same network: the
# Docker host has no radclient. EXPECT is 'Accept' or 'timed out'.
function check_radius_networks() {
  local NAME=${1}
  local EXPECT=${2}
  local ADDR OUT WHY=''

  ADDR=$(address_of freeradius)
  OUT=$("${COMPOSE[@]}" run --rm --no-deps -T --entrypoint radclient freeradius \
          -x -t 3 -r 1 "${ADDR}:1812" auth ${SECRET} 2>&1 \
        <<< "User-Name = \"admin01\", User-Password = \"${PASS_ADMIN}\"")
  if [[ "${EXPECT}" == 'timed out' ]]; then
    if grep -q '^Received ' <<< "${OUT}" || ! grep -q -F 'No reply' <<< "${OUT}"; then
      WHY='expected no reply'
    fi
  elif ! grep -q "^Received Access-${EXPECT}" <<< "${OUT}"; then
    WHY="expected Access-${EXPECT}"
  fi

  COUNT=$((COUNT + 1))
  if [[ -z "${WHY}" ]]; then
    printf 'ok    %-13s %-11s %s\n' 'networks' "${NAME}" "radius ${EXPECT}"
  else
    FAILED=$((FAILED + 1))
    printf 'FAIL  %-13s %-11s %s\n' 'networks' "${NAME}" "${WHY}"
    sed 's/^/      | /' <<< "${OUT}"
    "${COMPOSE[@]}" logs --tail 5 freeradius 2>&1 | sed 's/^/      | /'
  fi
}

# the number of messages that have come in to syslog-ng, before the
# filter. Empty while syslog-ng does not answer on its control socket.
function syslog_count() {
  "${COMPOSE[@]}" exec -T syslog-ng syslog-ng-ctl stats --control=/config/syslog-ng.ctl 2> /dev/null \
  | awk -F ';' '$1 == "source" && $2 == "s_network" { print $6 }'
}

# Sends a syslog message from the Docker host to the address of the
# container. EXPECT is 'received' or 'dropped'. syslog-ng says nothing
# about a message it drops, so a message counts as dropped only when
# syslog-ng has taken it in and has not written it: one that never got
# there says nothing about the filter.
function check_syslog_networks() {
  local NAME=${1}
  local EXPECT=${2}
  local LOG="/var/log/Hosts/smoke-${NAME}/smoke-${NAME}.log"
  local ADDR TRY BEFORE='' AFTER='' GOT='dropped' WHY=''

  # syslog-ng takes a while to start
  for (( TRY = 1; TRY <= WAIT_TRIES; TRY++ )); do
    BEFORE=$(syslog_count)
    [[ -n "${BEFORE}" ]] && break
    sleep 1
  done
  ADDR=$(address_of syslog-ng)
  if [[ -z "${BEFORE}" ]]; then
    WHY='syslog-ng did not start'
  elif [[ -z "${ADDR}" ]]; then
    WHY='could not find the address of syslog-ng'
  elif ! echo "<134>Jan  1 00:00:00 smoke-${NAME} smoke: koitohan-smoke" > "/dev/udp/${ADDR}/1514"; then
    WHY='could not send the message'
  else
    for TRY in 1 2 3 4 5; do
      AFTER=$(syslog_count)
      [[ ${AFTER:-0} -gt ${BEFORE} ]] && break
      sleep 1
    done
    if [[ ${AFTER:-0} -le ${BEFORE} ]]; then
      WHY='the message did not reach syslog-ng'
    else
      for TRY in 1 2 3 4 5; do
        if "${COMPOSE[@]}" exec -T syslog-ng grep -q -F koitohan-smoke "${LOG}" 2> /dev/null; then
          GOT='received'
          break
        fi
        sleep 1
      done
      [[ "${GOT}" == "${EXPECT}" ]] || WHY="expected the message to be ${EXPECT}"
    fi
  fi

  COUNT=$((COUNT + 1))
  if [[ -z "${WHY}" ]]; then
    printf 'ok    %-13s %-11s %s\n' 'networks' "${NAME}" "syslog ${EXPECT}"
  else
    FAILED=$((FAILED + 1))
    printf 'FAIL  %-13s %-11s %s\n' 'networks' "${NAME}" "${WHY}"
    "${COMPOSE[@]}" logs --tail 5 syslog-ng 2>&1 | sed 's/^/      | /'
  fi
}

# Fetches a file over TFTP from the Docker host to the address of the
# container. EXPECT is a fixed string to find in the file, or 'timed out'.
# A transfer times out as well when in.tftpd does not answer at all, so
# before that, the file has to come over the loopback, which the rules
# always let through. The client of tftp-hpa exits with 0 on an error
# as well, so what it fetched is what counts.
function check_tftp_networks() {
  local NAME=${1}
  local EXPECT=${2}
  local ADDR OUT='' WHY=''

  ADDR=$(address_of tftpd-hpa)
  if [[ -z "${ADDR}" ]]; then
    WHY='could not find the address of tftpd-hpa'
  elif [[ "${EXPECT}" == 'timed out' ]]; then
    OUT=$("${COMPOSE[@]}" exec -T tftpd-hpa \
            timeout 5 tftp -m octet 127.0.0.1 -c get firmware/smoke.txt /dev/stdout 2>&1)
    if ! grep -q -F koitohan-smoke <<< "${OUT}"; then
      WHY='tftpd-hpa does not answer on the loopback'
    else
      OUT=$(curl -s -S -m 5 "tftp://${ADDR}/firmware/smoke.txt" 2>&1)
      grep -q -i -F 'timed out' <<< "${OUT}" || WHY='expected the transfer to time out'
    fi
  else
    OUT=$(curl -s -S -m 5 "tftp://${ADDR}/firmware/smoke.txt" 2>&1)
    grep -q -F -- "${EXPECT}" <<< "${OUT}" || WHY="expected ${EXPECT}"
  fi

  COUNT=$((COUNT + 1))
  if [[ -z "${WHY}" ]]; then
    printf 'ok    %-13s %-11s %s\n' 'networks' "${NAME}" "tftp ${EXPECT}"
  else
    FAILED=$((FAILED + 1))
    printf 'FAIL  %-13s %-11s %s\n' 'networks' "${NAME}" "${WHY}"
    sed 's/^/      | /' <<< "${OUT}"
    "${COMPOSE[@]}" logs --tail 5 tftpd-hpa 2>&1 | sed 's/^/      | /'
  fi
}

# logrotate on the Docker host moves the detail logs away and makes no
# new ones (scripts/generate_logrotate.sh), so FreeRADIUS has to.
function check_detail() {
  local DIR=/var/log/freeradius/radacct/127.0.0.1
  local OUT WHY=''

  OUT=$("${COMPOSE[@]}" exec -T freeradius sh -c "
    mv ${DIR}/auth-detail ${DIR}/auth-detail-moved \\
    && mv ${DIR}/reply-detail ${DIR}/reply-detail-moved" 2>&1) \
  || WHY='expected auth-detail and reply-detail'
  if [[ -z "${WHY}" ]]; then
    send_request 127.0.0.1 admin01 "${PASS_ADMIN}" > /dev/null
    OUT=$("${COMPOSE[@]}" exec -T freeradius sh -c "
      test -s ${DIR}/auth-detail && test -s ${DIR}/reply-detail || ls -l ${DIR}" 2>&1) \
    && [[ -z "${OUT}" ]] || WHY='expected new files after the move'
  fi

  COUNT=$((COUNT + 1))
  if [[ -z "${WHY}" ]]; then
    printf 'ok    %-13s %-11s %s\n' 'detail log' admin01 'made again'
  else
    FAILED=$((FAILED + 1))
    printf 'FAIL  %-13s %-11s %s\n' 'detail log' admin01 "${WHY}"
    sed 's/^/      | /' <<< "${OUT}"
  fi
}

# The record of a transfer goes to a file as well as to the standard
# output. logrotate on the Docker host moves the file away and makes no
# new one (scripts/generate_logrotate.sh), so syslogd has to.
function check_tftp_log() {
  local LOG=/var/log/tftpd/tftpd.log
  local RECORD='RRQ from .* filename firmware/smoke.txt'
  local ADDR OUT WHY=''

  ADDR=$(address_of tftpd-hpa)
  OUT=$("${COMPOSE[@]}" exec -T tftpd-hpa sh -c "
    grep -q '${RECORD}' ${LOG} && mv ${LOG} ${LOG}-moved" 2>&1) \
  || WHY='expected the record of the transfer in tftpd.log'
  if [[ -z "${WHY}" ]]; then
    # syslogd opens the file again once a second, not for every line.
    # What it writes within the second of the move goes to the old file.
    sleep 2
    curl -s -S -m 5 -o /dev/null "tftp://${ADDR}/firmware/smoke.txt" 2> /dev/null
    OUT=$("${COMPOSE[@]}" exec -T tftpd-hpa sh -c "
      grep -q '${RECORD}' ${LOG} || ls -l /var/log/tftpd" 2>&1) \
    && [[ -z "${OUT}" ]] || WHY='expected a new file after the move'
  fi

  COUNT=$((COUNT + 1))
  if [[ -z "${WHY}" ]]; then
    printf 'ok    %-13s %-11s %s\n' 'tftp log' 'smoke.txt' 'recorded, made again'
  else
    FAILED=$((FAILED + 1))
    printf 'FAIL  %-13s %-11s %s\n' 'tftp log' 'smoke.txt' "${WHY}"
    sed 's/^/      | /' <<< "${OUT}"
    "${COMPOSE[@]}" logs --tail 5 tftpd-hpa 2>&1 | sed 's/^/      | /'
  fi
}

# OpenLDAP takes TLS 1.3 and nothing older. The handshake comes from
# the Docker host, with the client certificate of FreeRADIUS. A refusal
# has to be the alert for the version: a handshake that fails for any
# other reason says nothing about it. Without an address, openssl goes
# to the loopback, where the running stack may listen.
function check_tls() {
  local VERSION=${1}
  local EXPECT=${2}
  local ADDR OUT='' GOT WHY=''

  ADDR=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' \
    "$("${COMPOSE[@]}" ps -q openldap)" 2> /dev/null | cut -d ' ' -f 1)
  if [[ -z "${ADDR}" ]]; then
    WHY='could not find the address of openldap'
  else
    OUT=$(timeout 10 openssl s_client -connect "${ADDR}:636" "-${VERSION}" \
      -CAfile CA/default-ca.pem \
      -cert CA/freeradius_client.crt -key CA/freeradius_client.key < /dev/null 2>&1)

    if grep -q '^New, TLSv' <<< "${OUT}"; then
      GOT='accepted'
    elif grep -q -F 'alert protocol version' <<< "${OUT}"; then
      GOT='refused'
    else
      GOT='failed'
    fi
    [[ "${GOT}" == "${EXPECT}" ]] || WHY="expected ${EXPECT}, got ${GOT}"
  fi

  COUNT=$((COUNT + 1))
  if [[ -z "${WHY}" ]]; then
    printf 'ok    %-13s %-11s %s\n' 'tls' "${VERSION}" "${GOT}"
  else
    FAILED=$((FAILED + 1))
    printf 'FAIL  %-13s %-11s %s\n' 'tls' "${VERSION}" "${WHY}"
    grep -v -e '^-----' -e '^[A-Za-z0-9+/=]\{64\}$' <<< "${OUT}" | head -n 20 | sed 's/^/      | /'
  fi
}

# a missing source of a file bind mount would be created as a directory
for FILE in \
  CA/default-ca.pem \
  CA/openldap_server.crt \
  CA/freeradius_client.crt \
  CA/openssh_client.crt \
  openssh/hostkeys/ssh_host_ed25519_key
do
  if [[ ! -e "${FILE}" ]]; then
    echo "${FILE} is missing. Run 'make' first, then 'make test'."
    exit 1
  fi
done

ASKPASS=$(mktemp)
printf '#!/bin/sh\necho "${SSH_TEST_PASS}"\n' > "${ASKPASS}"
chmod 700 "${ASKPASS}"

trap cleanup EXIT

# The same scripts as make runs, on passwords of the test's own
rm -rf "${KOITOHAN_GENERATED_ROOT}"
mkdir -p "${KOITOHAN_GENERATED_ROOT}"/{secrets,openldap/ldif,freeradius/config/mods-available,syslog-ng/config}
if ! { scripts/generate_service_account_password.sh freeradius \
       && scripts/generate_service_account_password.sh openssh \
       && scripts/generate_ldap_admin_password.sh admin \
       && scripts/generate_ldap_admin_password.sh config \
       && scripts/generate_ldap_base.sh \
       && scripts/generate_freeradius_ldap.sh \
       && scripts/generate_device_networks.sh; }; then
  echo 'could not generate the files of the test stack'
  exit 1
fi

echo 'starting the test stack'
if ! "${COMPOSE[@]}" up -d --build > /dev/null 2>&1; then
  echo 'failed to start the test stack'
  "${COMPOSE[@]}" up -d --build
  exit 1
fi

if ! wait_ldap_ready; then
  echo 'the test stack did not become ready'
  "${COMPOSE[@]}" logs --tail 30 openldap openssh
  exit 1
fi

# The test accounts. bin/manage_users.sh does not make a user without a
# role, so norole01 is made by hand, and first: the numbers of the
# script have to start after it.
AS_MANAGER='-Q -Y EXTERNAL -H ldapi:///'
check_ldap 'by hand' norole01 'made norole01' "
  printf 'dn: uid=norole01,ou=People,%s\nobjectClass: inetOrgPerson\nobjectClass: posixAccount\nuid: norole01\nuidNumber: 10000\ngidNumber: 10000\nhomeDirectory: /home/norole01\nloginShell: /bin/sh\ncn: norole01\nsn: norole01\n' \"\${SUFFIX}\" \\
  | ldapadd ${AS_MANAGER} > /dev/null \\
  && ldappasswd ${AS_MANAGER} -s '${PASS_NOROLE}' \"uid=norole01,ou=People,\${SUFFIX}\" \\
  && echo 'made norole01'"
check_users 'users add' 'uidNumber 10001' "${PASS_ADMIN}" add admin01 admin
check_users 'users add' 'uidNumber 10002' "${PASS_OPERATOR}" add operator01 operator
check_users 'users add' 'uidNumber 10003' "${PASS_READONLY}" add readonly01 readonly

if [[ ${FAILED} -ne 0 ]]; then
  echo 'could not make the test accounts'
  exit 1
fi

if ! wait_ready; then
  echo 'FreeRADIUS did not become ready'
  "${COMPOSE[@]}" logs --tail 30 freeradius
  exit 1
fi

# client (tests/clients.conf) | source | user | reply | expected attribute
while IFS='|' read -r NAME SRC USER CODE EXPECT; do
  check "${NAME}" "${SRC}" "${USER}" "$(password_of ${USER})" "${CODE}" "${EXPECT}"
done <<'CASES'
cisco|127.0.0.1|admin01|Accept|AVPair = "shell:priv-lvl=15"
cisco|127.0.0.1|operator01|Accept|AVPair = "shell:priv-lvl=7"
cisco|127.0.0.1|readonly01|Accept|AVPair = "shell:priv-lvl=1"
cisco|127.0.0.1|norole01|Reject|-
aruba-cx|127.0.0.2|admin01|Accept|Priv-Admin-User = 15
aruba-cx|127.0.0.2|operator01|Accept|Priv-Admin-User = 7
aruba-cx|127.0.0.2|readonly01|Accept|Priv-Admin-User = 1
aruba-cx|127.0.0.2|norole01|Reject|-
aruba-ap|127.0.0.3|admin01|Accept|-
aruba-ap|127.0.0.3|operator01|Reject|no administration role for 'operator'
aruba-ap|127.0.0.3|readonly01|Reject|no administration role for 'readonly'
aruba-ap|127.0.0.3|norole01|Reject|-
fortinet|127.0.0.4|admin01|Accept|Group-Name = "super_admin"
fortinet|127.0.0.4|operator01|Accept|Group-Name = "readonly"
fortinet|127.0.0.4|readonly01|Accept|Group-Name = "readonly"
fortinet|127.0.0.4|norole01|Reject|-
juniper|127.0.0.5|admin01|Accept|Local-User-Name = "superuser"
juniper|127.0.0.5|operator01|Accept|Local-User-Name = "operator"
juniper|127.0.0.5|readonly01|Accept|Local-User-Name = "read-only"
juniper|127.0.0.5|norole01|Reject|-
palo-alto|127.0.0.6|admin01|Accept|Admin-Role = "superuser"
palo-alto|127.0.0.6|operator01|Accept|Admin-Role = "readonly"
palo-alto|127.0.0.6|readonly01|Accept|Admin-Role = "readonly"
palo-alto|127.0.0.6|norole01|Reject|-
service-type|127.0.0.7|admin01|Accept|Service-Type = ::Administrative-User
service-type|127.0.0.7|operator01|Accept|Service-Type = ::NAS-Prompt-User
service-type|127.0.0.7|readonly01|Accept|Service-Type = ::Login-User
service-type|127.0.0.7|norole01|Reject|-
ietf-mpl|127.0.0.8|admin01|Accept|Management-Privilege-Level = 15
ietf-mpl|127.0.0.8|operator01|Accept|Management-Privilege-Level = 7
ietf-mpl|127.0.0.8|readonly01|Accept|Management-Privilege-Level = 1
ietf-mpl|127.0.0.8|norole01|Reject|-
none|127.0.0.9|admin01|Accept|-
none|127.0.0.9|operator01|Accept|-
none|127.0.0.9|readonly01|Accept|-
none|127.0.0.9|norole01|Reject|-
unknown|127.0.0.10|admin01|Accept|Management-Privilege-Level = 15
unknown|127.0.0.10|readonly01|Accept|unknown nas_type: 'bogus'
unknown|127.0.0.10|norole01|Reject|-
CASES

check 'bad password' 127.0.0.1 admin01 wrong Reject '-'
check 'unknown user' 127.0.0.1 nobody01 nopass Reject '-'

check_detail

check_tls tls1_3 accepted
check_tls tls1_2 refused

# The limit on the source of RADIUS, syslog and TFTP. The same request,
# message and file, first from a network that is allowed, then with the
# containers made again for another network. In between, the file
# that keeps the record of the transfer. The other requests of this
# test come from the loopback, which FreeRADIUS always allows.
"${COMPOSE[@]}" exec -T tftpd-hpa sh -c 'echo koitohan-smoke > /tftpboot/firmware/smoke.txt'
check_radius_networks allowed 'Accept'
check_syslog_networks allowed 'received'
check_tftp_networks allowed 'koitohan-smoke'
check_tftp_log
if ! { DEVICE_NETWORKS="${OTHER_NETWORKS}" scripts/generate_device_networks.sh \
       && DEVICE_NETWORKS="${OTHER_NETWORKS}" "${COMPOSE[@]}" up -d --force-recreate freeradius syslog-ng tftpd-hpa > /dev/null 2>&1; }; then
  echo 'could not make freeradius, syslog-ng and tftpd-hpa again'
  exit 1
fi
if ! wait_ready; then
  echo 'FreeRADIUS did not become ready again'
  "${COMPOSE[@]}" logs --tail 30 freeradius
  exit 1
fi
check_radius_networks other 'timed out'
check_syslog_networks other 'dropped'
check_tftp_networks other 'timed out'

if ! wait_ssh_ready; then
  echo 'the openssh container did not become ready'
  "${COMPOSE[@]}" logs --tail 30 openssh
  exit 1
fi

# a rotated log, as logrotate leaves it on the Docker host
"${COMPOSE[@]}" exec -T openssh sh -c '
  mkdir -p /logs/Hosts/smoke \
  && echo "smoke LINK-3" | gzip > /logs/Hosts/smoke/smoke.log-2026-10-10.gz'

NEW_PASS='x9#Kq!vT2m@Lz7Pw'
NEW_PASS2='Gh4$wN8^rB1&yD6s'
TOUCH='2> /dev/null && echo written || echo refused'

# name | user | password | expected output | command
while IFS='|' read -r NAME USER PASS EXPECT COMMAND; do
  check_ssh "${NAME}" "${USER}" "${PASS}" "${EXPECT}" "${COMMAND}" < /dev/null
done <<CASES
ssh login|admin01|${PASS_ADMIN}|koitohan admin|id -Gn
ssh login|operator01|${PASS_OPERATOR}|koitohan operator|id -Gn
ssh login|readonly01|${PASS_READONLY}|koitohan readonly|id -Gn
ssh login|norole01|${PASS_NOROLE}|denied|id -Gn
ssh login|admin01|wrong|denied|id -Gn
ssh login|nobody01|nopass|denied|id -Gn
ssh login|root|nopass|denied|id -Gn
firmware|admin01|${PASS_ADMIN}|written|touch /tftpboot/firmware/smoke ${TOUCH}
firmware|operator01|${PASS_OPERATOR}|refused|touch /tftpboot/firmware/smoke ${TOUCH}
firmware|readonly01|${PASS_READONLY}|refused|touch /tftpboot/firmware/smoke ${TOUCH}
configs|admin01|${PASS_ADMIN}|written|touch /tftpboot/configs/smoke ${TOUCH}
configs|operator01|${PASS_OPERATOR}|refused|ls /tftpboot/configs ${TOUCH}
configs|readonly01|${PASS_READONLY}|refused|ls /tftpboot/configs ${TOUCH}
logs|readonly01|${PASS_READONLY}|smoke LINK-3|zgrep -h LINK-3 /logs/Hosts/*/*.log-2026-10-10.gz
CASES

check_read_only openssh
check_read_only openldap

check_secrets admin01 "${PASS_ADMIN}"
check_secrets operator01 "${PASS_OPERATOR}"
check_secrets readonly01 "${PASS_READONLY}"

# passwd reads the current password, then the new one twice
check_ssh 'weak password' readonly01 "${PASS_READONLY}" 'Weak password' passwd \
  "${PASS_READONLY}\nPassword1\nPassword1\n"
check_ssh 'passwd' readonly01 "${PASS_READONLY}" 'password updated successfully' passwd \
  "${PASS_READONLY}\n${NEW_PASS}\n${NEW_PASS}\n"
check_ssh 'new password' readonly01 "${NEW_PASS}" 'koitohan readonly' 'id -Gn' < /dev/null
check_ssh 'old password' readonly01 "${PASS_READONLY}" denied 'id -Gn' < /dev/null

# bin/manage_users.sh. The test accounts hold 10000 to 10003, so the
# numbers start at 10004 and a deleted one does not come back.
check_users 'users add' 'not usable as a login name' "${NEW_PASS}" add Smoke.01 operator
check_users 'users add' 'no such role' "${NEW_PASS}" add smoke01 root
check_users 'users add' 'the user exists' "${NEW_PASS}" add admin01 admin
check_users 'users add' 'belongs to an account' "${NEW_PASS}" add nobody admin
check_users 'users add' 'the password was refused' 'Password1' add smoke01 operator
check_users 'users add' 'uidNumber 10004' "${NEW_PASS}" add smoke01 operator
check_ssh 'users add' smoke01 "${NEW_PASS}" 'koitohan operator' 'id -Gn' < /dev/null
check 'users add' 127.0.0.1 smoke01 "${NEW_PASS}" Accept 'AVPair = "shell:priv-lvl=7"'

# More than one role, which only a change by hand gives: the weakest
# counts, for RADIUS and for ssh. readonly comes last in memberOf
# here, so neither the first value nor the strongest would do. "role"
# below puts smoke01 back into one role.
function add_role_by_hand() {
  "${COMPOSE[@]}" exec -T openldap sh -c "${LDAP_SUFFIX_SET};"'
    printf "dn: cn=%s,ou=Roles,%s\nchangetype: modify\nadd: uniqueMember\nuniqueMember: uid=%s,ou=People,%s\n" \
      '"${2}"' "${SUFFIX}" '"${1}"' "${SUFFIX}" \
    | ldapmodify '"${AS_MANAGER}" > /dev/null 2>&1 \
  && "${COMPOSE[@]}" exec -T openssh koitohan-update-users > /dev/null 2>&1
}
add_role_by_hand smoke01 admin
check 'two roles' 127.0.0.1 smoke01 "${NEW_PASS}" Accept 'AVPair = "shell:priv-lvl=7"'
check_ssh 'two roles' smoke01 "${NEW_PASS}" 'koitohan operator' 'id -Gn' < /dev/null
check_ssh 'two roles' smoke01 "${NEW_PASS}" 'refused' "touch /tftpboot/firmware/smoke ${TOUCH}" < /dev/null
add_role_by_hand smoke01 readonly
check 'three roles' 127.0.0.1 smoke01 "${NEW_PASS}" Accept 'AVPair = "shell:priv-lvl=1"'
check_ssh 'three roles' smoke01 "${NEW_PASS}" 'koitohan readonly' 'id -Gn' < /dev/null

# The session that is open has to end with the change of the role. A
# session that never got in ends quickly as well, so the role changes
# only once the session has said that it runs.
SESSION_OUT="${KOITOHAN_GENERATED_ROOT}/session.out"
ssh_run smoke01 "${NEW_PASS}" 'echo started; sleep 30' < /dev/null > "${SESSION_OUT}" &
SESSION_PID=$!
for (( TRY = 1; TRY <= WAIT_TRIES; TRY++ )); do
  grep -q -x started "${SESSION_OUT}" && break
  sleep 1
done
WHY=''
grep -q -x started "${SESSION_OUT}" || WHY='the session did not start'
check_users 'users role' 'smoke01 is admin now' '' role smoke01 admin
SECONDS=0
wait "${SESSION_PID}"
[[ -z "${WHY}" && ${SECONDS} -ge 10 ]] && WHY='expected the session to be cut'
COUNT=$((COUNT + 1))
if [[ -z "${WHY}" ]]; then
  printf 'ok    %-13s %-11s %s\n' 'users role' smoke01 'session cut'
else
  FAILED=$((FAILED + 1))
  printf 'FAIL  %-13s %-11s %s\n' 'users role' smoke01 "${WHY}"
  sed 's/^/      | /' "${SESSION_OUT}"
fi
check_ssh 'users role' smoke01 "${NEW_PASS}" 'koitohan admin' 'id -Gn' < /dev/null

check_users 'users passwd' 'the password was refused' 'Password1' passwd smoke01
check_users 'users passwd' 'set the password' "${NEW_PASS2}" passwd smoke01
check_ssh 'users passwd' smoke01 "${NEW_PASS2}" 'koitohan admin' 'id -Gn' < /dev/null
check_ssh 'users passwd' smoke01 "${NEW_PASS}" denied 'id -Gn' < /dev/null

# The password policy of OpenLDAP (ppolicy). A user who goes around
# passwd still meets the least length, and cannot store a hash, which
# would hide the length.
AS_OPERATOR01='-x -H ldapi:/// -D "uid=operator01,ou=People,${SUFFIX}" -w '"'${PASS_OPERATOR}'"
check_ldap 'min length' operator01 'Password fails quality checking policy' \
  "ldappasswd ${AS_OPERATOR01} -s 'x9#Kq!v'"
check_ldap 'hashed' operator01 'Password fails quality checking policy' \
  "printf 'dn: uid=operator01,ou=People,%s\nchangetype: modify\nreplace: userPassword\nuserPassword: {SSHA}c21va2Vfc21va2Vfc21va2Vfc21va2U=\n' \"\${SUFFIX}\" | ldapmodify ${AS_OPERATOR01}"
check 'min length' 127.0.0.1 operator01 "${PASS_OPERATOR}" Accept 'AVPair = "shell:priv-lvl=7"'

# The lock. The failures come in over RADIUS and lock ssh as well.
check_users 'users unlock' 'smoke01 is not locked' '' unlock smoke01
MAX_FAILURE=$("${COMPOSE[@]}" exec -T openldap sh -c "${LDAP_SUFFIX_SET};"'
  ldapsearch -Q -Y EXTERNAL -H ldapi:/// -LLL -b "cn=default,ou=Policies,${SUFFIX}" -s base pwdMaxFailure' \
  2> /dev/null | awk '$1 == "pwdMaxFailure:" { print $2 }')
# the lock below and the check of the service accounts count on it
COUNT=$((COUNT + 1))
if [[ "${MAX_FAILURE}" =~ ^[1-9][0-9]*$ ]]; then
  printf 'ok    %-13s %-11s %s\n' 'ppolicy' 'default' "pwdMaxFailure ${MAX_FAILURE}"
else
  FAILED=$((FAILED + 1))
  printf 'FAIL  %-13s %-11s %s\n' 'ppolicy' 'default' 'could not read pwdMaxFailure'
fi
for (( TRY = 1; TRY <= ${MAX_FAILURE:-0}; TRY++ )); do
  send_request 127.0.0.1 smoke01 wrong > /dev/null
done
check 'lock' 127.0.0.1 smoke01 "${NEW_PASS2}" Reject '-'
check_ssh 'lock' smoke01 "${NEW_PASS2}" denied 'id -Gn' < /dev/null
check_users 'users unlock' 'unlocked smoke01' '' unlock smoke01
check 'users unlock' 127.0.0.1 smoke01 "${NEW_PASS2}" Accept 'AVPair = "shell:priv-lvl=15"'
check_ssh 'users unlock' smoke01 "${NEW_PASS2}" 'koitohan admin' 'id -Gn' < /dev/null

# The service accounts are never locked, or nobody could log in.
# FreeRADIUS and nslcd keep their connections, so a login would not
# show a lock. This looks at the entries. Their policy records no
# failure, so the entries cannot show that the failures were counted at
# all: smoke01, under the default policy, fails the same way first and
# has to be locked. It is unlocked again here, or the checks of the
# deletion below would pass on the lock alone.
FREERADIUS_ACCOUNT=$(source .env && echo "${FREERADIUS_SERVICE_ACCOUNT_NAME}")
OPENSSH_ACCOUNT=$(source .env && echo "${OPENSSH_SERVICE_ACCOUNT_NAME}")
check_ldap 'no lock' 'service' 'never locked' '
  fail() {
    for TRY in $(seq '"${MAX_FAILURE:-0}"'); do
      ldapwhoami -x -H ldapi:/// -D "${1}" -w wrong 2>&1 | grep -q "Invalid credentials" || echo "${1}: no failure"
    done
  }
  locked() {
    ldapsearch -Q -Y EXTERNAL -H ldapi:/// -LLL -b "${1}" -s base "(pwdAccountLockedTime=*)" dn
  }
  OK=1
  CONTROL="uid=smoke01,ou=People,${SUFFIX}"
  fail "${CONTROL}"
  [ -n "$(locked "${CONTROL}")" ] || { echo "${CONTROL}: not locked"; OK=; }
  printf "dn: %s\nchangetype: modify\ndelete: pwdAccountLockedTime\n" "${CONTROL}" \
  | ldapmodify -Q -Y EXTERNAL -H ldapi:/// > /dev/null 2>&1
  [ -z "$(locked "${CONTROL}")" ] || { echo "${CONTROL}: still locked"; OK=; }
  for NAME in '"${FREERADIUS_ACCOUNT} ${OPENSSH_ACCOUNT}"'; do
    DN="uid=${NAME},ou=ServiceAccounts,${SUFFIX}"
    if ! ldapsearch -Q -Y EXTERNAL -H ldapi:/// -LLL -b "${DN}" -s base dn 2> /dev/null | grep -q "^dn:"; then
      echo "${DN}: missing"
      OK=
      continue
    fi
    fail "${DN}"
    [ -z "$(locked "${DN}")" ] || { echo "${DN}: locked"; OK=; }
  done
  [ -n "${OK}" ] && echo "never locked"'

check_users 'users delete' 'deleted smoke01' '' delete smoke01
check_ssh 'users delete' smoke01 "${NEW_PASS2}" denied 'id -Gn' < /dev/null
check 'users delete' 127.0.0.1 smoke01 "${NEW_PASS2}" Reject '-'
check_users 'users delete' 'no such user' '' delete smoke01
check_users 'users add' 'uidNumber 10005' "${NEW_PASS}" add smoke02 readonly

# The passwords of the service accounts. Each change recreates the
# container, which then has to bind with the new password: the old one
# is gone from the directory. The file of the running stack stays.
check_service_password bogus 'usage:'
OLD_FREERADIUS=$(< "${KOITOHAN_GENERATED_ROOT}/secrets/freeradius_service_account_password")
check_service_password freeradius 'recreated freeradius'
if ! wait_ready; then
  echo 'FreeRADIUS did not become ready with the new password'
  "${COMPOSE[@]}" logs --tail 30 freeradius
  exit 1
fi
check 'service pass' 127.0.0.1 operator01 "${PASS_OPERATOR}" Accept 'AVPair = "shell:priv-lvl=7"'
check_ldap 'service pass' 'old' 'Invalid credentials' \
  "ldapwhoami -x -H ldapi:/// -D \"uid=${FREERADIUS_ACCOUNT},ou=ServiceAccounts,\${SUFFIX}\" -w '${OLD_FREERADIUS}'"
# The limit on the source of ssh. The container is made again for
# another network, and the change of the password that follows makes it
# once more, for the networks of the test.
check_ssh_other_network
check_service_password openssh 'recreated openssh'
# the new container has another address
if ! wait_ssh_ready; then
  echo 'the openssh container did not become ready with the new password'
  "${COMPOSE[@]}" logs --tail 30 openssh
  exit 1
fi
check_ssh 'service pass' admin01 "${PASS_ADMIN}" 'koitohan admin' 'id -Gn' < /dev/null

# The passwords of the administrators of OpenLDAP. The change recreates
# openldap, and FreeRADIUS does not get over that, so nothing below
# goes through RADIUS.
ADMIN_FILE="${KOITOHAN_GENERATED_ROOT}/secrets/ldap_admin_password"
CONFIG_FILE="${KOITOHAN_GENERATED_ROOT}/secrets/ldap_config_password"
OLD_ADMIN=$(< "${ADMIN_FILE}")
OLD_CONFIG=$(< "${CONFIG_FILE}")
check_admin_bind 'admin pass' admin "${OLD_ADMIN}" 'dn:cn=admin,dc='
check_admin_bind 'admin pass' config "${OLD_CONFIG}" 'dn:cn=admin,cn=config'
OUT=$(COMPOSE_PROJECT_NAME=koitohan-test COMPOSE_FILE=compose.yaml:tests/compose.test.yaml \
      bin/change_ldap_admin_password.sh 2>&1 < /dev/null)
COUNT=$((COUNT + 1))
if grep -q -F 'recreated openldap' <<< "${OUT}"; then
  printf 'ok    %-13s %-11s %s\n' 'admin pass' 'change' 'recreated openldap'
else
  FAILED=$((FAILED + 1))
  printf 'FAIL  %-13s %-11s %s\n' 'admin pass' 'change' 'expected recreated openldap'
  sed 's/^/      | /' <<< "${OUT}"
fi
NEW_ADMIN=$(< "${ADMIN_FILE}")
NEW_CONFIG=$(< "${CONFIG_FILE}")
check_admin_bind 'admin pass' admin "${NEW_ADMIN}" 'dn:cn=admin,dc='
check_admin_bind 'admin pass' config "${NEW_CONFIG}" 'dn:cn=admin,cn=config'
check_admin_bind 'admin pass' admin "${OLD_ADMIN}" 'Invalid credentials'
check_admin_bind 'admin pass' config "${OLD_CONFIG}" 'Invalid credentials'

COUNT=$((COUNT + 1))
if [[ -n "$(find secrets -newer "${ASKPASS}" 2> /dev/null)" ]]; then
  FAILED=$((FAILED + 1))
  printf 'FAIL  %-13s %-11s %s\n' 'service pass' 'secrets/' 'expected the files of the running stack to stay'
else
  printf 'ok    %-13s %-11s %s\n' 'service pass' 'secrets/' 'untouched'
fi

# The minimum of TLS is written on every start as well. Lowered over
# ldapi:/// here, it has to be back after the restart.
check_ldap 'tls minimum' 'config' 'modifying entry "cn=config"' \
  'ldapmodify -Q -Y EXTERNAL -H ldapi:///' \
  'dn: cn=config\nchangetype: modify\nreplace: olcTLSProtocolMin\nolcTLSProtocolMin: 3.3\n'

check_restart

check_ldap 'tls minimum' 'config' 'olcTLSProtocolMin: 3.4' \
  'ldapsearch -LLL -Q -Y EXTERNAL -H ldapi:/// -b cn=config -s base olcTLSProtocolMin'

# the image sets the passwords on every start, from the files it has now
check_admin_bind 'ldap restart' admin "${NEW_ADMIN}" 'dn:cn=admin,dc='
check_admin_bind 'ldap restart' config "${NEW_CONFIG}" 'dn:cn=admin,cn=config'

# The entrypoint must not log the passwords it reads. This container
# has read them twice by now.
COUNT=$((COUNT + 1))
if "${COMPOSE[@]}" logs openldap 2>&1 | grep -q -F -e "${NEW_ADMIN}" -e "${NEW_CONFIG}"; then
  FAILED=$((FAILED + 1))
  printf 'FAIL  %-13s %-11s %s\n' 'admin pass' 'logs' 'expected no password in the logs of openldap'
else
  printf 'ok    %-13s %-11s %s\n' 'admin pass' 'logs' 'no password'
fi

# nslcd has to find the restarted OpenLDAP again
check_ssh 'ldap restart' admin01 "${PASS_ADMIN}" 'koitohan admin' 'id -Gn' < /dev/null

# OUT is the output of what was run. EXPECT is a fixed string to find in it.
function check_found() {
  local NAME=${1}
  local WHO=${2}
  local EXPECT=${3}
  local OUT=${4}

  COUNT=$((COUNT + 1))
  if grep -q -F -- "${EXPECT}" <<< "${OUT}"; then
    printf 'ok    %-13s %-11s %s\n' "${NAME}" "${WHO}" "${EXPECT}"
  else
    FAILED=$((FAILED + 1))
    printf 'FAIL  %-13s %-11s %s\n' "${NAME}" "${WHO}" "expected ${EXPECT}"
    sed 's/^/      | /' <<< "${OUT}"
  fi
}

# Backup and restore. A backup of the test stack, a change after it,
# then openldap made again with empty volumes and the backup loaded into
# it. The change has to be gone, and what was there at the backup has to
# be back: the users, their passwords and roles, the next uidNumber, and
# the files in configs/ with their owners. bin/backup.sh and
# bin/restore_ldap.sh find the files of the test stack through
# KOITOHAN_GENERATED_ROOT and the mounts of its containers.
STACK=(env COMPOSE_PROJECT_NAME=koitohan-test COMPOSE_FILE=compose.yaml:tests/compose.test.yaml)
BACKUP_DIR="${KOITOHAN_GENERATED_ROOT}/backup"
BACKUP_HOST=${HOSTNAME%%.*}
mkdir -p "${BACKUP_DIR}"
"${COMPOSE[@]}" exec -T tftpd-hpa sh -c '
  echo koitohan-smoke > /tftpboot/configs/smoke.cfg \
  && chown 1000:10001 /tftpboot/configs/smoke.cfg \
  && chmod 640 /tftpboot/configs/smoke.cfg'
# older archives of this host. -k 2 keeps the newer one and the new one.
touch "${BACKUP_DIR}/koitohan-${BACKUP_HOST}-20000101-000000.tar.gz" \
      "${BACKUP_DIR}/koitohan-${BACKUP_HOST}-20000102-000000.tar.gz"
OUT=$("${STACK[@]}" bin/backup.sh -k 2 "${BACKUP_DIR}" 2>&1 < /dev/null)
check_found 'backup' 'write' 'wrote' "${OUT}"
ARCHIVE=$(sed -n 's/^wrote //p' <<< "${OUT}")

OUT=$(ls "${BACKUP_DIR}")
[[ "${OUT}" == "koitohan-${BACKUP_HOST}-20000102-000000.tar.gz"$'\n'"${ARCHIVE##*/}" ]] && OUT='kept 2'
check_found 'backup' 'keep' 'kept 2' "${OUT}"

OUT=$(stat -c '%a' "${ARCHIVE}" 2>&1)
check_found 'backup' 'mode' '600' "${OUT}"

# what has to be there, and no directory entries
OUT=$(tar -t -z -f "${ARCHIVE}" 2>&1)
WHY=''
for MEMBER in .env freeradius/config/clients.conf \
  secrets/{freeradius,openssh}_service_account_password secrets/ldap_{admin,config}_password \
  openssh/hostkeys/ssh_host_ed25519_key ldap/config.ldif ldap/data.ldif \
  tftp-configs.tar koitohan-backup.txt
do
  grep -q -x -F -- "${MEMBER}" <<< "${OUT}" || WHY="${WHY} ${MEMBER}"
done
grep -q '/$' <<< "${OUT}" && WHY="${WHY} (directories)"
[[ -z "${WHY}" ]] && OUT='all members'
check_found 'backup' 'members' 'all members' "${OUT}"

# the files of the test stack, not those of the running one
OUT='other files'
tar -x -O -z -f "${ARCHIVE}" freeradius/config/clients.conf | cmp -s - tests/clients.conf \
  && tar -x -O -z -f "${ARCHIVE}" secrets/freeradius_service_account_password \
     | cmp -s - "${KOITOHAN_GENERATED_ROOT}/secrets/freeradius_service_account_password" \
  && OUT='files of the stack'
check_found 'backup' 'files' 'files of the stack' "${OUT}"

# the change after the backup
check_users 'backup' 'deleted smoke02' '' delete smoke02
"${COMPOSE[@]}" exec -T tftpd-hpa rm -f /tftpboot/configs/smoke.cfg

OUT=$("${STACK[@]}" bin/restore_ldap.sh "${ARCHIVE}" 2>&1 < /dev/null)
check_found 'restore' 'running' 'is not empty' "${OUT}"

# the container goes with its anonymous volumes, and restore_ldap.sh
# makes it again
"${COMPOSE[@]}" rm -s -f -v openldap > /dev/null 2>&1
OUT=$("${STACK[@]}" bin/restore_ldap.sh "${ARCHIVE}" 2>&1 < /dev/null)
check_found 'restore' 'ldap' 'restored the directory' "${OUT}"
grep -q '^warning:' <<< "${OUT}" || OUT='no warning'
check_found 'restore' 'secrets' 'no warning' "${OUT}"

# FreeRADIUS does not get over the change of openldap (README), so it is
# made again as well
if ! { "${COMPOSE[@]}" up -d --no-deps openldap > /dev/null 2>&1 \
       && "${COMPOSE[@]}" up -d --no-deps --force-recreate freeradius > /dev/null 2>&1; }; then
  echo 'could not start openldap and freeradius after the restore'
  exit 1
fi
if ! wait_ldap_ready || ! wait_ready || ! wait_ssh_ready; then
  echo 'the test stack did not become ready after the restore'
  "${COMPOSE[@]}" logs --tail 30 openldap freeradius openssh
  exit 1
fi

OUT=$("${COMPOSE[@]}" logs openldap 2>&1)
grep -q -F 'seeding' <<< "${OUT}" || OUT='not seeded'
check_found 'restore' 'openldap' 'not seeded' "${OUT}"
check 'restore' 127.0.0.1 smoke02 "${NEW_PASS}" Accept 'AVPair = "shell:priv-lvl=1"'
check_ssh 'restore' readonly01 "${NEW_PASS}" 'koitohan readonly' 'id -Gn' < /dev/null
check_users 'restore' 'uidNumber 10006' "${NEW_PASS}" add smoke03 operator
check_admin_bind 'restore' admin "${NEW_ADMIN}" 'dn:cn=admin,dc='

# configs/, as docs/backup.md restores it
OUT=$(tar -x -O -z -f "${ARCHIVE}" tftp-configs.tar \
      | "${COMPOSE[@]}" exec -T tftpd-hpa tar -x -f - -C /tftpboot 2>&1 \
      && "${COMPOSE[@]}" exec -T tftpd-hpa sh -c '
           F=/tftpboot/configs/smoke.cfg; echo "$(stat -c "%u:%g %a" ${F}) $(cat ${F})"' 2>&1)
check_found 'restore' 'configs' '1000:10001 640 koitohan-smoke' "${OUT}"

echo
if [[ ${FAILED} -ne 0 ]]; then
  echo "${FAILED} of ${COUNT} checks failed"
  exit 1
fi
echo "all ${COUNT} checks passed"
