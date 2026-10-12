#!/bin/bash
#
# Smoke test for the AAA path (FreeRADIUS -> LDAPS -> OpenLDAP) and for
# the workspace container (ssh -> OpenSSH -> LDAPS -> OpenLDAP).
#
# Starts openldap, freeradius and openssh as a separate compose project,
# seeded with the test accounts. Checks the reply for every combination
# of reply type and role, then logs in over ssh as each role. The
# running stack is left alone.
#
#   KEEP=1 tests/smoke.sh    leave the test stack up for a closer look

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"

cd "${ROOT_DIR}"

COMPOSE=(docker compose -p koitohan-test -f compose.yaml -f tests/compose.test.yaml)
SECRET='testing123'
WAIT_TRIES=40

function cleanup() {
  rm -f "${ASKPASS}"
  if [ -n "${KEEP}" ]; then
    echo "test stack left up: ${COMPOSE[*]} down -v"
  else
    "${COMPOSE[@]}" down -v > /dev/null 2>&1
  fi
}

function password_of() {
  case ${1} in
    admin01)    echo 'passadmin' ;;
    operator01) echo 'passoperator' ;;
    readonly01) echo 'passreadonly' ;;
    norole01)   echo 'passnorole' ;;
    *)          echo 'nopass' ;;
  esac
}

# send an Access-Request from the given source address
function send_request() {
  local SRC=${1}
  local USER=${2}
  local PASS=${3}

  echo "User-Name = \"${USER}\", User-Password = \"${PASS}\", Net.Src.IP = ${SRC}" \
  | "${COMPOSE[@]}" exec -T freeradius radclient -x -t 5 -r 1 127.0.0.1:1812 auth ${SECRET} 2>&1
}

# the attributes of the reply, without Message-Authenticator
function reply_attrs() {
  sed -n '/^Received /,$p' \
  | grep -v -e '^Received ' -e '^(' -e 'Message-Authenticator'
}

# the test accounts appear once OpenLDAP has loaded the seed LDIFs
function wait_ready() {
  local TRY

  for TRY in $(seq ${WAIT_TRIES}); do
    if send_request 127.0.0.1 admin01 passadmin | grep -q '^Received Access-Accept'; then
      return 0
    fi
    sleep 3
  done
  return 1
}

FAILED=0
COUNT=0

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
  ATTRS=$(echo "${OUT}" | reply_attrs)

  if ! echo "${OUT}" | grep -q "^Received Access-${CODE}"; then
    WHY="expected Access-${CODE}"
  elif [ "${EXPECT}" = '-' ]; then
    [ -z "${ATTRS}" ] || WHY='expected no attributes'
  elif ! echo "${ATTRS}" | grep -q -F -- "${EXPECT}"; then
    WHY="expected ${EXPECT}"
  fi

  COUNT=$((COUNT + 1))
  if [ -z "${WHY}" ]; then
    printf 'ok    %-13s %-11s %s\n' "${NAME}" "${USER}" "Access-${CODE}"
  else
    FAILED=$((FAILED + 1))
    printf 'FAIL  %-13s %-11s %s\n' "${NAME}" "${USER}" "${WHY}"
    echo "${OUT}" | sed 's/^/      | /'
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

# the users appear once the container has read them from OpenLDAP
function wait_ssh_ready() {
  local TRY

  for TRY in $(seq ${WAIT_TRIES}); do
    SSH_ADDR=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' \
      "$("${COMPOSE[@]}" ps -q openssh)" 2> /dev/null)
    if [ -n "${SSH_ADDR}" ] && ssh_run admin01 passadmin true < /dev/null > /dev/null; then
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

  if [ "${EXPECT}" = 'denied' ]; then
    echo "${OUT}" | grep -q -F 'Permission denied (password)' || WHY='expected the login to fail'
  elif ! echo "${OUT}" | grep -q -F -- "${EXPECT}"; then
    WHY="expected ${EXPECT}"
  fi

  COUNT=$((COUNT + 1))
  if [ -z "${WHY}" ]; then
    printf 'ok    %-13s %-11s %s\n' "${NAME}" "${USER}" "${EXPECT}"
  else
    FAILED=$((FAILED + 1))
    printf 'FAIL  %-13s %-11s %s\n' "${NAME}" "${USER}" "${WHY}"
    echo "${OUT}" | sed 's/^/      | /'
  fi
}

# The same container has to start a second time, as it does after a
# reboot of the host. This asks slapd itself and leaves FreeRADIUS out.
function check_restart() {
  local TRY WHY='expected a bind to succeed'
  local DN='uid=admin01,ou=People,dc=${LDAP_DOMAIN//./,dc=}'
  local BIND="ldapwhoami -x -H ldapi:/// -w passadmin -D \"${DN}\""

  "${COMPOSE[@]}" restart openldap > /dev/null 2>&1
  for TRY in $(seq ${WAIT_TRIES}); do
    if [ -z "$("${COMPOSE[@]}" ps --status running -q openldap)" ]; then
      WHY='openldap exited'
      break
    fi
    if "${COMPOSE[@]}" exec -T openldap bash -c "${BIND}" > /dev/null 2>&1; then
      WHY=''
      break
    fi
    sleep 3
  done

  COUNT=$((COUNT + 1))
  if [ -z "${WHY}" ]; then
    printf 'ok    %-13s %-11s %s\n' 'ldap restart' admin01 'bind'
  else
    FAILED=$((FAILED + 1))
    printf 'FAIL  %-13s %-11s %s\n' 'ldap restart' admin01 "${WHY}"
    "${COMPOSE[@]}" logs --tail 5 openldap 2>&1 | sed 's/^/      | /'
  fi
}

# a missing source of a file bind mount would be created as a directory
for FILE in \
  CA/default-ca.pem \
  CA/openldap_server.crt \
  CA/freeradius_client.crt \
  CA/openssh_client.crt \
  openssh/hostkeys/ssh_host_ed25519_key \
  openldap/ldif/100-People.ldif \
  freeradius/config/mods-available/ldap_openldap \
  tests/ldif/250-TestAccounts.ldif
do
  if [ ! -e "${FILE}" ]; then
    echo "${FILE} is missing. Run 'make' first, then 'make test'."
    exit 1
  fi
done

ASKPASS=$(mktemp)
printf '#!/bin/sh\necho "${SSH_TEST_PASS}"\n' > "${ASKPASS}"
chmod 700 "${ASKPASS}"

trap cleanup EXIT

echo 'starting the test stack'
if ! "${COMPOSE[@]}" up -d --build openldap freeradius openssh > /dev/null 2>&1; then
  echo 'failed to start the test stack'
  "${COMPOSE[@]}" up -d --build openldap freeradius openssh
  exit 1
fi

if ! wait_ready; then
  echo 'the test stack did not become ready'
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

if ! wait_ssh_ready; then
  echo 'the openssh container did not become ready'
  "${COMPOSE[@]}" logs --tail 30 openssh
  exit 1
fi

NEW_PASS='x9#Kq!vT2m@Lz7Pw'
TOUCH='2> /dev/null && echo written || echo refused'

# name | user | password | expected output | command
while IFS='|' read -r NAME USER PASS EXPECT COMMAND; do
  check_ssh "${NAME}" "${USER}" "${PASS}" "${EXPECT}" "${COMMAND}" < /dev/null
done <<CASES
ssh login|admin01|passadmin|koitohan admin|id -Gn
ssh login|operator01|passoperator|koitohan operator|id -Gn
ssh login|readonly01|passreadonly|koitohan readonly|id -Gn
ssh login|norole01|passnorole|denied|id -Gn
ssh login|admin01|wrong|denied|id -Gn
ssh login|nobody01|nopass|denied|id -Gn
ssh login|root|nopass|denied|id -Gn
firmware|admin01|passadmin|written|touch /tftpboot/firmware/smoke ${TOUCH}
firmware|operator01|passoperator|refused|touch /tftpboot/firmware/smoke ${TOUCH}
firmware|readonly01|passreadonly|refused|touch /tftpboot/firmware/smoke ${TOUCH}
configs|admin01|passadmin|written|touch /tftpboot/configs/smoke ${TOUCH}
configs|operator01|passoperator|refused|ls /tftpboot/configs ${TOUCH}
configs|readonly01|passreadonly|refused|ls /tftpboot/configs ${TOUCH}
root fs|admin01|passadmin|refused|touch /smoke ${TOUCH}
secrets|admin01|passadmin|refused|cat /run/koitohan/bindpw /etc/koitohan/certs/client.key ${TOUCH}
CASES

# passwd reads the current password, then the new one twice
check_ssh 'weak password' readonly01 passreadonly 'Weak password' passwd \
  'passreadonly\nPassword1\nPassword1\n'
check_ssh 'passwd' readonly01 passreadonly 'password updated successfully' passwd \
  "passreadonly\n${NEW_PASS}\n${NEW_PASS}\n"
check_ssh 'new password' readonly01 "${NEW_PASS}" 'koitohan readonly' 'id -Gn' < /dev/null
check_ssh 'old password' readonly01 passreadonly denied 'id -Gn' < /dev/null

check_restart

# nslcd has to find the restarted OpenLDAP again
check_ssh 'ldap restart' admin01 passadmin 'koitohan admin' 'id -Gn' < /dev/null

echo
if [ ${FAILED} -ne 0 ]; then
  echo "${FAILED} of ${COUNT} checks failed"
  exit 1
fi
echo "all ${COUNT} checks passed"
