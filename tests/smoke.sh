#!/bin/bash
#
# Smoke test for the AAA path (FreeRADIUS -> LDAPS -> OpenLDAP) and for
# the workspace container (ssh -> OpenSSH -> LDAPS -> OpenLDAP).
#
# Starts the stack as a separate compose project
# on an empty directory, and makes the test accounts with
# bin/manage_users.sh. Checks the reply for every combination of reply
# type and role, then that the detail logs survive a rotation, then
# that FreeRADIUS, syslog-ng, tftpd-hpa and chrony take nothing from
# outside the networks of the devices, that tftpd-hpa records a transfer
# in a file, and that chrony stops serving over its limit, then
# logs in over ssh as each role and checks where the users can connect
# to from there, then manages a user
# with bin/manage_users.sh, then runs into the password policy of
# OpenLDAP, then sees that FreeRADIUS and OpenSSH bound with their
# certificates and that the administrators of OpenLDAP have no password,
# then takes a backup and restores it into an openldap made again. The
# running stack is left alone: the test generates its own certificates,
# LDIFs and ldap_openldap into tests/generated.
#
#   KEEP=1 tests/smoke.sh    leave the test stack up for a closer look

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR%/*}"

cd "${ROOT_DIR}"

COMPOSE=(docker compose -p koitohan-test -f compose.yaml -f tests/compose.test.yaml)
# the scripts under scripts/ write here instead of CA/, openldap/ldif/
# and freeradius/config/
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
# the users of ssh reach only OpenLDAP, as .env.sample has it. One check
# opens the way out.
export OPENSSH_EGRESS='none'
# no other host of a pair reaches OpenLDAP, as .env.sample has it. One
# check sets addresses on a container of its own.
export OPENLDAP_ALLOWED_NETWORKS='none'
# The address that the other host of a pair would connect to (in the
# server certificate), and the other host itself: none until the last
# check. The other host has a CA of its own (PEER_ROOT), as it would.
# TEST-NET-2 and TEST-NET-3: nothing ever answers on them.
HOST_ADDRESS='198.51.100.10'
PEER_ADDRESS='203.0.113.10'
export OPENLDAP_HOST_ADDRESS="${HOST_ADDRESS}"
export OPENLDAP_PEER_ADDRESS='none'
PEER_ROOT="${ROOT_DIR}/tests/generated/peer"
# for openldap-b of tests/compose.test.yaml, the other host (host B) in
# the checks of replication: its own address, and that of openldap
export KOITOHAN_TEST_A_ADDRESS="${HOST_ADDRESS}"
export KOITOHAN_TEST_B_ADDRESS="${PEER_ADDRESS}"
# the optional NTP service as well, whatever .env has. The scripts under
# bin/ see it too.
export COMPOSE_PROFILES='ntp'
# the limit on the size of an upload, small enough to reach over TFTP
# in a moment
TFTP_MAX_BYTES=65536
export TFTP_UPLOAD_MAX_BYTES="${TFTP_MAX_BYTES}"
WAIT_TRIES=40

function cleanup() {
  rm -f "${ASKPASS}"
  docker rm -f "${EGRESS_NAME}" > /dev/null 2>&1
  if [[ -n "${KEEP}" ]]; then
    echo "test stack left up: ${COMPOSE[*]} --profile pair down -v && rm -rf tests/generated"
  else
    "${COMPOSE[@]}" --profile pair down -v > /dev/null 2>&1
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
PASS_OTHER='Qm5+tRz8-Hv2.Wc7k'

function password_of() {
  case ${1} in
    admin01)    echo "${PASS_ADMIN}" ;;
    operator01) echo "${PASS_OPERATOR}" ;;
    readonly01) echo "${PASS_READONLY}" ;;
    norole01)   echo "${PASS_NOROLE}" ;;
    other0?)    echo "${PASS_OTHER}" ;;
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

# what goes under the line of a check that failed
function indent() {
  sed 's/^/      | /'
}

function show_logs() {
  "${COMPOSE[@]}" logs --tail 5 "${1}" 2>&1 | indent
}

# Counts one check and prints its line: PASSED when WHY is empty, WHY
# otherwise, with DETAIL under it if given (even empty). Returns 1 on a
# failure, so that the caller can add more: report ... || show_logs x
function report() {
  local NAME=${1}
  local WHO=${2}
  local PASSED=${3}
  local WHY=${4}

  COUNT=$((COUNT + 1))
  if [[ -z "${WHY}" ]]; then
    printf 'ok    %-13s %-11s %s\n' "${NAME}" "${WHO}" "${PASSED}"
    return 0
  fi
  FAILED=$((FAILED + 1))
  printf 'FAIL  %-13s %-11s %s\n' "${NAME}" "${WHO}" "${WHY}"
  [[ $# -ge 5 ]] && indent <<< "${5}"
  return 1
}

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
  report "${NAME}" "${USER}" "Access-${CODE}" "${WHY}" "${OUT}"
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

# A container on the network of openssh, the only one there besides
# OpenLDAP, that answers on 22, EGRESS_PORT and 514 of TCP. The users of
# ssh reach it or not, as OPENSSH_EGRESS says. No word of OPENSSH_EGRESS
# lets out EGRESS_PORT. The checks show EGRESS_VALUE, the value that the
# openssh container runs with.
EGRESS_NAME='koitohan-test-egress'
EGRESS_PORT=8080
EGRESS_REPLY='koitohan-egress'
EGRESS_VALUE="${OPENSSH_EGRESS}"

function start_egress_target() {
  # not compose run, whose container would count as one of openssh
  docker run -d --rm --name "${EGRESS_NAME}" --network koitohan-test_openssh \
    --entrypoint sh koitohan/openssh -c \
    "nc -lk -p 22 -e echo ${EGRESS_REPLY} & nc -lk -p ${EGRESS_PORT} -e echo ${EGRESS_REPLY} & nc -lk -p 514 -e echo ${EGRESS_REPLY} & wait" \
    > /dev/null 2>&1 || return 1
  EGRESS_ADDR=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
    "${EGRESS_NAME}" 2> /dev/null)
  [[ -n "${EGRESS_ADDR}" ]]
}

# Makes the openssh container again with OPENSSH_EGRESS=VALUE
function recreate_egress() {
  EGRESS_VALUE=${1}
  OPENSSH_EGRESS="${EGRESS_VALUE}" "${COMPOSE[@]}" up -d --force-recreate openssh > /dev/null 2>&1
  if ! wait_ssh_ready; then
    echo "the openssh container did not become ready with OPENSSH_EGRESS=${EGRESS_VALUE}"
    "${COMPOSE[@]}" logs --tail 30 openssh
    exit 1
  fi
}

# Runs COMMAND in the shell of admin01. EXPECT is a fixed string to find
# in the output.
function check_egress_shell() {
  local NAME=${1}
  local EXPECT=${2}
  local COMMAND=${3}
  local OUT WHY=''

  OUT=$(ssh_run admin01 "${PASS_ADMIN}" "${COMMAND}" < /dev/null)
  grep -q -F -- "${EXPECT}" <<< "${OUT}" || WHY="expected ${EXPECT}"
  report "${NAME}" "${EGRESS_VALUE}" "${EXPECT}" "${WHY}" "${OUT}"
}

# Reaches PORT of the target over TCP from the shell. EXPECT is 'reached'
# or 'refused'. Refused has to come at once: a filter that drops would
# pass on a timeout as well. The nc of busybox says nothing of why it
# fails, wget does.
function check_egress_tcp() {
  local PORT=${1}

  if [[ "${2}" == 'reached' ]]; then
    check_egress_shell "egress ${PORT}/tcp" reached \
      "nc -w 3 ${EGRESS_ADDR} ${PORT} 2> /dev/null | grep -q ${EGRESS_REPLY} && echo reached || echo blocked"
  else
    check_egress_shell "egress ${PORT}/tcp" 'Connection refused' \
      "wget -T 3 -O /dev/null http://${EGRESS_ADDR}:${PORT}/ 2>&1"
  fi
}

# Pings the target. EXPECT is 'reached' or 'refused'. A packet of ICMP
# that the filter holds fails with EPERM, whether refused or dropped,
# which tells only that the filter held it.
function check_egress_icmp() {
  if [[ "${1}" == 'reached' ]]; then
    check_egress_shell 'egress icmp' reached \
      "ping -c 1 -W 3 ${EGRESS_ADDR} > /dev/null 2>&1 && echo reached || echo blocked"
  else
    check_egress_shell 'egress icmp' 'Operation not permitted' "ping -c 1 -W 3 ${EGRESS_ADDR} 2>&1"
  fi
}

# Reaches PORT of the target over the forwarding of sshd (ssh -W, as
# ssh -J does). EXPECT is 'reached', 'refused' (sshd forwards, and the
# filter refuses the connection that sshd opens) or 'prohibited' (sshd
# does not forward, before the filter would see it).
function check_egress_forwarding() {
  local PORT=${1}
  local EXPECT=${2}
  local OUT FIND WHY=''

  case "${EXPECT}" in
    reached) FIND=${EGRESS_REPLY} ;;
    refused) FIND='connect failed: Connection refused' ;;
    prohibited) FIND='administratively prohibited' ;;
  esac
  # the reason of a refused forwarding shows from INFO on. The first
  # value wins, so this comes before SSH_OPTS.
  OUT=$(SSH_TEST_PASS="${PASS_ADMIN}" SSH_ASKPASS="${ASKPASS}" SSH_ASKPASS_REQUIRE=force \
        timeout 20 ssh -o LogLevel=INFO "${SSH_OPTS[@]}" -W "${EGRESS_ADDR}:${PORT}" "admin01@${SSH_ADDR}" 2>&1 < /dev/null)
  grep -q -F -- "${FIND}" <<< "${OUT}" || WHY="expected ${FIND}"
  report "egress -W ${PORT}" "${EGRESS_VALUE}" "${EXPECT}" "${WHY}" "${OUT}"
}

# With OPENSSH_EGRESS=any, syslog and TFTP are refused, whatever the
# address: through the Docker host they would reach syslog-ng and
# tftpd-hpa. The target listens on 514/tcp, so a refusal there comes
# from the filter. Over UDP the filter shows as EPERM, an exit status of
# 1 from nc, where a port that nobody listens on gives 0.
function check_egress_own() {
  local PORT

  check_egress_tcp 514 refused
  for PORT in 514 69; do
    check_egress_shell "egress ${PORT}/udp" 'status 1' \
      "echo x | nc -u -w 1 ${EGRESS_ADDR} ${PORT}; echo status \$?"
  done
  check_egress_shell "egress ${EGRESS_PORT}/udp" 'status 0' \
    "echo x | nc -u -w 1 ${EGRESS_ADDR} ${EGRESS_PORT}; echo status \$?"
  check_egress_forwarding 514 refused
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
  report "${NAME}" "${USER}" "${EXPECT}" "${WHY}" "${OUT}"
}

# The files in the openssh container that hold a password or a private
# key. A user who logs in must not read any of them.
SECRET_FILES=(
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
  report 'secrets' "${USER}" 'none readable' "${WHY}" "${OUT}"
}

# The root file system of SERVICE is read-only (read_only: true). root
# writes there, so nothing but the mount can stop it.
function check_read_only() {
  local SERVICE=${1}
  local OUT WHY=''

  OUT=$("${COMPOSE[@]}" exec -T "${SERVICE}" sh -c '
    touch /koitohan-smoke; rm -f /koitohan-smoke' 2>&1)
  grep -q -F 'Read-only file system' <<< "${OUT}" || WHY='expected a read-only file system'
  report 'root fs' "${SERVICE}" 'read-only' "${WHY}" "${OUT}"
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
  report "${NAME}" "${2}" "${EXPECT}" "${WHY}" "${OUT}"
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
  report "${NAME}" "${USER}" "${EXPECT}" "${WHY}" "${OUT}"
}

# Binds as an administrator of OpenLDAP (admin or config) with PASS, a
# simple bind over ldapi:///. EXPECT is a fixed string to find in the
# output.
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
  report 'ldap restart' admin01 'bind' "${WHY}" || show_logs openldap
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
  report 'networks' 'other' 'ssh timed out' "${WHY}" "${OUT}" || show_logs openssh
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
  report 'networks' "${NAME}" "radius ${EXPECT}" "${WHY}" "${OUT}" || show_logs freeradius
}

# the number of messages that have come in to syslog-ng, before the
# filter. Empty while syslog-ng does not answer on its control socket.
function syslog_count() {
  "${COMPOSE[@]}" exec -T syslog-ng syslog-ng-ctl stats --control=/config/syslog-ng.ctl 2> /dev/null \
  | awk -F ';' '$1 == "source" && $2 == "s_network" { print $6 }'
}

# A container started with a wrong value of the networks it takes has
# to stop before it listens, and say why: the message tells this from a
# start that fails for some other reason. One that starts after all is
# stopped after a while, and removed either way.
function check_bad_value() {
  local CHECK=${1}
  local VARIABLE=${2}
  local SERVICE=${3}
  local VALUE=${4}
  local EXPECT=${5}
  local NAME="koitohan-test-networks-${SERVICE}"
  local OUT RC WHY=''

  OUT=$(timeout 30 "${COMPOSE[@]}" run --rm --no-deps -T --name "${NAME}" \
          -e "${VARIABLE}=${VALUE}" "${SERVICE}" 2>&1 < /dev/null)
  RC=$?
  docker rm -f "${NAME}" > /dev/null 2>&1
  if [[ ${RC} -eq 0 || ${RC} -eq 124 ]]; then
    WHY='expected the container to stop'
  elif ! grep -q -F -- "${EXPECT}" <<< "${OUT}"; then
    WHY="expected ${EXPECT}"
  fi
  [[ -n "${WHY}" ]] && WHY="'${VALUE}': ${WHY}"
  report "${CHECK}" "${SERVICE}" "'${VALUE}': ${EXPECT}" "${WHY}" "$(tail -n 5 <<< "${OUT}")"
}

function check_bad_networks() {
  local VARIABLE=DEVICE_NETWORKS

  [[ "${1}" == 'openssh' ]] && VARIABLE=OPENSSH_ALLOWED_NETWORKS
  [[ "${1}" == 'openldap' ]] && VARIABLE=OPENLDAP_ALLOWED_NETWORKS
  check_bad_value 'bad networks' "${VARIABLE}" "$@"
}

# The same for the filter of syslog-ng, which the script writes on the
# Docker host: syslog-ng itself takes what looks like a network. The
# file has to stay as it was, and is put back if not.
function check_bad_generated() {
  local VALUE=${1}
  local FILE="${KOITOHAN_GENERATED_ROOT}/syslog-ng/config/device_networks.conf"
  local BEFORE OUT WHY=''

  BEFORE=$(< "${FILE}")
  if OUT=$(DEVICE_NETWORKS="${VALUE}" scripts/generate_device_networks.sh 2>&1); then
    WHY='expected the script to fail'
  elif ! grep -q -F 'has to be IPv4' <<< "${OUT}"; then
    WHY='expected has to be IPv4'
  elif [[ "$(< "${FILE}")" != "${BEFORE}" ]]; then
    WHY='expected device_networks.conf to stay'
  fi
  [[ "$(< "${FILE}")" == "${BEFORE}" ]] || printf '%s\n' "${BEFORE}" > "${FILE}"
  [[ -n "${WHY}" ]] && WHY="'${VALUE}': ${WHY}"
  report 'bad networks' 'syslog-ng' "'${VALUE}': has to be IPv4" "${WHY}" "${OUT}"
}

# The gateway of the network of a container: the source that the
# container sees for what the Docker host sends to its address.
function gateway_of() {
  docker inspect -f '{{range .NetworkSettings.Networks}}{{.Gateway}}{{end}}' \
    "$("${COMPOSE[@]}" ps -q ${1})" 2> /dev/null
}

# The log that syslog-ng keeps for the messages from the Docker host,
# as a path below Hosts/. It is named after the source address.
function syslog_log_of_host() {
  local GATEWAY
  GATEWAY=$(gateway_of syslog-ng)
  [[ -n "${GATEWAY}" ]] && echo "${GATEWAY}/${GATEWAY}.log"
}

# Sends a syslog message from the Docker host to the address of the
# container, over PROTO ('udp', the default, or 'tcp'). EXPECT is
# 'received' or 'dropped'. The messages all land in the one log of the
# Docker host, so each carries its NAME to tell them apart. syslog-ng
# says nothing about a message it
# drops, so a message counts as dropped only when syslog-ng has taken it
# in and has not written it: one that never got there says nothing about
# the filter. The filter is in syslog-ng, so over TCP the connection is
# made either way.
function check_syslog_networks() {
  local NAME=${1}
  local EXPECT=${2}
  local PROTO=${3:-udp}
  local ADDR LOG TRY BEFORE='' AFTER='' GOT='dropped' WHY=''

  # syslog-ng takes a while to start
  for (( TRY = 1; TRY <= WAIT_TRIES; TRY++ )); do
    BEFORE=$(syslog_count)
    [[ -n "${BEFORE}" ]] && break
    sleep 1
  done
  ADDR=$(address_of syslog-ng)
  LOG=$(syslog_log_of_host)
  if [[ -z "${BEFORE}" ]]; then
    WHY='syslog-ng did not start'
  elif [[ -z "${ADDR}" || -z "${LOG}" ]]; then
    WHY='could not find the address or the gateway of syslog-ng'
  elif ! echo "<134>Jan  1 00:00:00 smoke-${NAME} smoke: koitohan-smoke [${NAME}]" 2> /dev/null \
           > "/dev/${PROTO}/${ADDR}/1514"; then
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
        if "${COMPOSE[@]}" exec -T syslog-ng grep -q -F "koitohan-smoke [${NAME}]" "/var/log/Hosts/${LOG}" 2> /dev/null; then
          GOT='received'
          break
        fi
        sleep 1
      done
      [[ "${GOT}" == "${EXPECT}" ]] || WHY="expected the message to be ${EXPECT}"
    fi
  fi
  report 'networks' "${NAME}" "syslog/${PROTO} ${EXPECT}" "${WHY}" || show_logs syslog-ng
}

# What a sender writes in a message must not decide where and under
# which time it is kept. The message of check_syslog_networks NAME gave
# the host name smoke-NAME and the time Jan 1 00:00:00: no directory of
# that name, the time of receipt at the head of the line, and the name
# it gave still in the line.
function check_syslog_sender() {
  local NAME=${1}
  local LOG LINE='' WHY=''

  LOG=$(syslog_log_of_host)
  [[ -n "${LOG}" ]] && LINE=$("${COMPOSE[@]}" exec -T syslog-ng \
    grep -F "koitohan-smoke [${NAME}]" "/var/log/Hosts/${LOG}" 2> /dev/null)
  if [[ -z "${LINE}" ]]; then
    WHY='the message is not in the log of its source address'
  elif "${COMPOSE[@]}" exec -T syslog-ng test -e "/var/log/Hosts/smoke-${NAME}"; then
    WHY="expected no Hosts/smoke-${NAME}"
  elif [[ ! "${LINE}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}[+-][0-9]{2}:[0-9]{2}\  ]]; then
    WHY='expected the time of receipt at the head of the line'
  elif [[ "${LINE}" == *'Jan  1 00:00:00'* ]]; then
    WHY='expected the time in the message to be left out'
  elif [[ "${LINE}" != *" smoke-${NAME} smoke: "* ]]; then
    WHY='expected the host name of the message in the line'
  fi
  report 'syslog sender' "${NAME}" 'kept by source address and time of receipt' "${WHY}" "${LINE}"
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
  report 'networks' "${NAME}" "tftp ${EXPECT}" "${WHY}" "${OUT}" || show_logs tftpd-hpa
}

# Asks the chrony container for the time from another container of the
# same image, on the same network: the Docker host has no NTP client.
# The client is chronyd, which only reads the clock (-x). EXPECT is
# 'served' (stratum 10), 'unsynchronised' (stratum 0, which a client
# does not take) or 'no reply'. First waits for the line of the
# entrypoint that says chrony serves, or that it stopped: before it,
# chrony answers that it is not synchronised, and does not answer at all
# before it starts.
function check_ntp() {
  local CHECK=${1}
  local NAME=${2}
  local EXPECT=${3}
  local WAIT_FOR='serving the host clock'
  local ADDR TRY OUT='' GOT WHY=''

  [[ "${EXPECT}" == 'unsynchronised' ]] && WAIT_FOR='stopped serving'
  for (( TRY = 1; TRY <= WAIT_TRIES; TRY++ )); do
    "${COMPOSE[@]}" logs chrony 2>&1 | grep -q -F "${WAIT_FOR}" && break
    sleep 1
  done
  ADDR=$(address_of chrony)
  if [[ ${TRY} -gt ${WAIT_TRIES} ]]; then
    WHY="chrony did not say '${WAIT_FOR}'"
  elif [[ -z "${ADDR}" ]]; then
    WHY='could not find the address of chrony'
  else
    OUT=$("${COMPOSE[@]}" run --rm --no-deps -T --entrypoint sh chrony -c '
            printf "server %s iburst minpoll 0 maxpoll 0\ncmdport 0\n" "$1" > /run/client.conf
            chronyd -x -f /run/client.conf
            sleep 6
            chronyc -n ntpdata' sh "${ADDR}" 2>&1 < /dev/null)
    GOT=$(awk -F ' *: *' '
            $1 == "Leap status" { leap = $2 }
            $1 == "Stratum"     { stratum = $2 }
            $1 == "Total RX"    { rx = $2 }
            END {
              if (rx == "") print "no answer from the client"
              else if (rx == 0) print "no reply"
              else if (leap == "Normal" && stratum == 10) print "served"
              else if (leap == "Not synchronised" && stratum == 0) print "unsynchronised"
              else print "leap " leap ", stratum " stratum
            }' <<< "${OUT}")
    [[ "${GOT}" == "${EXPECT}" ]] || WHY="expected ${EXPECT}, got ${GOT}"
  fi
  report "${CHECK}" "${NAME}" "ntp ${EXPECT}" "${WHY}" "${OUT}" || show_logs chrony
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
  report 'detail log' admin01 'made again' "${WHY}" "${OUT}"
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
  report 'tftp log' 'smoke.txt' 'recorded, made again' "${WHY}" "${OUT}" || show_logs tftpd-hpa
}

# OUT is the output of what was run. EXPECT is a fixed string to find in it.
function check_found() {
  local NAME=${1}
  local WHO=${2}
  local EXPECT=${3}
  local OUT=${4}
  local WHY=''

  grep -q -F -- "${EXPECT}" <<< "${OUT}" || WHY="expected ${EXPECT}"
  report "${NAME}" "${WHO}" "${EXPECT}" "${WHY}" "${OUT}"
}

# bin/check_services.sh -q on the test stack. EXPECT is 'healthy': exit
# 0 and no NG. Otherwise it is an NG line without the NG, which has to
# be the only one, with exit 1. A WARN counts for neither, as the space
# on the Docker host decides it.
function check_services() {
  local WHO=${1}
  local EXPECT=${2}
  local OUT RC NG_LINES WHY=''

  OUT=$(COMPOSE_PROJECT_NAME=koitohan-test COMPOSE_FILE=compose.yaml:tests/compose.test.yaml \
    bin/check_services.sh -q 2>&1)
  RC=$?
  NG_LINES=$(grep '^NG ' <<< "${OUT}")
  if [[ "${EXPECT}" == healthy ]]; then
    if [[ ${RC} -ne 0 ]]; then
      WHY="exit ${RC}"
    elif [[ -n "${NG_LINES}" ]]; then
      WHY='an NG with exit 0'
    fi
  elif [[ ${RC} -ne 1 ]]; then
    WHY="exit ${RC}, not 1"
  elif [[ "${NG_LINES}" != "NG    ${EXPECT}"* ]]; then
    WHY="expected NG ${EXPECT}"
  elif [[ "${NG_LINES}" == *$'\n'* ]]; then
    WHY='more than one NG'
  fi
  report 'services' "${WHO}" "${EXPECT}" "${WHY}" "${OUT}"
}

# what tftpd-hpa holds as PATH under /tftpboot: owner, mode, size and
# checksum, or 'missing'
function tftp_stored() {
  "${COMPOSE[@]}" exec -T tftpd-hpa sh -c "
    F=/tftpboot/${1}
    if [ -e \"\${F}\" ]; then
      echo \"\$(stat -c '%u:%g %a %s' \"\${F}\") \$(md5sum < \"\${F}\" | cut -d ' ' -f 1)\"
    else
      echo missing
    fi" 2>&1
}

# what tftpd-hpa has to hold of the first SIZE bytes of FILE: written by
# in.tftpd (1000) into configs (10001, setgid) with --umask 022
function tftp_expected() {
  echo "1000:10001 644 ${2} $(head -c "${2}" "${1}" | md5sum | cut -d ' ' -f 1)"
}

# Uploads from the Docker host, as the devices back up their
# configurations: to configs, which keeps what comes, also over a file
# of the same name, and only up to the limit on the size; and to
# firmware, which takes nothing. The test stack mounts a firmware of its
# own, so the mount of compose.yaml is looked at as well.
function check_tftp_uploads() {
  local DIR="${KOITOHAN_GENERATED_ROOT}/upload"
  local ADDR OUT FILE

  mkdir -p "${DIR}"
  head -c 1000 /dev/urandom > "${DIR}/first"
  head -c 300 /dev/urandom > "${DIR}/second"
  head -c "${TFTP_MAX_BYTES}" /dev/urandom > "${DIR}/max"
  head -c $((TFTP_MAX_BYTES + 1)) /dev/urandom > "${DIR}/over"
  ADDR=$(address_of tftpd-hpa)

  # a new file, then a shorter one over it, which has to cut it short
  for FILE in first second; do
    OUT=$(curl -s -S -m 5 -T "${DIR}/${FILE}" "tftp://${ADDR}/configs/smoke-upload.cfg" 2>&1)
    check_found 'tftp upload' "${FILE}" \
      "$(tftp_expected "${DIR}/${FILE}" "$(stat -c %s "${DIR}/${FILE}")")" \
      "$(tftp_stored configs/smoke-upload.cfg) ${OUT}"
  done

  # The limit itself goes through. One byte over it times out and leaves
  # what fits.
  OUT=$(curl -s -S -m 5 -T "${DIR}/max" "tftp://${ADDR}/configs/smoke-max.cfg" 2>&1)
  check_found 'tftp upload' 'limit' "$(tftp_expected "${DIR}/max" "${TFTP_MAX_BYTES}")" \
    "$(tftp_stored configs/smoke-max.cfg) ${OUT}"
  OUT=$(curl -s -S -m 5 -T "${DIR}/over" "tftp://${ADDR}/configs/smoke-over.cfg" 2>&1)
  check_found 'tftp upload' 'over limit' "$(tftp_expected "${DIR}/over" "${TFTP_MAX_BYTES}")" \
    "$(tftp_stored configs/smoke-over.cfg) ${OUT}"

  # tftpd-hpa has to answer with an error: no file and no answer at all
  # would look the same
  OUT=$(curl -s -S -m 5 -T "${DIR}/first" "tftp://${ADDR}/firmware/smoke-upload.bin" 2>&1)
  [[ "$(tftp_stored firmware/smoke-upload.bin)" == 'missing' ]] \
    && grep -q -F 'TFTP: ' <<< "${OUT}" && OUT='refused'
  check_found 'tftp upload' 'firmware' 'refused' "${OUT}"

  OUT=$(docker compose -f compose.yaml config 2>&1 | awk '
    /^  [^ ]/ { SERVICE = $1 }
    $1 == "-" { TARGET = "" }
    SERVICE == "tftpd-hpa:" && $1 == "target:" { TARGET = $2 }
    TARGET == "/tftpboot/firmware" && $1 == "read_only:" { print "read_only " $2; exit }')
  check_found 'tftp upload' 'compose' 'read_only true' "${OUT}"
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
      -CAfile "${KOITOHAN_GENERATED_ROOT}/CA/default-ca.pem" \
      -cert "${KOITOHAN_GENERATED_ROOT}/CA/freeradius_client.crt" \
      -key "${KOITOHAN_GENERATED_ROOT}/CA/freeradius_client.key" < /dev/null 2>&1)

    if grep -q '^New, TLSv' <<< "${OUT}"; then
      GOT='accepted'
    elif grep -q -F 'alert protocol version' <<< "${OUT}"; then
      GOT='refused'
    else
      GOT='failed'
    fi
    [[ "${GOT}" == "${EXPECT}" ]] || WHY="expected ${EXPECT}, got ${GOT}"
  fi
  # the output without the certificates
  report 'tls' "${VERSION}" "${GOT}" "${WHY}" \
    "$(grep -v -e '^-----' -e '^[A-Za-z0-9+/=]\{64\}$' <<< "${OUT}" | head -n 20)"
}

# IPv4 addresses, prefixes and ranges ("a.b.c.d-e.f.g.h", which nft
# prints for joined prefixes that make no single prefix), separated by
# spaces, as the ranges of addresses they cover: one line "first-last"
# (as numbers) for each run, with overlapping and neighbouring ones joined.
function address_ranges() {
  tr ' ' '\n' | grep . | awk -F '[./-]' '{
      first = (($1 * 256 + $2) * 256 + $3) * 256 + $4
      if ($0 ~ /-/) {
        print first, (($5 * 256 + $6) * 256 + $7) * 256 + $8
        next
      }
      size = 2 ^ (32 - (NF == 5 ? $5 : 32))
      first -= first % size
      print first, first + size - 1
    }' | sort -n -k 1,1 | awk '
      NR == 1 { a = $1; b = $2; next }
      $1 <= b + 1 { if ($2 > b) b = $2; next }
      { printf "%.0f-%.0f\n", a, b; a = $1; b = $2 }
      END { if (NR) printf "%.0f-%.0f\n", a, b }'
}

# The sources that the filter of OpenLDAP lets in to 636/tcp, read from
# the rules: one Docker host has no outside address to send from (what
# another network of Docker sends to a published port comes in from the
# gateway of the container's own network). A container in the same
# network namespace lists them, since the one that put them in has given
# up NET_ADMIN. VALUE is set on a container of its own, on the default
# network of the test stack, with no alias for FreeRADIUS and OpenSSH to
# find; it stays up after its entrypoint stops (it has no secrets), so
# that its rules can be read. '' reads the running openldap. EXPECT is
# what VALUE adds to the subnets of the container ('' for nothing).
function check_ldap_networks() {
  local VALUE=${1}
  local EXPECT=${2}
  local NAME='koitohan-test-ldap-networks'
  local ID NETWORK OUT='' GOT WANT TRY WHY=''

  if [[ -z "${VALUE}" ]]; then
    ID=$("${COMPOSE[@]}" ps -q openldap)
  else
    NETWORK=$(docker inspect -f '{{range $name, $_ := .NetworkSettings.Networks}}{{$name}} {{end}}' \
      "$("${COMPOSE[@]}" ps -q freeradius)" 2> /dev/null | cut -d ' ' -f 1)
    docker rm -f "${NAME}" > /dev/null 2>&1
    docker run -d --rm --name "${NAME}" --network "${NETWORK}" --cap-add NET_ADMIN \
      --ulimit nofile=1024 -e "OPENLDAP_ALLOWED_NETWORKS=${VALUE}" -e LDAP_DOMAIN=example.com \
      --entrypoint sh koitohan/openldap -c '/entrypoint.sh; sleep 60' > /dev/null 2>&1
    ID=${NAME}
  fi
  for (( TRY = 0; TRY < 20; TRY++ )); do
    OUT=$(docker run --rm --network "container:${ID}" --cap-add NET_ADMIN \
            --entrypoint nft koitohan/openldap list ruleset 2>&1)
    grep -q 'dport 636' <<< "${OUT}" && break
    sleep 0.5
  done
  GOT=$(sed -n 's/.* saddr \(.*\) tcp dport 636 accept$/\1/p' <<< "${OUT}" \
        | tr -d '{} ' | tr ',' '\n' | grep . | sort | paste -s -d ' ')
  WANT=$( {
    for NETWORK in $(docker inspect -f '{{range $name, $_ := .NetworkSettings.Networks}}{{$name}} {{end}}' "${ID}"); do
      docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' "${NETWORK}"
    done
    tr ' ' '\n' <<< "${EXPECT}"
  } | grep . | sort | paste -s -d ' ')
  # nft joins neighbouring prefixes (two /20 may come back as one /19),
  # so the two are compared as the addresses they cover
  [[ -n "${GOT}" && "$(address_ranges <<< "${GOT}")" == "$(address_ranges <<< "${WANT}")" ]] \
    || WHY="expected ${WANT}, got ${GOT:-no rule}"
  [[ -n "${VALUE}" ]] && docker rm -f "${NAME}" > /dev/null 2>&1
  local WHO=running
  [[ -n "${VALUE}" ]] && WHO=value
  report 'ldap networks' "${WHO}" "${GOT}" "${WHY}" "${OUT}"
}

# A bind over LDAPS to the address in the server certificate, with the
# replication certificate from the CA of ROOT, as the other host of a
# pair would make it. The address is TEST-NET, so a container of its own
# sends it on to openldap (DNAT in its own namespace): the name checked
# against the certificate is still the address. EXPECT is the DN that
# the bind gives, or refused (the server ends the handshake).
function check_peer_tls() {
  local WHO=${1}
  local ROOT=${2}
  local EXPECT=${3}
  local ID NETWORK ADDR OUT='' GOT WHY=''

  ID=$("${COMPOSE[@]}" ps -q openldap)
  read -r NETWORK ADDR < <(docker inspect \
    -f '{{range $name, $net := .NetworkSettings.Networks}}{{$name}} {{$net.IPAddress}}{{"\n"}}{{end}}' \
    "${ID}" 2> /dev/null | grep -v -F -- "koitohan-test_openssh")
  if [[ -z "${ADDR}" ]]; then
    WHY='could not find the address of openldap'
  else
    OUT=$(docker run --rm --network "${NETWORK}" --cap-add NET_ADMIN --ulimit nofile=1024 \
      -v "${ROOT}/CA/openldap_replication.crt:/peer/replication.crt:ro" \
      -v "${ROOT}/CA/openldap_replication.key:/peer/replication.key:ro" \
      -v "${KOITOHAN_GENERATED_ROOT}/CA/default-ca.pem:/peer/ca.pem:ro" \
      --entrypoint sh koitohan/openldap -c "
        nft add table ip peer \
        && nft 'add chain ip peer out { type nat hook output priority -100; }' \
        && nft add rule ip peer out ip daddr ${HOST_ADDRESS} dnat to ${ADDR} \
        && LDAPTLS_REQCERT=demand LDAPTLS_CACERT=/peer/ca.pem \
           LDAPTLS_CERT=/peer/replication.crt LDAPTLS_KEY=/peer/replication.key \
           timeout 10 ldapwhoami -Q -Y EXTERNAL -H ldaps://${HOST_ADDRESS}" 2>&1 < /dev/null)
    if grep -q '^dn:' <<< "${OUT}"; then
      GOT=$(grep '^dn:' <<< "${OUT}")
      GOT=${GOT#dn:}
    elif grep -q -F 'additional info: TLS:' <<< "${OUT}"; then
      # this end did not take the server certificate: says nothing
      # about the client certificate
      GOT='server not verified'
    elif grep -q -F "Can't contact LDAP server" <<< "${OUT}"; then
      GOT='refused'
    else
      GOT='failed'
    fi
    [[ "${GOT,,}" == "${EXPECT,,}" ]] || WHY="expected ${EXPECT}, got ${GOT}"
  fi
  report 'peer tls' "${WHO}" "${GOT}" "${WHY}" "${OUT}"
}

# Runs COMMAND with sh in the container of SERVICE (openldap, or
# openldap-b of a pair), where SUFFIX is the suffix of the directory.
# INPUT goes to the standard input of the command.
function on_ldap() {
  local SERVICE=${1}
  local COMMAND=${2}
  local INPUT=${3:-}

  printf '%b' "${INPUT}" \
    | "${COMPOSE[@]}" exec -T "${SERVICE}" sh -c "${LDAP_SUFFIX_SET}; ${COMMAND}" 2>&1
}

# A bind over LDAPS to openldap, as the other host of a pair: the
# replication certificate from the CA of host B, and the address in the
# server certificate, sent on as in check_peer_tls. Runs COMMAND with sh
# there, with SUFFIX set and the TLS settings in the environment.
function as_peer() {
  local COMMAND=${1}
  local ID NETWORK ADDR SUFFIX

  SUFFIX=$(on_ldap openldap 'echo "${SUFFIX}"')
  ID=$("${COMPOSE[@]}" ps -q openldap)
  read -r NETWORK ADDR < <(docker inspect \
    -f '{{range $name, $net := .NetworkSettings.Networks}}{{$name}} {{$net.IPAddress}}{{"\n"}}{{end}}' \
    "${ID}" 2> /dev/null | grep -v -F -- "koitohan-test_openssh")
  docker run --rm --network "${NETWORK}" --cap-add NET_ADMIN --ulimit nofile=1024 \
    -e "SUFFIX=${SUFFIX}" \
    -v "${PEER_ROOT}/CA/openldap_replication.crt:/peer/replication.crt:ro" \
    -v "${PEER_ROOT}/CA/openldap_replication.key:/peer/replication.key:ro" \
    -v "${KOITOHAN_GENERATED_ROOT}/CA/default-ca.pem:/peer/ca.pem:ro" \
    --entrypoint sh koitohan/openldap -c "
      nft add table ip peer \
      && nft 'add chain ip peer out { type nat hook output priority -100; }' \
      && nft add rule ip peer out ip daddr ${HOST_ADDRESS} dnat to ${ADDR} \
      && export LDAPTLS_REQCERT=demand LDAPTLS_CACERT=/peer/ca.pem \
           LDAPTLS_CERT=/peer/replication.crt LDAPTLS_KEY=/peer/replication.key \
      && ${COMMAND}" 2>&1 < /dev/null
}

# The addresses of a pair are TEST-NET, as in the server certificates.
# Each host sends the address of the other on to its container, with
# DNAT in its own namespace (the container itself has given NET_ADMIN
# up). A container that starts again has a new namespace, and maybe a
# new address, so this follows every start. A host that is not running
# is left out.
function link_pair() {
  local FROM TO ADDRESS ID TARGET

  for FROM in openldap openldap-b; do
    if [[ "${FROM}" == 'openldap' ]]; then
      TO=openldap-b
      ADDRESS=${PEER_ADDRESS}
    else
      TO=openldap
      ADDRESS=${HOST_ADDRESS}
    fi
    ID=$("${COMPOSE[@]}" ps -q "${FROM}" 2> /dev/null)
    TARGET=$(docker inspect -f '{{(index .NetworkSettings.Networks "koitohan-test_default").IPAddress}}' \
               "$("${COMPOSE[@]}" ps -q "${TO}" 2> /dev/null)" 2> /dev/null)
    [[ -z "${ID}" || -z "${TARGET}" ]] && continue
    docker run --rm --network "container:${ID}" --cap-add NET_ADMIN --ulimit nofile=1024 \
      --entrypoint sh koitohan/openldap -c "
        nft delete table ip pair 2> /dev/null
        nft add table ip pair \
        && nft 'add chain ip pair out { type nat hook output priority -100; }' \
        && nft add rule ip pair out ip daddr ${ADDRESS} dnat to ${TARGET}" > /dev/null 2>&1
  done
}

# waits up to TRIES times 2 seconds until the log of SERVICE has TEXT
function wait_log() {
  local SERVICE=${1}
  local TEXT=${2}
  local TRIES=${3:-15}
  local TRY

  for (( TRY = 1; TRY <= TRIES; TRY++ )); do
    "${COMPOSE[@]}" logs "${SERVICE}" 2>&1 | grep -q -F -- "${TEXT}" && return 0
    sleep 2
  done
  return 1
}

# whether host B listens on LDAPS, and its marks
PAIR_STATE='if netstat -ltn | grep -q ":636 "; then echo -n "636 listening "; else echo -n "636 closed "; fi; ls /etc/openldap/slapd.d | grep "^koitohan-" | paste -s -d " " -'

# The whole tree of SERVICE with the operational attributes, one line
# for each value, with the DN of its entry in front, sorted. memberOf is
# made on each host, and the rest is replicated: the two hosts of a pair
# have to give the same.
function tree_of() {
  on_ldap "${1}" 'ldapsearch -LLL -o ldif-wrap=no -Q -Y EXTERNAL -H ldapi:/// -b "${SUFFIX}" "(objectClass=*)" "*" "+"' \
    | awk '/^dn: / { dn = $0 } NF { print dn " | " $0 }' | sort
}

# waits for the two hosts of the pair to hold the same tree
function check_pair_same() {
  local WHO=${1}
  local TRY A B WHY='expected the same tree on both hosts'

  for (( TRY = 1; TRY <= 20; TRY++ )); do
    A=$(tree_of openldap)
    B=$(tree_of openldap-b)
    if grep -q '^dn: ' <<< "${A}" && [[ "${A}" == "${B}" ]]; then
      WHY=''
      break
    fi
    sleep 3
  done
  report 'pair' "${WHO}" "the same tree, $(grep -c . <<< "${A}") values" "${WHY}" \
    "$(diff <(echo "${A}") <(echo "${B}") | head -n 20)"
}

# the replication settings of SERVICE, in one line
PAIR_CONFIG='for F in "(objectClass=olcSyncProvConfig)" "(olcSyncrepl=*)" "(olcMultiProvider=TRUE)"; do
    echo -n "$(ldapsearch -LLL -Q -Y EXTERNAL -H ldapi:/// -b cn=config "${F}" dn | grep -c "^dn:") "
  done
  ldapsearch -LLL -o ldif-wrap=no -Q -Y EXTERNAL -H ldapi:/// -b cn=config "(|(olcServerID=*)(olcSyncrepl=*))" olcServerID olcSyncrepl \
    | sed -n "s/^olcServerID: /id /p; s/^olcSyncrepl: .*\(provider=[^ ]*\).*/\1/p" | paste -s -d " " - | grep . || echo none'

# a missing source of a file bind mount would be created as a directory
for FILE in \
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

# The same scripts as make runs, on certificates of the test's own
rm -rf "${KOITOHAN_GENERATED_ROOT}"
mkdir -p "${KOITOHAN_GENERATED_ROOT}"/{CA,openldap/ldif,openldap/peer,freeradius/config/mods-available,syslog-ng/config,syslog-ng/log/Hosts,tftpboot/firmware}
# as make private_dirs does CA/: the key of FreeRADIUS is 0644 for the
# container, and only the directory keeps it in
chmod 700 "${KOITOHAN_GENERATED_ROOT}/CA"
# the file to fetch over TFTP, in the firmware of the test stack
echo koitohan-smoke > "${KOITOHAN_GENERATED_ROOT}/tftpboot/firmware/smoke.txt"
if ! { scripts/create_certs.sh > /dev/null 2>&1 \
       && scripts/generate_ldap_base.sh \
       && scripts/generate_freeradius_ldap.sh \
       && scripts/generate_device_networks.sh; }; then
  echo 'could not generate the files of the test stack'
  exit 1
fi
# the CA of the other host, with its own certificates; the test stack
# trusts it only while OPENLDAP_PEER_ADDRESS names that host
mkdir -p -m 700 "${PEER_ROOT}/CA"
if ! { KOITOHAN_GENERATED_ROOT="${PEER_ROOT}" OPENLDAP_HOST_ADDRESS="${PEER_ADDRESS}" \
         scripts/create_certs.sh > /dev/null 2>&1 \
       && cp "${PEER_ROOT}/CA/default-ca.pem" "${KOITOHAN_GENERATED_ROOT}/openldap/peer/ca.pem" \
       && mkdir -p "${PEER_ROOT}/openldap/peer" \
       && cp "${KOITOHAN_GENERATED_ROOT}/CA/default-ca.pem" "${PEER_ROOT}/openldap/peer/ca.pem"; }; then
  echo 'could not generate the certificates of the other host'
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

# configs as docs/tftp.md sets it up on the Docker host: in.tftpd (1000)
# writes, the role admin (10001) reads
if ! "${COMPOSE[@]}" exec -T tftpd-hpa sh -c '
       chown 1000:10001 /tftpboot/configs && chmod 2770 /tftpboot/configs'; then
  echo 'could not set up configs of tftpd-hpa'
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

# Users in groups other than the roles, which give nothing: guest is a
# role that is not one of the three, staff is outside ou=Roles. other03
# is in operator as well, which counts alone. bin/manage_users.sh makes
# none of them, so they are made by hand, after the test accounts and
# with numbers of their own, which leaves the numbers of the script as
# they are. The login of other03 shows that the users were read again.
check_ldap 'by hand' other01-03 'made other01 to other03' "
  for N in 1 2 3; do
    printf 'dn: uid=other0%s,ou=People,%s\nobjectClass: inetOrgPerson\nobjectClass: posixAccount\nuid: other0%s\nuidNumber: 2000%s\ngidNumber: 10000\nhomeDirectory: /home/other0%s\nloginShell: /bin/sh\ncn: other0%s\nsn: other0%s\n\n' \
      \"\${N}\" \"\${SUFFIX}\" \"\${N}\" \"\${N}\" \"\${N}\" \"\${N}\" \"\${N}\"
  done | ldapadd ${AS_MANAGER} > /dev/null \\
  && for N in 1 2 3; do
       ldappasswd ${AS_MANAGER} -s '${PASS_OTHER}' \"uid=other0\${N},ou=People,\${SUFFIX}\" || exit 1
     done \\
  && printf 'dn: cn=guest,ou=Roles,%s\nobjectClass: groupOfUniqueNames\ncn: guest\nuniqueMember: uid=other01,ou=People,%s\nuniqueMember: uid=other03,ou=People,%s\n\ndn: cn=staff,%s\nobjectClass: groupOfUniqueNames\ncn: staff\nuniqueMember: uid=other02,ou=People,%s\n\ndn: cn=operator,ou=Roles,%s\nchangetype: modify\nadd: uniqueMember\nuniqueMember: uid=other03,ou=People,%s\n' \
       \"\${SUFFIX}\" \"\${SUFFIX}\" \"\${SUFFIX}\" \"\${SUFFIX}\" \"\${SUFFIX}\" \"\${SUFFIX}\" \"\${SUFFIX}\" \\
     | ldapadd ${AS_MANAGER} > /dev/null \\
  && echo 'made other01 to other03'"
"${COMPOSE[@]}" exec -T openssh koitohan-update-users > /dev/null 2>&1

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
unknown|127.0.0.10|operator01|Accept|Management-Privilege-Level = 7
unknown|127.0.0.10|readonly01|Accept|Management-Privilege-Level = 1
unknown|127.0.0.10|readonly01|Accept|unknown nas_type: 'bogus'
unknown|127.0.0.10|norole01|Reject|-
vyos|127.0.0.11|admin01|Accept|AVPair = "shell:priv-lvl=15"
vyos|127.0.0.11|operator01|Accept|AVPair = "shell:priv-lvl=7"
vyos|127.0.0.11|readonly01|Accept|AVPair = "shell:priv-lvl=1"
vyos|127.0.0.11|norole01|Reject|-
cisco|127.0.0.1|other01|Reject|-
aruba-ap|127.0.0.3|other01|Reject|-
none|127.0.0.9|other01|Reject|-
cisco|127.0.0.1|other02|Reject|-
cisco|127.0.0.1|other03|Accept|AVPair = "shell:priv-lvl=7"
CASES

check 'bad password' 127.0.0.1 admin01 wrong Reject '-'
check 'unknown user' 127.0.0.1 nobody01 nopass Reject '-'

check_detail

check_tls tls1_3 accepted
check_tls tls1_2 refused

# The certificates for a redundant pair. The server certificate names
# the address that the other host connects to, and the bind checks it
# against the address in the URI. The replication certificate maps to
# the DN of replication, on a single host as well. One from the CA of
# the other host is refused while OPENLDAP_PEER_ADDRESS is none, though
# its ca.pem is there.
OUT=$(openssl x509 -noout -ext subjectAltName -in "${KOITOHAN_GENERATED_ROOT}/CA/openldap_server.crt" 2>&1)
check_found 'certs' 'server' "IP Address:${HOST_ADDRESS}" "${OUT}"
REPLICATION_DN='cn=replication,cn=koitohan'
OUT=$(openssl x509 -noout -subject -nameopt RFC2253 -in "${KOITOHAN_GENERATED_ROOT}/CA/openldap_replication.crt" 2>&1)
check_found 'certs' 'replication' "subject=CN=replication,OU=$(hostname -s),O=koitohan" "${OUT}"
check_peer_tls own "${KOITOHAN_GENERATED_ROOT}" "${REPLICATION_DN}"
check_peer_tls 'peer none' "${PEER_ROOT}" refused

# A single host has syncprov, and nothing else of replication: no
# server ID, no syncrepl.
check_ldap 'replication' 'single' '1 0 0 none' "${PAIR_CONFIG}"

# The filter of OpenLDAP: the test stack has none, as .env.sample, and
# lets in its own networks only. FreeRADIUS and OpenSSH coming in from
# them is what every check through RADIUS and SSH shows.
check_ldap_networks '' ''
check_ldap_networks '192.0.2.0/24 198.51.100.7' '192.0.2.0/24 198.51.100.7'
# slapd cannot change the rules: NET_ADMIN (bit 12) is out of its
# bounding set. A process that docker exec starts gets the capabilities
# of the container afresh, so nft in one says nothing about slapd.
OUT=$("${COMPOSE[@]}" exec -T openldap sh -c 'grep CapBnd /proc/$(pidof slapd)/status' 2>&1 < /dev/null)
WHY=''
if [[ ! "${OUT}" =~ CapBnd:[[:space:]]*([0-9a-f]{16}) ]]; then
  WHY='could not read the capabilities of slapd'
elif (( 16#${BASH_REMATCH[1]} & (1 << 12) )); then
  WHY='expected slapd to be without NET_ADMIN'
fi
report 'ldap networks' 'net_admin' 'slapd without it' "${WHY}" "${OUT}"

# The limit on the source of RADIUS, syslog, TFTP and NTP. The same request,
# message and file, first from a network that is allowed, then with the
# containers made again for another network. In between, the file
# that keeps the record of the transfer. The other requests of this
# test come from the loopback, which FreeRADIUS always allows.
check_radius_networks allowed 'Accept'
check_syslog_networks allowed 'received'
check_syslog_networks allowed-tcp 'received' tcp
check_syslog_sender allowed
check_tftp_networks allowed 'koitohan-smoke'
check_ntp networks allowed 'served'
check_tftp_log
check_tftp_uploads
# bin/check_services.sh, while every service works, then with one
# broken at a time. configs/ owned by root stands for the image file of
# docs/tftp.md that is not mounted.
check_services all healthy
"${COMPOSE[@]}" exec -T tftpd-hpa chown 0 /tftpboot/configs
check_services configs 'configs/: owned by 0, not 1000'
if ! "${COMPOSE[@]}" exec -T tftpd-hpa sh -c \
     'chown 1000:10001 /tftpboot/configs && chmod 2770 /tftpboot/configs'; then
  echo 'could not set up configs of tftpd-hpa again'
  exit 1
fi
"${COMPOSE[@]}" stop syslog-ng > /dev/null 2>&1
check_services syslog-ng 'syslog-ng: exited'
if ! "${COMPOSE[@]}" start syslog-ng > /dev/null 2>&1; then
  echo 'could not start syslog-ng again'
  exit 1
fi
if ! { DEVICE_NETWORKS="${OTHER_NETWORKS}" scripts/generate_device_networks.sh \
       && DEVICE_NETWORKS="${OTHER_NETWORKS}" "${COMPOSE[@]}" up -d --force-recreate freeradius syslog-ng tftpd-hpa chrony > /dev/null 2>&1; }; then
  echo 'could not make freeradius, syslog-ng, tftpd-hpa and chrony again'
  exit 1
fi
if ! wait_ready; then
  echo 'FreeRADIUS did not become ready again'
  "${COMPOSE[@]}" logs --tail 30 freeradius
  exit 1
fi
check_radius_networks other 'timed out'
check_syslog_networks other 'dropped'
check_syslog_networks other-tcp 'dropped' tcp
check_tftp_networks other 'timed out'
check_ntp networks other 'no reply'

# Values of the networks that nothing may start with
for SERVICE in freeradius tftpd-hpa openssh; do
  check_bad_networks "${SERVICE}" '' 'is empty'
  check_bad_networks "${SERVICE}" example.com 'must be IPv4'
  check_bad_networks "${SERVICE}" 10.0.0.0/33 'Error: Prefix length 33 is invalid'
done
# OpenLDAP takes none as well, but not with networks
check_bad_networks openldap '' 'is empty'
check_bad_networks openldap example.com 'must be none, or IPv4'
check_bad_networks openldap 10.0.0.0/33 'Error: Prefix length 33 is invalid'
check_bad_networks openldap 'none 10.0.0.0/8' 'must be none, or IPv4'
# The other host of a pair: none or one address, and its CA has to be
# there. ca.pem is moved away for a while: the directory is mounted.
for VALUE in '' example.com 203.0.113.256 '203.0.113.10 203.0.113.11'; do
  check_bad_value 'bad peer' OPENLDAP_PEER_ADDRESS openldap "${VALUE}" \
    'OPENLDAP_PEER_ADDRESS must be none or an IPv4 address'
done
mv "${KOITOHAN_GENERATED_ROOT}/openldap/peer/ca.pem" "${KOITOHAN_GENERATED_ROOT}/openldap/peer/ca.pem.away"
check_bad_value 'bad peer' OPENLDAP_PEER_ADDRESS openldap "${PEER_ADDRESS}" 'openldap/peer/ca.pem (the CA certificate of the other host) is missing'
mv "${KOITOHAN_GENERATED_ROOT}/openldap/peer/ca.pem.away" "${KOITOHAN_GENERATED_ROOT}/openldap/peer/ca.pem"
# A host of a pair needs its own address, which is not that of the
# other host: the two decide the server IDs.
OPENLDAP_PEER_ADDRESS="${PEER_ADDRESS}" check_bad_value 'bad peer' OPENLDAP_HOST_ADDRESS openldap none \
  'a host of a pair needs its own address'
check_bad_value 'bad peer' OPENLDAP_PEER_ADDRESS openldap "${HOST_ADDRESS}" 'are the same address'
check_bad_value 'bad host address' OPENLDAP_HOST_ADDRESS openldap example.com \
  'OPENLDAP_HOST_ADDRESS must be none or an IPv4 address'
# and the address of this host, before any certificate is made
for VALUE in example.com 198.51.100.256; do
  OUT=$(KOITOHAN_GENERATED_ROOT="${KOITOHAN_GENERATED_ROOT}/bad-address" OPENLDAP_HOST_ADDRESS="${VALUE}" \
          scripts/create_certs.sh 2>&1)
  RC=$?
  WHY=''
  if [[ ${RC} -eq 0 ]]; then
    WHY="'${VALUE}': expected create_certs.sh to fail"
  elif ! grep -q -F 'OPENLDAP_HOST_ADDRESS must be none or an IPv4 address' <<< "${OUT}"; then
    WHY="'${VALUE}': expected the reason"
  fi
  report 'bad host address' 'create_certs' "'${VALUE}': refused" "${WHY}" "$(tail -n 5 <<< "${OUT}")"
done
# chronyd itself stops on a malformed network, with its own words, but
# takes a host name
check_bad_networks chrony '' 'is empty'
check_bad_networks chrony example.com 'must be IPv4'
check_bad_networks chrony 10.0.0.0/33 'Bad subnet in 10.0.0.0/33'
check_bad_networks chrony 999.0.0.0/8 'Could not parse allow directive'
check_bad_value 'bad max error' NTP_MAX_ERROR_US chrony abc 'must be a number of microseconds'
for VALUE in example.com 10.0.0.0/33 999.0.0.0/8; do
  check_bad_generated "${VALUE}"
done
for VALUE in '' ldaps; do
  check_bad_value 'bad egress' OPENSSH_EGRESS openssh "${VALUE}" 'must be none, any, or ssh and icmp'
done

# chrony stops serving once the maxerror of the kernel is over the
# limit. The host clock stays in sync here, so the limit goes down to 0
# instead. The networks are the allowed ones again.
if ! NTP_MAX_ERROR_US=0 "${COMPOSE[@]}" up -d --force-recreate chrony > /dev/null 2>&1; then
  echo 'could not make chrony again'
  exit 1
fi
check_ntp 'max error' zero 'unsynchronised'
check_services chrony 'chrony: not serving'

if ! wait_ssh_ready; then
  echo 'the openssh container did not become ready'
  "${COMPOSE[@]}" logs --tail 30 openssh
  exit 1
fi

# a rotated log, as logrotate leaves it on the Docker host
mkdir -p "${KOITOHAN_GENERATED_ROOT}/syslog-ng/log/Hosts/smoke" \
  && echo "smoke LINK-3" | gzip > "${KOITOHAN_GENERATED_ROOT}/syslog-ng/log/Hosts/smoke/smoke.log-2026-10-10.gz"

NEW_PASS='x9#Kq!vT2m@Lz7Pw'
NEW_PASS2='Gh4$wN8^rB1&yD6s'
TOUCH='2> /dev/null && echo written || echo refused'

# the log of what the Docker host sent, as the users see it
HOST_LOG=$(syslog_log_of_host)

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
ssh login|other01|${PASS_OTHER}|denied|id -Gn
ssh login|other02|${PASS_OTHER}|denied|id -Gn
ssh login|other03|${PASS_OTHER}|koitohan operator|id -Gn
firmware|admin01|${PASS_ADMIN}|written|touch /tftpboot/firmware/smoke ${TOUCH}
firmware|operator01|${PASS_OPERATOR}|refused|touch /tftpboot/firmware/smoke ${TOUCH}
firmware|readonly01|${PASS_READONLY}|refused|touch /tftpboot/firmware/smoke ${TOUCH}
configs|admin01|${PASS_ADMIN}|written|touch /tftpboot/configs/smoke ${TOUCH}
configs|operator01|${PASS_OPERATOR}|refused|ls /tftpboot/configs ${TOUCH}
configs|readonly01|${PASS_READONLY}|refused|ls /tftpboot/configs ${TOUCH}
logs|readonly01|${PASS_READONLY}|smoke LINK-3|zgrep -h LINK-3 /logs/Hosts/*/*.log-2026-10-10.gz
logs|readonly01|${PASS_READONLY}|koitohan-smoke [allowed]|grep -h -o -F 'koitohan-smoke [allowed]' /logs/Hosts/${HOST_LOG:-missing}
CASES

check_read_only openssh
check_read_only openldap

# Some Docker hosts give the containers no limit on the descriptors, and
# then slapd aborts and nslcd keeps everyone out for minutes. Read the
# soft limit that the main process of each service got from compose.yaml.
while IFS='|' read -r SERVICE PROCESS; do
  WHY=''
  OUT=$("${COMPOSE[@]}" exec -T "${SERVICE}" sh -c "
    grep '^Max open files' /proc/\$(pidof -s ${PROCESS})/limits" 2>&1 < /dev/null)
  [[ "$(awk '{ print $4 }' <<< "${OUT}")" == '1024' ]] \
    || WHY="expected 1024 as the soft limit of ${PROCESS}"
  report 'nofile' "${SERVICE}" '1024' "${WHY}" "${OUT}"
done <<'SERVICES'
openldap|slapd
freeradius|freeradius
syslog-ng|syslog-ng
tftpd-hpa|in.tftpd
openssh|nslcd
chrony|chronyd
SERVICES

if ! start_egress_target; then
  echo 'could not start the target of the egress checks'
  exit 1
fi
check_egress_tcp ${EGRESS_PORT} refused
check_egress_icmp refused
check_egress_forwarding ${EGRESS_PORT} prohibited

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

# OpenLDAP stores the passwords as Argon2 hashes. By now they came in
# three ways: bin/manage_users.sh, ldappasswd over ldapi:/// and passwd.
# The value is in base64, and e0FSR09OMn0k is {ARGON2}$. The count keeps
# an empty answer from passing.
check_ldap 'hash scheme' 'ou=People' 'all {ARGON2}' "
  ldapsearch -LLL ${AS_MANAGER} -o ldif-wrap=no -b \"ou=People,\${SUFFIX}\" '(userPassword=*)' userPassword \\
  | awk '/^dn: /{dn=\$2} /^userPassword:/{n++; if (\$2 !~ /^e0FSR09OMn0k/) {print \"not Argon2: \" dn; bad++}} END{if (n >= 4 && !bad) print \"all {ARGON2}\"; else print n+0 \" hashes, \" bad+0 \" not Argon2\"}'"

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

# An ssh session of smoke01 that runs for a minute. A session that never
# got in ends quickly as well, so this returns once it has said that it
# runs, or WHY says that it did not.
SESSION_OUT="${KOITOHAN_GENERATED_ROOT}/session.out"
function start_session() {
  ssh_run smoke01 "${NEW_PASS}" 'echo started; sleep 60' < /dev/null > "${SESSION_OUT}" &
  SESSION_PID=$!
  for (( TRY = 1; TRY <= WAIT_TRIES; TRY++ )); do
    grep -q -x started "${SESSION_OUT}" && break
    sleep 1
  done
  WHY=''
  grep -q -x started "${SESSION_OUT}" || WHY='the session did not start'
}

# The session has to end within LIMIT seconds of the change
function check_session_cut() {
  local NAME=${1}
  local LIMIT=${2}

  SECONDS=0
  wait "${SESSION_PID}"
  [[ -z "${WHY}" && ${SECONDS} -ge ${LIMIT} ]] && WHY='expected the session to be cut'
  report "${NAME}" smoke01 'session cut' "${WHY}" || indent < "${SESSION_OUT}"
}

# A change that does not go through bin/manage_users.sh, nor through
# koitohan-update-users: the openssh container reads the users again by
# itself (every 5 seconds in the test stack), and ends the session of
# the user whose group is not the same. Without readonly, smoke01 is
# operator.
start_session
"${COMPOSE[@]}" exec -T openldap sh -c "${LDAP_SUFFIX_SET};"'
  printf "dn: cn=readonly,ou=Roles,%s\nchangetype: modify\ndelete: uniqueMember\nuniqueMember: uid=smoke01,ou=People,%s\n" \
    "${SUFFIX}" "${SUFFIX}" \
  | ldapmodify '"${AS_MANAGER}" > /dev/null 2>&1 || WHY='could not take smoke01 out of readonly'
check_session_cut 'periodic' 30
check_ssh 'periodic' smoke01 "${NEW_PASS}" 'koitohan operator' 'id -Gn' < /dev/null

# A change of the role through the script, which runs
# koitohan-update-users at once
start_session
check_users 'users role' 'smoke01 is admin now' '' role smoke01 admin
check_session_cut 'users role' 10
check_ssh 'users role' smoke01 "${NEW_PASS}" 'koitohan admin' 'id -Gn' < /dev/null

check_users 'users passwd' 'the password was refused' 'Password1' passwd smoke01
check_users 'users passwd' 'set the password' "${NEW_PASS2}" passwd smoke01
check_ssh 'users passwd' smoke01 "${NEW_PASS2}" 'koitohan admin' 'id -Gn' < /dev/null
check_ssh 'users passwd' smoke01 "${NEW_PASS}" denied 'id -Gn' < /dev/null

# an attribute of the default password policy
function policy_value() {
  "${COMPOSE[@]}" exec -T openldap sh -c "${LDAP_SUFFIX_SET};"'
    ldapsearch -Q -Y EXTERNAL -H ldapi:/// -LLL -b "cn=default,ou=Policies,${SUFFIX}" -s base '"${1}" \
    2> /dev/null | awk -v ATTR="${1}:" '$1 == ATTR { print $2 }'
}

# The checks below count on the values of the policy
function check_policy_number() {
  local ATTR=${1}
  local VALUE=${2}
  local WHY=''

  [[ "${VALUE}" =~ ^[1-9][0-9]*$ ]] || WHY="could not read ${ATTR}"
  report 'ppolicy' 'default' "${ATTR} ${VALUE}" "${WHY}"
}

# The password policy of OpenLDAP (ppolicy). A user who goes around
# passwd still meets the least length, and cannot store a hash, which
# would hide the length. The passwords are one short of the least length
# and just that long, whatever .env sets; the policy checks nothing else
# of them (no pwdCheckModule).
MIN_LENGTH=$(policy_value pwdMinLength)
check_policy_number pwdMinLength "${MIN_LENGTH}"
PASS_POOL=$(printf 'Ab3-%.0s' {1..16})
SHORT_PASS=${PASS_POOL:0:${MIN_LENGTH:-1}-1}
MIN_PASS=${PASS_POOL:0:${MIN_LENGTH:-1}}
AS_OPERATOR01='-x -H ldapi:/// -D "uid=operator01,ou=People,${SUFFIX}" -w '"'${PASS_OPERATOR}'"
check_ldap 'min length' operator01 'Password fails quality checking policy' \
  "ldappasswd ${AS_OPERATOR01} -s '${SHORT_PASS}'"
# If the policy took the short password after all, the password of the
# test comes back, so that the checks after this fail for their own reasons
"${COMPOSE[@]}" exec -T openldap sh -c "${LDAP_SUFFIX_SET}; ldappasswd ${AS_MANAGER} -s '${PASS_OPERATOR}' \"uid=operator01,ou=People,\${SUFFIX}\"" > /dev/null 2>&1
# The least length goes through. The password of the test comes back
# right after (the policy keeps no history), which the check of RADIUS
# below shows.
check_ldap 'min length' operator01 'took the least length' "
  ldappasswd ${AS_OPERATOR01} -s '${MIN_PASS}' \\
  && ldappasswd -x -H ldapi:/// -D \"uid=operator01,ou=People,\${SUFFIX}\" -w '${MIN_PASS}' -s '${PASS_OPERATOR}' \\
  && echo 'took the least length'"
check_ldap 'hashed' operator01 'Password fails quality checking policy' \
  "printf 'dn: uid=operator01,ou=People,%s\nchangetype: modify\nreplace: userPassword\nuserPassword: {SSHA}c21va2Vfc21va2Vfc21va2Vfc21va2U=\n' \"\${SUFFIX}\" | ldapmodify ${AS_OPERATOR01}"
check 'min length' 127.0.0.1 operator01 "${PASS_OPERATOR}" Accept 'AVPair = "shell:priv-lvl=7"'

# The lock. The failures come in over RADIUS and lock ssh as well.
check_users 'users unlock' 'smoke01 is not locked' '' unlock smoke01
# the lock below counts on it
MAX_FAILURE=$(policy_value pwdMaxFailure)
check_policy_number pwdMaxFailure "${MAX_FAILURE}"
# One failure short of the lock, the password still goes through, and
# the success counts the failures from 0 again. The old password of
# "users passwd" above still counts as a failure (unlock leaves the
# count alone while there is no lock), so a success comes first.
send_request 127.0.0.1 smoke01 "${NEW_PASS2}" > /dev/null
for (( TRY = 1; TRY < ${MAX_FAILURE:-0}; TRY++ )); do
  send_request 127.0.0.1 smoke01 wrong > /dev/null
done
check 'lock' 127.0.0.1 smoke01 "${NEW_PASS2}" Accept 'AVPair = "shell:priv-lvl=15"'
for (( TRY = 1; TRY <= ${MAX_FAILURE:-0}; TRY++ )); do
  send_request 127.0.0.1 smoke01 wrong > /dev/null
done
check 'lock' 127.0.0.1 smoke01 "${NEW_PASS2}" Reject '-'
check_ssh 'lock' smoke01 "${NEW_PASS2}" denied 'id -Gn' < /dev/null
check_users 'users unlock' 'unlocked smoke01' '' unlock smoke01
check 'users unlock' 127.0.0.1 smoke01 "${NEW_PASS2}" Accept 'AVPair = "shell:priv-lvl=15"'
check_ssh 'users unlock' smoke01 "${NEW_PASS2}" 'koitohan admin' 'id -Gn' < /dev/null

check_users 'users delete' 'deleted smoke01' '' delete smoke01
check_ssh 'users delete' smoke01 "${NEW_PASS2}" denied 'id -Gn' < /dev/null
check 'users delete' 127.0.0.1 smoke01 "${NEW_PASS2}" Reject '-'
check_users 'users delete' 'no such user' '' delete smoke01

# A search has no limit on its size (replication sends the whole tree).
# More entries than the old limit (500) go into an OU of their own, and
# openssh reads them all over LDAPS, as nslcd does. The OU goes again,
# so that nothing after this sees it.
SIZE_COUNT=520
check_ldap 'size limit' 'add' "added ${SIZE_COUNT}" "
  { printf 'dn: ou=SizeLimit,%s\nobjectClass: organizationalUnit\nou: SizeLimit\n\n' \"\${SUFFIX}\"
    I=1
    while [ \${I} -le ${SIZE_COUNT} ]; do
      printf 'dn: cn=size%s,ou=SizeLimit,%s\nobjectClass: device\ncn: size%s\n\n' \${I} \"\${SUFFIX}\" \${I}
      I=\$((I + 1))
    done; } | ldapadd -Q -Y EXTERNAL -H ldapi:/// > /dev/null \
  && echo \"added \$(ldapsearch -LLL -Q -Y EXTERNAL -H ldapi:/// -b ou=SizeLimit,\${SUFFIX} -s one 1.1 | grep -c '^dn:')\""
OUT=$("${COMPOSE[@]}" exec -T openssh sh -c '
  LDAP_SUFFIX="dc=$(echo "${LDAP_DOMAIN}" | sed "s/\./,dc=/g")"
  LDAPTLS_REQCERT=demand LDAPTLS_CACERT=/etc/koitohan/certs/ca.crt \
  LDAPTLS_CERT=/etc/koitohan/certs/client.crt LDAPTLS_KEY=/etc/koitohan/certs/client.key \
  ldapsearch -Q -Y EXTERNAL -LLL -H "${LDAP_URI}" -b "ou=SizeLimit,${LDAP_SUFFIX}" -s one 1.1 > /tmp/size.ldif
  echo "status $? entries $(grep -c "^dn:" /tmp/size.ldif)"
  rm -f /tmp/size.ldif' < /dev/null 2>&1)
check_found 'size limit' 'openssh' "status 0 entries ${SIZE_COUNT}" "${OUT}"
check_ldap 'size limit' 'delete' 'deleted' \
  "ldapdelete -r -Q -Y EXTERNAL -H ldapi:/// \"ou=SizeLimit,\${SUFFIX}\" && echo deleted"

# memberof and refint, without bin/manage_users.sh in between, as the
# other host of a pair or ldapi:/// may write. A user named by a group
# before it is added gets the memberOf of that group (AddCheck, for
# replication, which may bring the groups first). A user deleted
# directly is taken out of the groups by the refint overlay (the one of
# memberof is off). refint does that in the background, so the group is
# read again for a while.
check_ldap 'memberof' 'add check' 'memberOf: cn=readonly,ou=Roles,' "
  printf 'dn: cn=readonly,ou=Roles,%s\nchangetype: modify\nadd: uniqueMember\nuniqueMember: uid=addcheck01,ou=People,%s\n\ndn: uid=addcheck01,ou=People,%s\nchangetype: add\nobjectClass: inetOrgPerson\nuid: addcheck01\ncn: addcheck01\nsn: addcheck01\n' \
    \"\${SUFFIX}\" \"\${SUFFIX}\" \"\${SUFFIX}\" \
  | ldapmodify -Q -Y EXTERNAL -H ldapi:/// > /dev/null \
  && ldapsearch -LLL -Q -Y EXTERNAL -H ldapi:/// -b \"uid=addcheck01,ou=People,\${SUFFIX}\" -s base memberOf"
check_ldap 'memberof' 'refint' 'out of the group' "
  ldapdelete -Q -Y EXTERNAL -H ldapi:/// \"uid=addcheck01,ou=People,\${SUFFIX}\" || exit 1
  TRY=0
  while [ \${TRY} -lt 30 ]; do
    ldapsearch -LLL -Q -Y EXTERNAL -H ldapi:/// -b \"cn=readonly,ou=Roles,\${SUFFIX}\" -s base uniqueMember \
      | grep -q -i '^uniqueMember: uid=addcheck01,' || { echo 'out of the group'; exit 0; }
    TRY=\$((TRY + 1))
    sleep 0.2
  done
  echo 'still in the group'"
check_users 'users add' 'uidNumber 10005' "${NEW_PASS}" add smoke02 readonly

# The way out of the openssh container, opened by a word at a time.
recreate_egress ssh
check_egress_tcp 22 reached
check_egress_tcp ${EGRESS_PORT} refused
check_egress_icmp refused
check_egress_forwarding 22 reached
check_egress_forwarding ${EGRESS_PORT} refused
recreate_egress icmp
check_egress_icmp reached
check_egress_tcp 22 refused
check_egress_tcp ${EGRESS_PORT} refused
check_egress_forwarding 22 prohibited
# both words, in the other order than the guides give them
recreate_egress 'icmp ssh'
check_egress_tcp 22 reached
check_egress_icmp reached
check_egress_tcp ${EGRESS_PORT} refused
check_egress_forwarding 22 reached
# Opened wide. The limit on the source of ssh that follows makes the
# container again with OPENSSH_EGRESS of the test, then it is made once
# more, for the networks of the test. Keep the three in this order.
recreate_egress any
check_egress_tcp ${EGRESS_PORT} reached
check_egress_icmp reached
check_egress_forwarding ${EGRESS_PORT} reached
check_egress_own
check_ssh_other_network
"${COMPOSE[@]}" up -d --force-recreate openssh > /dev/null 2>&1
# the new container has another address
if ! wait_ssh_ready; then
  echo 'the openssh container did not become ready for the networks of the test'
  "${COMPOSE[@]}" logs --tail 30 openssh
  exit 1
fi
check_ssh 'networks' admin01 "${PASS_ADMIN}" 'koitohan admin' 'id -Gn' < /dev/null

# FreeRADIUS and OpenSSH bind with their client certificates alone,
# which OpenLDAP maps to DNs that have no entry. Every login so far went
# through these binds, and this openldap has seen them all.
for SERVICE in freeradius openssh; do
  WHY=''
  "${COMPOSE[@]}" logs openldap 2>&1 \
    | grep -q -F "BIND dn=\"cn=${SERVICE},cn=koitohan\" mech=EXTERNAL" \
    || WHY="expected a bind as cn=${SERVICE},cn=koitohan with EXTERNAL"
  report 'service identity' "${SERVICE}" 'bound with the certificate' "${WHY}"
done
# no simple bind but those of the users
OUT=$("${COMPOSE[@]}" logs openldap 2>&1 | grep -F 'BIND dn=' | grep -F 'method=128' \
      | grep -v -F 'ou=People,')
WHY=''
[[ -n "${OUT}" ]] && WHY='expected no other simple bind'
report 'service identity' 'simple bind' 'users only' "${WHY}" "${OUT}"

WHY=''
[[ -n "$(find CA -newer "${ASKPASS}" 2> /dev/null)" ]] \
  && WHY='expected the files of the running stack to stay'
report 'running stack' 'CA/' 'untouched' "${WHY}"

# The administrators of OpenLDAP have no password, and nobody can bind
# as them. The restart below cuts the two connections of FreeRADIUS, so
# from here to "ldap restart" nothing goes through RADIUS.
ROOTPW_COUNT='ldapsearch -LLL -Q -Y EXTERNAL -H ldapi:/// -b cn=config "(olcRootPW=*)" dn | grep -c "^dn:"'
check_ldap 'admin pass' 'none' 'olcRootPW: 0' "echo \"olcRootPW: \$(${ROOTPW_COUNT})\""
check_admin_bind 'admin pass' admin 'smoke-root-pw' 'Invalid credentials'
check_admin_bind 'admin pass' config 'smoke-root-pw' 'Invalid credentials'
# One written over ldapi:/// works until the restart, which removes it.
check_ldap 'admin pass' 'written' 'modifying entry "olcDatabase={1}mdb,cn=config"' \
  'ldapmodify -Q -Y EXTERNAL -H ldapi:///' \
  'dn: olcDatabase={0}config,cn=config\nchangetype: modify\nreplace: olcRootPW\nolcRootPW: smoke-root-pw\n\ndn: olcDatabase={1}mdb,cn=config\nchangetype: modify\nreplace: olcRootPW\nolcRootPW: smoke-root-pw\n'
check_admin_bind 'admin pass' admin 'smoke-root-pw' 'dn:cn=admin,dc='
check_admin_bind 'admin pass' config 'smoke-root-pw' 'dn:cn=admin,cn=config'

# The minimum of TLS is written on every start as well. Lowered over
# ldapi:/// here, it has to be back after the restart.
check_ldap 'tls minimum' 'config' 'modifying entry "cn=config"' \
  'ldapmodify -Q -Y EXTERNAL -H ldapi:///' \
  'dn: cn=config\nchangetype: modify\nreplace: olcTLSProtocolMin\nolcTLSProtocolMin: 3.3\n'
# the same for the scheme of the password hashes
check_ldap 'hash scheme' 'config' 'modifying entry "olcDatabase={-1}frontend,cn=config"' \
  'ldapmodify -Q -Y EXTERNAL -H ldapi:///' \
  'dn: olcDatabase={-1}frontend,cn=config\nchangetype: modify\nreplace: olcPasswordHash\nolcPasswordHash: {SSHA}\n'
# and for the limit on the size of a search
check_ldap 'size limit' 'config' 'modifying entry "olcDatabase={-1}frontend,cn=config"' \
  'ldapmodify -Q -Y EXTERNAL -H ldapi:///' \
  'dn: olcDatabase={-1}frontend,cn=config\nchangetype: modify\nreplace: olcSizeLimit\nolcSizeLimit: 500\n'
# and for the settings of memberof (AddCheck first: memberof refuses it
# while its own RefInt is on)
check_ldap 'memberof' 'config' 'modifying entry "olcOverlay={0}memberof,olcDatabase={1}mdb,cn=config"' \
  'ldapmodify -Q -Y EXTERNAL -H ldapi:///' \
  'dn: olcOverlay={0}memberof,olcDatabase={1}mdb,cn=config\nchangetype: modify\nreplace: olcMemberOfAddCheck\nolcMemberOfAddCheck: FALSE\n\ndn: olcOverlay={0}memberof,olcDatabase={1}mdb,cn=config\nchangetype: modify\nreplace: olcMemberOfRefInt\nolcMemberOfRefInt: TRUE\n'
# and for the identities of the services and the access control. With
# these gone, FreeRADIUS and OpenSSH read nothing: the logins after the
# restart below show that they are back.
check_ldap 'service identity' 'config' 'modifying entry "olcDatabase={1}mdb,cn=config"' \
  'ldapmodify -Q -Y EXTERNAL -H ldapi:///' \
  'dn: cn=config\nchangetype: modify\ndelete: olcAuthzRegexp\n\ndn: olcDatabase={1}mdb,cn=config\nchangetype: modify\ndelete: olcAccess\nolcAccess: {2}\n'
# and for replication: a single host has no server ID
check_ldap 'replication' 'config' 'modifying entry "cn=config"' \
  'ldapmodify -Q -Y EXTERNAL -H ldapi:///' \
  'dn: cn=config\nchangetype: modify\nreplace: olcServerID\nolcServerID: 7\n'

check_restart

check_ldap 'tls minimum' 'config' 'olcTLSProtocolMin: 3.4' \
  'ldapsearch -LLL -Q -Y EXTERNAL -H ldapi:/// -b cn=config -s base olcTLSProtocolMin'
check_ldap 'hash scheme' 'config' 'olcPasswordHash: {ARGON2}' \
  "ldapsearch -LLL -Q -Y EXTERNAL -H ldapi:/// -b 'olcDatabase={-1}frontend,cn=config' -s base olcPasswordHash"
check_ldap 'service identity' 'config' '"cn=openssh,cn=koitohan"' \
  'ldapsearch -LLL -Q -Y EXTERNAL -H ldapi:/// -b cn=config -s base olcAuthzRegexp'
check_ldap 'replication' 'identity' '"cn=replication,cn=koitohan"' \
  'ldapsearch -LLL -o ldif-wrap=no -Q -Y EXTERNAL -H ldapi:/// -b cn=config -s base olcAuthzRegexp'
check_ldap 'replication' 'config' '1 0 0 none' "${PAIR_CONFIG}"
check_ldap 'size limit' 'config' 'olcSizeLimit: unlimited' \
  "ldapsearch -LLL -Q -Y EXTERNAL -H ldapi:/// -b 'olcDatabase={-1}frontend,cn=config' -s base olcSizeLimit"
check_ldap 'memberof' 'config' 'olcMemberOfAddCheck: TRUE olcMemberOfRefInt: FALSE' \
  "ldapsearch -LLL -Q -Y EXTERNAL -H ldapi:/// -b 'olcOverlay={0}memberof,olcDatabase={1}mdb,cn=config' -s base olcMemberOfAddCheck olcMemberOfRefInt | grep '^olcMemberOf' | sort | paste -s -d ' '"

# the image removes the passwords of the administrators on every start
check_ldap 'ldap restart' 'rootpw' 'olcRootPW: 0' "echo \"olcRootPW: \$(${ROOTPW_COUNT})\""
check_admin_bind 'ldap restart' admin 'smoke-root-pw' 'Invalid credentials'
check_admin_bind 'ldap restart' config 'smoke-root-pw' 'Invalid credentials'

# nslcd has to find the restarted OpenLDAP again
check_ssh 'ldap restart' admin01 "${PASS_ADMIN}" 'koitohan admin' 'id -Gn' < /dev/null

# So has FreeRADIUS, and within the login that finds out. Both of its
# connections are from before OpenLDAP was restarted, and this is the
# first request since. Without backlog_on_failed_conn in
# ldap_openldap it is rejected, and so is the one after it.
check 'ldap restart' 127.0.0.1 admin01 "${PASS_ADMIN}" Accept 'AVPair = "shell:priv-lvl=15"'

# While OpenLDAP is down, FreeRADIUS does not answer. A reject would
# keep a device from turning to another server or to its local accounts.
# The first login after OpenLDAP is back goes through.
"${COMPOSE[@]}" stop openldap > /dev/null 2>&1
OUT=$(send_request 127.0.0.1 admin01 "${PASS_ADMIN}")
WHY=''
grep -q -F 'No reply from server' <<< "${OUT}" || WHY='expected no reply'
report 'ldap down' admin01 'no reply' "${WHY}" "${OUT}"
"${COMPOSE[@]}" start openldap > /dev/null 2>&1
wait_ldap_ready
check 'ldap down' 127.0.0.1 admin01 "${PASS_ADMIN}" Accept 'AVPair = "shell:priv-lvl=15"'

# Backup and restore. A backup of the test stack, a change after it,
# then openldap made again with empty volumes and the backup loaded into
# it. The change has to be gone, and what was there at the backup has to
# be back: the users, their passwords and roles, the next uidNumber, and
# the files in configs/ with their owners. bin/backup.sh and
# bin/restore_ldap.sh find the test stack through COMPOSE_PROJECT_NAME
# and COMPOSE_FILE, and bin/backup.sh its files through the mounts of
# its containers.
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
  openssh/hostkeys/ssh_host_ed25519_key ldap/config.ldif ldap/data.ldif \
  tftp-configs.tar koitohan-backup.txt
do
  grep -q -x -F -- "${MEMBER}" <<< "${OUT}" || WHY="${WHY} ${MEMBER}"
done
grep -q '/$' <<< "${OUT}" && WHY="${WHY} (directories)"
# nothing is kept in secrets/ any more
grep -q '^secrets/' <<< "${OUT}" && WHY="${WHY} (secrets/)"
[[ -z "${WHY}" ]] && OUT='all members'
check_found 'backup' 'members' 'all members' "${OUT}"

# the files of the test stack, not those of the running one
OUT='other files'
tar -x -O -z -f "${ARCHIVE}" freeradius/config/clients.conf | cmp -s - tests/clients.conf \
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

# configs/, as docs/backup.md restores it
OUT=$(tar -x -O -z -f "${ARCHIVE}" tftp-configs.tar \
      | "${COMPOSE[@]}" exec -T tftpd-hpa tar -x -f - -C /tftpboot 2>&1 \
      && "${COMPOSE[@]}" exec -T tftpd-hpa sh -c '
           F=/tftpboot/configs/smoke.cfg; echo "$(stat -c "%u:%g %a" ${F}) $(cat ${F})"' 2>&1)
check_found 'restore' 'configs' '1000:10001 640 koitohan-smoke' "${OUT}"

# The other host of a pair is set: openldap is made again with it, and
# trusts its CA as well as its own. The directory has the mark, so this
# is a start like any other.
if ! OPENLDAP_PEER_ADDRESS="${PEER_ADDRESS}" "${COMPOSE[@]}" up -d --no-deps openldap > /dev/null 2>&1 \
   || ! wait_ldap_ready; then
  echo 'openldap did not start with the other host set'
  "${COMPOSE[@]}" logs --tail 30 openldap
  exit 1
fi
check_peer_tls 'peer set' "${PEER_ROOT}" "${REPLICATION_DN}"
check_peer_tls 'own, peer set' "${KOITOHAN_GENERATED_ROOT}" "${REPLICATION_DN}"

# The identity of replication, as the other host uses it: it reads the
# whole tree with the passwords, and writes nothing.
OUT=$(as_peer 'ldapsearch -LLL -Q -Y EXTERNAL -H ldaps://'"${HOST_ADDRESS}"' -b "uid=admin01,ou=People,${SUFFIX}" -s base userPassword')
check_found 'replication' 'read' 'userPassword:' "${OUT}"
OUT=$(as_peer 'printf "dn: uid=admin01,ou=People,${SUFFIX}\nchangetype: modify\nreplace: description\ndescription: from the peer\n" \
               | ldapmodify -Q -Y EXTERNAL -H ldaps://'"${HOST_ADDRESS}")
check_found 'replication' 'write' 'Insufficient access' "${OUT}"

# openldap is host A of a pair from here: a server ID, syncprov, and the
# syncrepl towards host B (openldap-b)
check_ldap 'replication' 'host A' "1 1 1 id 1 provider=ldaps://${PEER_ADDRESS}:636" "${PAIR_CONFIG}"

# Host B starts empty, and receives the data from host A. A failed bind
# leaves a record of ppolicy on host A first, which has to come along.
on_ldap openldap 'ldapwhoami -x -H ldapi:/// -D "uid=readonly01,ou=People,${SUFFIX}" -w wrong-password' > /dev/null
# Host A is away when host B starts. Host B waits for it, and does not
# listen on LDAPS meanwhile.
"${COMPOSE[@]}" stop openldap > /dev/null 2>&1
"${COMPOSE[@]}" up -d --no-deps openldap-b > /dev/null 2>&1
WHY=''
wait_log openldap-b 'waiting for the data from' || WHY='expected host B to wait'
report 'pair receive' 'waiting' 'waits for host A' "${WHY}" "$("${COMPOSE[@]}" logs --tail 5 openldap-b 2>&1)"
check_found 'pair receive' 'waiting' '636 closed koitohan-receiving' "$(on_ldap openldap-b "${PAIR_STATE}")"
# stopped halfway, it starts over
"${COMPOSE[@]}" stop openldap-b > /dev/null 2>&1
"${COMPOSE[@]}" start openldap-b > /dev/null 2>&1
WHY=''
wait_log openldap-b 'stopped halfway: deleting it' || WHY='expected host B to start over'
report 'pair receive' 'stopped' 'starts over' "${WHY}" "$("${COMPOSE[@]}" logs --tail 5 openldap-b 2>&1)"
# and waits again, with nothing of the first try left that would stop it
for (( TRY = 1; TRY <= 15; TRY++ )); do
  [[ $("${COMPOSE[@]}" logs openldap-b 2>&1 | grep -c -F 'receiving the data from the other host') -ge 2 ]] && break
  sleep 2
done
check_found 'pair receive' 'stopped' '636 closed koitohan-receiving' "$(on_ldap openldap-b "${PAIR_STATE}")"

# host A is back
"${COMPOSE[@]}" start openldap > /dev/null 2>&1
if ! wait_ldap_ready; then
  echo 'host A did not start again'
  "${COMPOSE[@]}" logs --tail 30 openldap
  exit 1
fi
link_pair
WHY=''
wait_log openldap-b 'received the data from the other host' 60 || WHY='expected host B to receive the data'
report 'pair receive' 'received' 'all of it' "${WHY}" "$("${COMPOSE[@]}" logs --tail 10 openldap-b 2>&1)"
check_found 'pair receive' 'serving' '636 listening koitohan-seeded' "$(on_ldap openldap-b "${PAIR_STATE}")"
OUT=$("${COMPOSE[@]}" logs openldap-b 2>&1)
grep -q -F 'seeding' <<< "${OUT}" || OUT='not seeded'
check_found 'pair receive' 'openldap-b' 'not seeded' "${OUT}"
check_found 'replication' 'host B' "1 1 1 id 2 provider=ldaps://${HOST_ADDRESS}:636" \
  "$(on_ldap openldap-b "${PAIR_CONFIG}")"
check_pair_same 'received'
# made on host B from the groups, not received
check_found 'pair receive' 'memberOf' 'memberOf: cn=admin,ou=Roles' \
  "$(on_ldap openldap-b 'ldapsearch -LLL -Q -Y EXTERNAL -H ldapi:/// -b "uid=admin01,ou=People,${SUFFIX}" -s base memberOf')"
check_found 'pair receive' 'ppolicy' 'pwdFailureTime:' \
  "$(on_ldap openldap-b 'ldapsearch -LLL -Q -Y EXTERNAL -H ldapi:/// -b "uid=readonly01,ou=People,${SUFFIX}" -s base pwdFailureTime')"
check_found 'pair receive' 'password' 'dn:uid=admin01,ou=People' \
  "$(on_ldap openldap-b "ldapwhoami -x -H ldapi:/// -D \"uid=admin01,ou=People,\${SUFFIX}\" -w '${PASS_ADMIN}'")"

# Both ways from here. A user added on host B, with a role and a
# password, logs in through the FreeRADIUS of host A. FreeRADIUS does
# not get over the changes of openldap above, so it is made again.
on_ldap openldap-b "ldapadd -Q -Y EXTERNAL -H ldapi:/// > /dev/null <<EOF
dn: uid=pair01,ou=People,\${SUFFIX}
objectClass: inetOrgPerson
objectClass: posixAccount
uid: pair01
uidNumber: 19001
gidNumber: 10000
homeDirectory: /home/pair01
loginShell: /bin/sh
cn: pair01
sn: pair01

dn: cn=readonly,ou=Roles,\${SUFFIX}
changetype: modify
add: uniqueMember
uniqueMember: uid=pair01,ou=People,\${SUFFIX}
EOF
ldappasswd -Q -Y EXTERNAL -H ldapi:/// -s '${PASS_OTHER}' \"uid=pair01,ou=People,\${SUFFIX}\"" > /dev/null
check_pair_same 'added on B'
if ! "${COMPOSE[@]}" up -d --no-deps --force-recreate freeradius > /dev/null 2>&1 || ! wait_ready; then
  echo 'freeradius did not start again for the pair'
  "${COMPOSE[@]}" logs --tail 30 freeradius
  exit 1
fi
check 'pair' 127.0.0.1 pair01 "${PASS_OTHER}" Accept 'AVPair = "shell:priv-lvl=1"'
# a failure on host A reaches host B
on_ldap openldap 'ldapwhoami -x -H ldapi:/// -D "uid=pair01,ou=People,${SUFFIX}" -w wrong-password' > /dev/null
check_pair_same 'failure on A'
check_found 'pair' 'failure on A' 'pwdFailureTime:' \
  "$(on_ldap openldap-b 'ldapsearch -LLL -Q -Y EXTERNAL -H ldapi:/// -b "uid=pair01,ou=People,${SUFFIX}" -s base pwdFailureTime')"
# deleted on host B, the user leaves the group on host A as well (refint
# on host B changes the group, which is replicated)
on_ldap openldap-b 'ldapdelete -Q -Y EXTERNAL -H ldapi:/// "uid=pair01,ou=People,${SUFFIX}"' > /dev/null
check_pair_same 'deleted on B'
check_found 'pair' 'deleted on B' 'uid=pair01: 0' \
  "$(on_ldap openldap 'echo "uid=pair01: $(ldapsearch -LLL -Q -Y EXTERNAL -H ldapi:/// -b "${SUFFIX}" "(|(uid=pair01)(uniqueMember=uid=pair01,ou=People,${SUFFIX}))" dn | grep -c "^dn:")"')"

# The settings of replication are written on every start: changed over
# ldapi:/// on host A, they are back after a restart, and the two hosts
# go on.
check_ldap 'replication' 'host A' 'modifying entry "olcDatabase={1}mdb,cn=config"' \
  'ldapmodify -Q -Y EXTERNAL -H ldapi:///' \
  'dn: cn=config\nchangetype: modify\nreplace: olcServerID\nolcServerID: 5\n\ndn: olcDatabase={1}mdb,cn=config\nchangetype: modify\nreplace: olcSyncrepl\nolcSyncrepl: rid=001 provider=ldaps://192.0.2.1:636 bindmethod=sasl saslmech=EXTERNAL searchbase="dc=invalid" type=refreshAndPersist retry="10 +"\n'
"${COMPOSE[@]}" restart openldap > /dev/null 2>&1
if ! wait_ldap_ready; then
  echo 'host A did not start again'
  "${COMPOSE[@]}" logs --tail 30 openldap
  exit 1
fi
link_pair
check_ldap 'replication' 'host A' "1 1 1 id 1 provider=ldaps://${PEER_ADDRESS}:636" "${PAIR_CONFIG}"
on_ldap openldap-b 'ldapmodify -Q -Y EXTERNAL -H ldapi:/// > /dev/null <<EOF
dn: cn=operator,ou=Roles,${SUFFIX}
changetype: modify
replace: description
description: after the restart of host A
EOF' > /dev/null
check_pair_same 'restarted A'

# Without the other host, openldap is a single host again: no server
# ID, no syncrepl, and syncprov stays.
if ! "${COMPOSE[@]}" up -d --no-deps openldap > /dev/null 2>&1 || ! wait_ldap_ready; then
  echo 'openldap did not start without the other host'
  "${COMPOSE[@]}" logs --tail 30 openldap
  exit 1
fi
check_ldap 'replication' 'single again' '1 0 0 none' "${PAIR_CONFIG}"

echo
if [[ ${FAILED} -ne 0 ]]; then
  echo "${FAILED} of ${COUNT} checks failed"
  exit 1
fi
echo "all ${COUNT} checks passed"
