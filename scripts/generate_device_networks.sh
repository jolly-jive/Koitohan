#!/bin/bash
#
# Writes the networks of the devices (DEVICE_NETWORKS in .env) in the
# syntax of syslog-ng, which limits the source by itself:
#
#   syslog-ng/config/device_networks.conf    the filter f_device_networks
#
# FreeRADIUS and tftpd-hpa take the same variable from compose.yaml and
# filter the packets in their entrypoints.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR%/*}"

# the environment wins over .env, as it does for docker compose
FROM_ENVIRONMENT="${DEVICE_NETWORKS:-}"
source "${ROOT_DIR}/.env"
DEVICE_NETWORKS="${FROM_ENVIRONMENT:-${DEVICE_NETWORKS}}"

# tests/smoke.sh keeps its own generated files apart
GENERATED_ROOT="${KOITOHAN_GENERATED_ROOT:-${ROOT_DIR}}"

SYSLOG_NETWORKS="${GENERATED_ROOT}/syslog-ng/config/device_networks.conf"

# An IPv4 address or prefix, in numbers that nft takes as well in the
# other containers. syslog-ng takes anything that looks like one, such
# as 10.0.0.0/33, and would run with a filter that nobody meant.
function valid_network() {
  local OCTET
  local -a OCTETS

  [[ "${1}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$ ]] || return 1
  if [[ "${1}" == */* ]] && (( 10#${1#*/} > 32 )); then
    return 1
  fi
  IFS=. read -r -a OCTETS <<< "${1%/*}"
  for OCTET in "${OCTETS[@]}"; do
    (( 10#${OCTET} <= 255 )) || return 1
  done
}

read -r -a NETWORKS <<< "${DEVICE_NETWORKS}"
if [[ ${#NETWORKS[@]} -eq 0 ]]; then
  echo "DEVICE_NETWORKS is empty. Set it in .env (see .env.sample)." >&2
  exit 1
fi
for NETWORK in "${NETWORKS[@]}"; do
  if ! valid_network "${NETWORK}"; then
    echo "DEVICE_NETWORKS has to be IPv4 addresses or prefixes separated by spaces: ${NETWORK}" >&2
    exit 1
  fi
done

# The file is written in place. A container that mounts the single file
# would keep seeing the old one if it were replaced.
{
  echo "# generated from DEVICE_NETWORKS in .env by scripts/generate_device_networks.sh"
  echo "filter f_device_networks {"
  SEPARATOR='    '
  for NETWORK in "${NETWORKS[@]}"; do
    echo "${SEPARATOR}netmask(\"${NETWORK}\")"
    SEPARATOR='    or '
  done
  echo "    ;"
  echo "};"
} > "${SYSLOG_NETWORKS}"
