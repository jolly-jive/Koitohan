#!/bin/bash
#
# Checks that the services of the running stack work, by using each of
# them from inside its container.
#
#   check_services.sh [-q]
#
# Runs on the Docker host, without sudo, and changes nothing. Prints a
# line for each item, OK, NG, WARN or SKIP, with what to do for an NG
# or a WARN. Exits with 1 when there is an NG.
#
# -q prints only the NG and the WARN lines, so cron mails the output
# only when something is wrong. Without it, a daily run tells that all
# is well, and when that mail stops coming, the Docker host itself is
# down. docs/monitoring.md has the crontab.
#
# The requests go to the loopback inside each container: from the
# Docker host, they would come from the gateway of the network, which
# DEVICE_NETWORKS may not take. RADIUS needs a client for 127.0.0.1 in
# clients.conf. Each run leaves a line of a request for a missing file
# in the log of tftpd-hpa.
#
# COMPOSE_PROJECT_NAME and COMPOSE_FILE select another stack, as
# tests/smoke.sh does.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR%/*}"

cd "${ROOT_DIR}"

QUIET=''
while getopts 'q' OPT; do
  case ${OPT} in
    q) QUIET=1 ;;
    *) echo "usage: ${0##*/} [-q]" >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
[[ $# -eq 0 ]] || { echo "usage: ${0##*/} [-q]" >&2; exit 2; }

# a WARN at this use of a filesystem, in percent
DISK_WARN_PERCENT=90
# a WARN when a certificate expires within this, in days
CERT_WARN_DAYS=30
# for each request into a container
TIMEOUT=20

# in.tftpd
TFTPD_UID=1000
# no such file in firmware/: the answer, an error, is all that is wanted
TFTP_PROBE_FILE=firmware/koitohan-service-check

FAILED=0

function ok()   { [[ -n "${QUIET}" ]] || echo "OK    $1"; }
function skip() { [[ -n "${QUIET}" ]] || echo "SKIP  $1"; }
function warn() { echo "WARN  $1"; shift; printf '      %s\n' "$@"; }
function ng()   { echo "NG    $1"; shift; printf '      %s\n' "$@"; FAILED=1; }

function in_container() {
  timeout ${TIMEOUT} docker compose exec -T "$@"
}

# where the container has DESTINATION mounted from, on the Docker host
function source_of() {
  docker inspect -f "{{range .Mounts}}{{if eq .Destination \"${2}\"}}{{.Source}}{{end}}{{end}}" "${1}" 2> /dev/null
}

# the use of the filesystem that holds a path, in percent, from the
# output of df -P
function use_percent() {
  local LINE
  LINE=$(tail -n 1 <<< "${1}")
  read -r _ _ _ _ PERCENT _ <<< "${LINE}"
  PERCENT=${PERCENT%\%}
  [[ "${PERCENT}" =~ ^[0-9]+$ ]] && echo "${PERCENT}"
}

### containers
# The services of the profiles in COMPOSE_PROFILES of .env are there
# too, so chrony is when ntp is on.
declare -A CONTAINER=()
if ! SERVICES=$(docker compose config --services 2> /dev/null) || [[ -z "${SERVICES}" ]]; then
  ng 'containers: docker compose config failed' 'docker compose config'
  exit 1
fi
for SERVICE in ${SERVICES}; do
  ID=$(docker compose ps -a -q "${SERVICE}" 2> /dev/null | head -n 1)
  if [[ -z "${ID}" ]]; then
    ng "${SERVICE}: no container" 'make up'
    continue
  fi
  read -r STATUS RESTARTS STARTED <<< \
    "$(docker inspect -f '{{.State.Status}} {{.RestartCount}} {{.State.StartedAt}}' "${ID}" 2> /dev/null)"
  if [[ "${STATUS}" == running ]]; then
    CONTAINER[${SERVICE}]=${ID}
    ok "${SERVICE}: running since $(date -d "${STARTED}" '+%F %T'), restarted ${RESTARTS} times"
  else
    ng "${SERVICE}: ${STATUS:-unknown}, restarted ${RESTARTS:-?} times" "docker compose logs ${SERVICE}"
  fi
done

function running() {
  [[ -n "${CONTAINER[${1}]:-}" ]]
}

### openldap
# The way of nslcd and koitohan-update-users: LDAPS, the client
# certificate and the service account of openssh.
if ! running openldap; then
  skip 'openldap: not running, not checked'
elif ! running openssh; then
  skip 'openldap: not checked, as it is checked from openssh, which is not running'
elif OUT=$(in_container openssh sh -c '
    LDAP_SUFFIX="dc=$(echo "${LDAP_DOMAIN}" | sed "s/\./,dc=/g")"
    LDAPTLS_REQCERT=demand \
    LDAPTLS_CACERT=/etc/koitohan/certs/ca.crt \
    LDAPTLS_CERT=/etc/koitohan/certs/client.crt \
    LDAPTLS_KEY=/etc/koitohan/certs/client.key \
    ldapsearch -x -LLL -o nettimeout=10 \
      -H "${LDAP_URI}" \
      -D "uid=${SERVICE_ACCOUNT_NAME},ou=ServiceAccounts,${LDAP_SUFFIX}" \
      -y /run/koitohan/bindpw \
      -b "${LDAP_SUFFIX}" -s base dn' < /dev/null 2>&1) && [[ "${OUT}" == dn:* ]]; then
  ok 'openldap: openssh binds over LDAPS and reads the suffix'
else
  ng 'openldap: openssh could not bind over LDAPS and read the suffix' \
    "${OUT//$'\n'/ }" \
    'docker compose logs openldap openssh'
fi

### freeradius
# Status-Server answers without going to LDAP, so no user is needed.
# The secret goes through stdin and a file, as arguments show in ps.
if ! running freeradius; then
  skip 'freeradius: not running, not checked'
else
  CLIENTS_CONF=$(source_of "${CONTAINER[freeradius]}" /etc/freeradius/clients.conf)
  # the secret of the first client that covers 127.0.0.1. A nested
  # section ends the client early, which is fine while ipaddr and
  # secret come first.
  SECRET=$(awk '
    function value(line) {
      sub(/^[^=]*=[ \t]*/, "", line)
      if (line ~ /^"/) {
        sub(/^"/, "", line)
        sub(/".*/, "", line)
      } else {
        sub(/[ \t#].*/, "", line)
      }
      return line
    }
    /^[ \t]*#/ { next }
    /^[ \t]*client[ \t]/ { inside = 1; ip = ""; secret = ""; next }
    inside && /^[ \t]*(ipaddr|ipv4addr)[ \t]*=/ { ip = value($0) }
    inside && /^[ \t]*secret[ \t]*=/ { secret = value($0) }
    inside && /^[ \t]*}/ {
      if ((ip == "127.0.0.1" || ip == "127.0.0.1/32" || ip == "127.0.0.0/8") && secret != "") {
        print secret
        exit
      }
      inside = 0
    }' "${CLIENTS_CONF}" 2> /dev/null)
  if [[ -z "${SECRET}" ]]; then
    warn 'freeradius: no client for 127.0.0.1 in clients.conf, so RADIUS is not checked' \
      "Add one to ${CLIENTS_CONF:-clients.conf}, as freeradius/config/clients.conf.sample has, then docker compose restart freeradius."
  elif OUT=$(in_container freeradius sh -c '
      F=$(mktemp) || exit 1
      cat > "${F}"
      echo "Message-Authenticator = 0x00" | radclient -S "${F}" -t 3 -r 2 127.0.0.1:1812 status
      RC=$?
      rm -f "${F}"
      exit ${RC}' <<< "${SECRET}" 2>&1); then
    ok 'freeradius: answers Status-Server'
  else
    ng 'freeradius: no answer to Status-Server' \
      "${OUT//$'\n'/ }" \
      "Check the secret of the client for 127.0.0.1 in ${CLIENTS_CONF}." \
      'docker compose logs freeradius'
  fi
fi

### syslog-ng
if ! running syslog-ng; then
  skip 'syslog-ng: not running, not checked'
elif OUT=$(in_container syslog-ng syslog-ng-ctl stats --control=/config/syslog-ng.ctl < /dev/null 2>&1); then
  ok 'syslog-ng: answers on its control socket'
else
  ng 'syslog-ng: no answer on its control socket' \
    "${OUT//$'\n'/ }" \
    'docker compose logs syslog-ng'
fi

# The logs are on the Docker host, wherever this stack has them.
if running syslog-ng; then
  LOG_DIR=$(source_of "${CONTAINER[syslog-ng]}" /var/log)
  PERCENT=$(use_percent "$(df -P "${LOG_DIR}" 2> /dev/null)")
  if [[ -z "${PERCENT}" ]]; then
    ng "logs: df failed on ${LOG_DIR:-the log directory}" "df -P ${LOG_DIR}"
  elif (( PERCENT >= DISK_WARN_PERCENT )); then
    warn "logs: the filesystem of ${LOG_DIR} is ${PERCENT}% full" 'See docs/logs.md.'
  else
    ok "logs: the filesystem of ${LOG_DIR} is ${PERCENT}% full"
  fi
else
  skip 'logs: syslog-ng is not running, so the space is not checked'
fi

### tftpd-hpa
# A request for a missing file: the error proves that in.tftpd answers,
# and nothing is sent. tftp exits with 0 on the error, and crashes when
# nothing answers, so only the message tells.
if ! running tftpd-hpa; then
  skip 'tftpd-hpa: not running, not checked'
else
  OUT=$(in_container tftpd-hpa sh -c "printf 'rexmt 1\ntimeout 5\nget ${TFTP_PROBE_FILE} /dev/null\n' | tftp 127.0.0.1" < /dev/null 2>&1)
  if [[ "${OUT}" == *'Error code 1: File not found'* ]]; then
    ok 'tftpd-hpa: answers a request'
  else
    ng 'tftpd-hpa: no answer to a request' \
      "${OUT//$'\n'/ }" \
      'docker compose logs tftpd-hpa'
  fi

  # The directory under the image file is owned by root, so it shows
  # when the image is not mounted, or was mounted after tftpd-hpa
  # started.
  OWNER=$(in_container tftpd-hpa stat -c '%u' /tftpboot/configs < /dev/null 2> /dev/null)
  if [[ "${OWNER}" == "${TFTPD_UID}" ]]; then
    ok "configs/: owned by ${TFTPD_UID}, in.tftpd can write"
  else
    ng "configs/: owned by ${OWNER:-unknown}, not ${TFTPD_UID}. Uploads fail." \
      'When it is the image file of docs/tftp.md, mount it, then docker compose restart tftpd-hpa openssh.' \
      'make host_check'
  fi

  PERCENT=$(use_percent "$(in_container tftpd-hpa df -P /tftpboot/configs < /dev/null 2> /dev/null)")
  if [[ -z "${PERCENT}" ]]; then
    ng 'configs/: df failed' 'docker compose exec tftpd-hpa df -P /tftpboot/configs'
  elif (( PERCENT >= DISK_WARN_PERCENT )); then
    warn "configs/: the filesystem is ${PERCENT}% full" 'See docs/tftp.md.'
  else
    ok "configs/: the filesystem is ${PERCENT}% full"
  fi
fi

### openssh
if ! running openssh; then
  skip 'openssh: not running, not checked'
elif OUT=$(in_container openssh sh -c 'nc -w 5 127.0.0.1 22 < /dev/null | head -c 8' < /dev/null 2>&1) \
     && [[ "${OUT}" == SSH-2.0-* ]]; then
  ok 'openssh: sshd answers'
else
  ng 'openssh: sshd does not answer' \
    "${OUT//$'\n'/ }" \
    'docker compose logs openssh'
fi

### chrony
# It stops serving when the clock of the host is out of sync, and then
# says that it is not synchronised.
if [[ " ${SERVICES//$'\n'/ } " != *' chrony '* ]]; then
  skip 'chrony: the profile ntp is off'
elif ! running chrony; then
  skip 'chrony: not running, not checked'
else
  OUT=$(in_container chrony chronyc -n tracking < /dev/null 2>&1)
  LEAP=$(sed -n 's/^Leap status *: //p' <<< "${OUT}")
  if [[ "${LEAP}" == Normal ]]; then
    ok 'chrony: serves the clock of the host'
  elif [[ -n "${LEAP}" ]]; then
    ng "chrony: not serving (${LEAP}). The clock of the host is out of sync." \
      'timedatectl timesync-status' \
      'make host_check'
  else
    ng 'chrony: chronyc tracking failed' \
      "${OUT//$'\n'/ }" \
      'docker compose logs chrony'
  fi
fi

### certificates
# The services check one another with these. When one expires, LDAPS
# fails, and every login with it.
CERTS=(CA/default-ca.pem CA/*.crt)
EXPIRING=()
for CERT in "${CERTS[@]}"; do
  if [[ ! -r "${CERT}" ]]; then
    EXPIRING+=("${CERT} (not readable)")
  elif ! openssl x509 -noout -checkend $(( CERT_WARN_DAYS * 86400 )) -in "${CERT}" > /dev/null 2>&1; then
    EXPIRING+=("${CERT} ($(openssl x509 -noout -enddate -in "${CERT}" 2> /dev/null | sed 's/^notAfter=//'))")
  fi
done
if [[ ${#EXPIRING[@]} -eq 0 ]]; then
  ok "certificates: none expires within ${CERT_WARN_DAYS} days"
else
  warn "certificates: expire within ${CERT_WARN_DAYS} days" "${EXPIRING[@]}" \
    'make certs, then make down && make up'
fi

exit ${FAILED}
