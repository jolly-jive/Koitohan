#!/bin/bash
#
# Takes a backup of the running stack into one archive.
#
#   backup.sh [-k COUNT] DIRECTORY
#
# Runs on the Docker host, and needs openldap and tftpd-hpa running.
# Writes DIRECTORY/koitohan-<host>-<date>-<time>.tar.gz, mode 0600:
#
#   .env, freeradius/config/clients.conf, secrets/, openssh/hostkeys/
#       the files themselves, under the paths they have in the repository
#   ldap/config.ldif, ldap/data.ldif
#       slapcat of cn=config and of the directory, which is consistent
#       while slapd runs
#   tftp-configs.tar
#       tftpd-hpa/tftpboot/configs/, taken inside the container, which
#       can read every file and keeps the owners as numbers
#   koitohan-backup.txt
#       when, where and from which commit
#
# Neither the logs nor firmware/ are taken, and nothing that make makes
# again. The archive has no directory entries, so that unpacking it into
# the repository changes the mode of no directory there. It is not
# encrypted: it holds the passwords and the keys in clear text.
#
# -k COUNT deletes the older archives of this host in DIRECTORY, once
# the new one is written, and keeps COUNT of them.
#
# COMPOSE_PROJECT_NAME and COMPOSE_FILE select another stack, and
# KOITOHAN_GENERATED_ROOT the generated files of that stack, as
# tests/smoke.sh does.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR%/*}"

source "${ROOT_DIR}/.env"

function die() {
  echo "$*" >&2
  exit 1
}

function usage() {
  echo "usage: ${0##*/} [-k COUNT] DIRECTORY" >&2
  exit 2
}

KEEP=''
while getopts 'k:' OPT; do
  case ${OPT} in
    k) KEEP=${OPTARG} ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))
[[ $# -eq 1 ]] || usage
[[ -z "${KEEP}" || "${KEEP}" =~ ^[1-9][0-9]*$ ]] || die "-k ${KEEP}: not a count"

OUT_DIR=$(cd "${1}" && pwd) || die "${1}: no such directory"

KOITOHAN_GENERATED_ROOT=$(cd "${KOITOHAN_GENERATED_ROOT:-${ROOT_DIR}}" && pwd) \
  || die 'KOITOHAN_GENERATED_ROOT: no such directory'

cd "${ROOT_DIR}"

umask 077

CONF_DIR=/etc/openldap/slapd.d
SECRETS=(
  freeradius_service_account_password
  openssh_service_account_password
  ldap_admin_password
  ldap_config_password
)

function container_of() {
  docker compose ps -a -q "${1}" 2> /dev/null
}

# where the container has DESTINATION mounted from, on the Docker host
function source_of() {
  docker inspect -f "{{range .Mounts}}{{if eq .Destination \"${2}\"}}{{.Source}}{{end}}{{end}}" "${1}" 2> /dev/null
}

for SERVICE in openldap freeradius tftpd-hpa openssh; do
  [[ -n "$(container_of ${SERVICE})" ]] || die "${SERVICE}: no such container in this stack. Start the stack first."
done
for SERVICE in openldap tftpd-hpa; do
  [[ -n "$(docker compose ps --status running -q ${SERVICE} 2> /dev/null)" ]] \
    || die "${SERVICE} is not running. Start the stack first."
done

# The passwords have to be the ones of this stack, or the backup would
# not agree with its own directory.
docker inspect -f '{{range .Mounts}}{{println .Source}}{{end}}' "$(container_of openldap)" \
| grep -q -x -F -- "${KOITOHAN_GENERATED_ROOT}/secrets/ldap_admin_password" \
  || die "openldap does not read ${KOITOHAN_GENERATED_ROOT}/secrets/ldap_admin_password. For another stack, set KOITOHAN_GENERATED_ROOT."

# the files the containers read, wherever this stack has them
CLIENTS_CONF=$(source_of "$(container_of freeradius)" /etc/freeradius/clients.conf)
HOSTKEYS_DIR=$(source_of "$(container_of openssh)" /etc/koitohan/hostkeys)
[[ -f "${CLIENTS_CONF}" ]] || die 'could not find the clients.conf that freeradius reads'
[[ -d "${HOSTKEYS_DIR}" ]] || die 'could not find the host keys that openssh reads'

STAGE=$(mktemp -d "${OUT_DIR}/.koitohan-backup.XXXXXX") || die "could not write to ${OUT_DIR}"
trap 'rm -rf "${STAGE}"' EXIT
mkdir -p "${STAGE}"/{freeradius/config,secrets,openssh/hostkeys,ldap}

cp -p .env "${STAGE}/.env" || die 'could not copy .env'
cp -p "${CLIENTS_CONF}" "${STAGE}/freeradius/config/clients.conf" || die "could not copy ${CLIENTS_CONF}"
for SECRET in "${SECRETS[@]}"; do
  cp -p "${KOITOHAN_GENERATED_ROOT}/secrets/${SECRET}" "${STAGE}/secrets/" \
    || die "could not copy ${KOITOHAN_GENERATED_ROOT}/secrets/${SECRET}"
done
HOSTKEYS=("${HOSTKEYS_DIR}"/ssh_host_*)
[[ -f "${HOSTKEYS[0]}" ]] || die "no host keys in ${HOSTKEYS_DIR}"
cp -p "${HOSTKEYS[@]}" "${STAGE}/openssh/hostkeys/" || die "could not copy the host keys in ${HOSTKEYS_DIR}"

for N in 0 1; do
  case ${N} in
    0) LDIF="${STAGE}/ldap/config.ldif" ;;
    1) LDIF="${STAGE}/ldap/data.ldif" ;;
  esac
  docker compose exec -T openldap slapcat -F "${CONF_DIR}" -n ${N} -o ldif-wrap=no < /dev/null > "${LDIF}" \
    || die "could not dump database ${N} of openldap"
  [[ "$(head -c 4 "${LDIF}")" == 'dn: ' ]] || die "the dump of database ${N} of openldap is empty"
done

# lost+found is there when configs/ is the image file of docs/tftp.md
docker compose exec -T tftpd-hpa tar -c -f - --exclude=configs/lost+found -C /tftpboot configs \
  < /dev/null > "${STAGE}/tftp-configs.tar" \
  || die 'could not take the files in configs/ from tftpd-hpa'

COMMIT=$(git rev-parse HEAD 2> /dev/null) || COMMIT='unknown'
[[ -z "$(git status --porcelain --untracked-files=no 2> /dev/null)" ]] || COMMIT="${COMMIT} (with changes)"
HOST=${HOSTNAME%%.*}
STAMP=$(date '+%Y%m%d-%H%M%S')
cat > "${STAGE}/koitohan-backup.txt" <<EOF
date:   $(date '+%Y-%m-%d %H:%M:%S %z')
host:   ${HOST}
commit: ${COMMIT}
EOF

# files only: a directory entry would set the mode of that directory in
# the repository it is unpacked into
ARCHIVE="${OUT_DIR}/koitohan-${HOST}-${STAMP}.tar.gz"
( cd "${STAGE}" && find . -type f -printf '%P\n' | sort ) \
| tar -c -z -f "${ARCHIVE}.part" -C "${STAGE}" --no-recursion -T - \
  || { rm -f "${ARCHIVE}.part"; die "could not write ${ARCHIVE}"; }
mv "${ARCHIVE}.part" "${ARCHIVE}" || die "could not write ${ARCHIVE}"
echo "wrote ${ARCHIVE}"

if [[ -n "${KEEP}" ]]; then
  # the names sort by time, the oldest first
  OLD=("${OUT_DIR}/koitohan-${HOST}-"[0-9]*-[0-9]*.tar.gz)
  for (( I = 0; I < ${#OLD[@]} - KEEP; I++ )); do
    rm -f -- "${OLD[I]}" && echo "deleted ${OLD[I]}"
  done
fi
