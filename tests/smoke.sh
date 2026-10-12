#!/bin/bash
#
# Smoke test for the AAA path: FreeRADIUS -> LDAPS -> OpenLDAP.
#
# Starts openldap and freeradius as a separate compose project, seeded
# with the test accounts, and checks the reply for every combination of
# reply type and role. The running stack is left alone.
#
#   KEEP=1 tests/smoke.sh    leave the test stack up for a closer look

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"

cd "${ROOT_DIR}"

COMPOSE=(docker compose -p koitohan-test -f compose.yaml -f tests/compose.test.yaml)
SECRET='testing123'
WAIT_TRIES=40

function cleanup() {
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
  openldap/ldif/100-People.ldif \
  freeradius/config/mods-available/ldap_openldap \
  tests/ldif/250-TestAccounts.ldif
do
  if [ ! -e "${FILE}" ]; then
    echo "${FILE} is missing. Run 'make' first, then 'make test'."
    exit 1
  fi
done

trap cleanup EXIT

echo 'starting the test stack'
if ! "${COMPOSE[@]}" up -d openldap freeradius > /dev/null 2>&1; then
  echo 'failed to start the test stack'
  "${COMPOSE[@]}" up -d openldap freeradius
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

check_restart

echo
if [ ${FAILED} -ne 0 ]; then
  echo "${FAILED} of ${COUNT} checks failed"
  exit 1
fi
echo "all ${COUNT} checks passed"
