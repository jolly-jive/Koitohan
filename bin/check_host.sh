#!/bin/bash
#
# Checks the state of the Docker host that make does not make: the
# steps done by hand, mostly with sudo, in the quick start of the
# README and in docs/tftp.md, docs/logs.md and docs/ssh.md, and the
# sync of the host clock.
#
#   check_host.sh
#
# Runs on the Docker host, without sudo, and changes nothing. Prints a
# line for each item, OK, NG, WARN or SKIP, with what to do for an NG
# or a WARN. Exits with 1 when there is an NG.
#
# Where a directory is closed to this user (freeradius/log/radacct/),
# only the directory itself is looked at.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR%/*}"

cd "${ROOT_DIR}"

[[ $# -eq 0 ]] || { echo "usage: ${0##*/}" >&2; exit 2; }

# freerad in the FreeRADIUS image
FREERAD_UID=101
# in.tftpd, and PUID of syslog-ng in compose.yaml
TFTPD_UID=1000
SYSLOG_UID=1000
# the role admin in the OpenSSH container
ADMIN_GID=10001

FREERADIUS_LOG=freeradius/log
FIRMWARE_DIR=tftpd-hpa/tftpboot/firmware
CONFIGS_DIR=tftpd-hpa/tftpboot/configs
SYSLOG_HOSTS_DIR=syslog-ng/log/Hosts
LOGROTATE_CONF=logrotate/koitohan
LOGROTATE_INSTALLED=/etc/logrotate.d/koitohan

FAILED=0

function ok()   { echo "OK    $1"; }
function skip() { echo "SKIP  $1"; }
function warn() { echo "WARN  $1"; shift; printf '      %s\n' "$@"; }
function ng()   { echo "NG    $1"; shift; printf '      %s\n' "$@"; FAILED=1; }

# owner, group and mode of a directory for TFTP: in.tftpd writes, and
# the role admin reads and writes over SSH
function check_tftp_dir() {
  local DIR=${1} DOC=${2}
  local STATE

  STATE=$(stat -c '%u:%g %a' "${DIR}" 2> /dev/null)
  if [[ -z "${STATE}" ]]; then
    ng "${DIR}: missing" "See ${DOC}."
  elif [[ "${STATE}" == "${TFTPD_UID}:${ADMIN_GID} 2770" ]]; then
    ok "${DIR}: ${STATE}"
  else
    ng "${DIR}: ${STATE}, not ${TFTPD_UID}:${ADMIN_GID} 2770" \
      "sudo chown ${TFTPD_UID}:${ADMIN_GID} ${DIR}" \
      "sudo chmod 2770 ${DIR}" \
      "See ${DOC}."
  fi
}

### freeradius/log/
# FreeRADIUS writes the detail logs after it drops to uid 101. Without
# the chown, it rejects every login.
if [[ ! -d "${FREERADIUS_LOG}" ]]; then
  ng "${FREERADIUS_LOG}: missing" "mkdir ${FREERADIUS_LOG} && sudo chown -R ${FREERAD_UID}:${FREERAD_UID} ${FREERADIUS_LOG}"
else
  # -maxdepth 1: radacct/ is closed to this user
  NOT_OWNED=$(find "${FREERADIUS_LOG}" -maxdepth 1 ! -name .gitkeep \( ! -uid ${FREERAD_UID} -o ! -gid ${FREERAD_UID} \) 2> /dev/null)
  if [[ -z "${NOT_OWNED}" ]]; then
    ok "${FREERADIUS_LOG}: owned by ${FREERAD_UID}:${FREERAD_UID}"
  else
    ng "${FREERADIUS_LOG}: not owned by ${FREERAD_UID}:${FREERAD_UID}: ${NOT_OWNED//$'\n'/ }" \
      "sudo chown -R ${FREERAD_UID}:${FREERAD_UID} ${FREERADIUS_LOG}"
  fi
fi

### tftpd-hpa/tftpboot/
check_tftp_dir "${FIRMWARE_DIR}" 'the quick start in README.md'
check_tftp_dir "${CONFIGS_DIR}" 'docs/tftp.md'

# The image file bounds what uploads can use. Strongly recommended, not
# required, hence WARN.
CONFIGS_MOUNT=$(findmnt -n -o SOURCE,OPTIONS -M "${CONFIGS_DIR}" 2> /dev/null)
if [[ -z "${CONFIGS_MOUNT}" ]]; then
  warn "${CONFIGS_DIR}: nothing is mounted. Uploads have no space limit." \
    "See \"Limit the space uploads can use\" in docs/tftp.md."
else
  read -r SOURCE OPTIONS <<< "${CONFIGS_MOUNT}"
  MISSING_OPTIONS=()
  for OPTION in nodev nosuid noexec; do
    [[ ",${OPTIONS}," == *",${OPTION},"* ]] || MISSING_OPTIONS+=("${OPTION}")
  done
  if [[ "${SOURCE}" != /dev/loop* ]]; then
    warn "${CONFIGS_DIR}: ${SOURCE} is mounted, not an image file" \
      "See \"Limit the space uploads can use\" in docs/tftp.md."
  elif [[ ${#MISSING_OPTIONS[@]} -gt 0 ]]; then
    warn "${CONFIGS_DIR}: mounted without ${MISSING_OPTIONS[*]}" \
      "See \"Limit the space uploads can use\" in docs/tftp.md."
  else
    ok "${CONFIGS_DIR}: an image file is mounted (${SOURCE})"
  fi
fi

if [[ -n "${CONFIGS_MOUNT}" ]]; then
  if findmnt -n --fstab -M "${ROOT_DIR}/${CONFIGS_DIR}" > /dev/null 2>&1; then
    ok "/etc/fstab: has ${CONFIGS_DIR}"
  else
    warn "/etc/fstab: no line for ${CONFIGS_DIR}. The mount goes away when the host reboots." \
      "See \"Limit the space uploads can use\" in docs/tftp.md."
  fi
else
  skip "/etc/fstab: nothing is mounted on ${CONFIGS_DIR}"
fi

# A mount made after the stack started does not reach the containers
# until they restart.
if [[ -n "${CONFIGS_MOUNT}" ]]; then
  HOST_DEVICE=$(findmnt -n -o MAJ:MIN -M "${CONFIGS_DIR}")
  HOST_DEVICE=${HOST_DEVICE//[[:space:]]/}
  for SERVICE in tftpd-hpa openssh; do
    if [[ -z "$(docker compose ps -q --status running ${SERVICE} 2> /dev/null)" ]]; then
      skip "${SERVICE}: not running, so its view of /tftpboot/configs is not checked"
      continue
    fi
    MOUNTINFO=$(docker compose exec -T ${SERVICE} cat /proc/self/mountinfo 2> /dev/null)
    CONTAINER_DEVICE=$(awk '$5 == "/tftpboot/configs" { print $3 }' <<< "${MOUNTINFO}")
    if [[ "${CONTAINER_DEVICE}" == "${HOST_DEVICE}" ]]; then
      ok "${SERVICE}: sees the image file on /tftpboot/configs"
    else
      warn "${SERVICE}: does not see the image file on /tftpboot/configs" \
        "docker compose restart ${SERVICE}"
    fi
  done
else
  skip "containers: nothing is mounted on ${CONFIGS_DIR}"
fi

### logrotate
# logrotate skips a config that is not owned by root, or that the group
# or the others can write.
if [[ ! -f "${LOGROTATE_INSTALLED}" ]]; then
  ng "${LOGROTATE_INSTALLED}: missing" \
    "sudo install -m 644 -o root -g root ${LOGROTATE_CONF} ${LOGROTATE_INSTALLED}"
else
  STATE=$(stat -c '%u:%g %a' "${LOGROTATE_INSTALLED}")
  read -r OWNER MODE <<< "${STATE}"
  if [[ "${OWNER}" != 0:0 || $(( 8#${MODE} & 8#022 )) -ne 0 ]]; then
    ng "${LOGROTATE_INSTALLED}: ${STATE}. logrotate does not read it." \
      "sudo install -m 644 -o root -g root ${LOGROTATE_CONF} ${LOGROTATE_INSTALLED}"
  else
    ok "${LOGROTATE_INSTALLED}: ${STATE}"
  fi

  if [[ ! -f "${LOGROTATE_CONF}" ]]; then
    ng "${LOGROTATE_CONF}: missing, nothing to compare with" "make logrotate_conf"
  elif cmp -s "${LOGROTATE_CONF}" "${LOGROTATE_INSTALLED}"; then
    ok "${LOGROTATE_INSTALLED}: the same as ${LOGROTATE_CONF}"
  else
    ng "${LOGROTATE_INSTALLED}: differs from ${LOGROTATE_CONF}" \
      "sudo install -m 644 -o root -g root ${LOGROTATE_CONF} ${LOGROTATE_INSTALLED}"
  fi
fi

### syslog-ng/log/Hosts/
# make up creates it. Docker would create it owned by root, and
# syslog-ng could not write there.
if [[ ! -d "${SYSLOG_HOSTS_DIR}" ]]; then
  skip "${SYSLOG_HOSTS_DIR}: not there yet, make up creates it"
else
  OWNER=$(stat -c '%u' "${SYSLOG_HOSTS_DIR}")
  if [[ "${OWNER}" == "${SYSLOG_UID}" ]]; then
    ok "${SYSLOG_HOSTS_DIR}: owned by ${OWNER}"
  else
    ng "${SYSLOG_HOSTS_DIR}: owned by ${OWNER}, not ${SYSLOG_UID}" \
      "sudo chown ${SYSLOG_UID}:${SYSLOG_UID} ${SYSLOG_HOSTS_DIR}"
  fi
fi

### sources of the bind mounts
# Docker creates a missing source as an empty directory owned by root,
# also where a file belongs. configs/ is checked above: when nothing is
# mounted, it is meant to be owned by root.
SOURCES=$(docker compose config 2> /dev/null | sed -n 's|^ *source: \(/.*\)$|\1|p' | sort -u)
if [[ -z "${SOURCES}" ]]; then
  ng "bind mounts: docker compose config failed" "docker compose config"
else
  BAD_SOURCES=()
  while read -r SOURCE; do
    [[ "${SOURCE}" == "${ROOT_DIR}/${CONFIGS_DIR}" ]] && continue
    if [[ ! -e "${SOURCE}" ]]; then
      BAD_SOURCES+=("${SOURCE#${ROOT_DIR}/} (missing)")
    elif [[ -d "${SOURCE}" && $(stat -c '%u' "${SOURCE}") == 0 && -r "${SOURCE}" && -z "$(ls -A "${SOURCE}")" ]]; then
      BAD_SOURCES+=("${SOURCE#${ROOT_DIR}/} (an empty directory owned by root)")
    fi
  done <<< "${SOURCES}"
  if [[ ${#BAD_SOURCES[@]} -eq 0 ]]; then
    ok 'bind mounts: every source is there'
  else
    ng 'bind mounts: sources that make did not make' "${BAD_SOURCES[@]}" \
      'Remove an empty directory owned by root with sudo rmdir, then run make.'
  fi
fi

### the clock of the Docker host
# Every container shares this clock, and the NTP service serves it to
# the devices. NTPSynchronized is the kernel's flag, which turns off
# only hours after the last sync.
if ! TIME_STATE=$(timedatectl show -p NTP -p NTPSynchronized 2> /dev/null); then
  warn 'clock: timedatectl failed, so the sync with NTP is not checked' \
    'Make sure that an NTP client keeps the clock of this host in sync.'
elif [[ "${TIME_STATE}" == *NTPSynchronized=yes* ]]; then
  ok 'clock: synchronized with NTP'
elif [[ "${TIME_STATE}" == *NTP=yes* ]]; then
  ng 'clock: not synchronized, though the NTP client is on' \
    'timedatectl timesync-status' \
    'Check that this host reaches its NTP servers, then wait for the sync.'
else
  ng 'clock: not synchronized, and no NTP client is on' \
    'sudo timedatectl set-ntp true'
fi

### the memory controller of cgroup
# mem_limit of the OpenSSH container works only with it.
case $(docker info --format '{{.MemoryLimit}}' 2> /dev/null) in
  true)  ok 'cgroup: the memory controller is enabled' ;;
  false) warn 'cgroup: the memory controller is disabled. The memory limit of openssh does not work.' \
           'See docs/ssh.md.' ;;
  *)     ng 'cgroup: docker info failed' 'docker info' ;;
esac

exit ${FAILED}
