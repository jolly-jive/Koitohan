#!/bin/bash
#
# Writes the networks of the devices (DEVICE_NETWORKS in .env) in the
# syntax of the two servers that limit the source by themselves:
#
#   freeradius/config/device_networks        "allow" of the listener
#   syslog-ng/config/device_networks.conf    the filter f_device_networks
#
# tftpd-hpa takes the same variable from compose.yaml and filters the
# packets in its entrypoint.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"

# the environment wins over .env, as it does for docker compose
FROM_ENVIRONMENT="${DEVICE_NETWORKS}"
source "${ROOT_DIR}/.env"
DEVICE_NETWORKS="${FROM_ENVIRONMENT:-${DEVICE_NETWORKS}}"

# tests/smoke.sh keeps its own generated files apart
GENERATED_ROOT="${KOITOHAN_GENERATED_ROOT:-${ROOT_DIR}}"

FREERADIUS_NETWORKS="${GENERATED_ROOT}/freeradius/config/device_networks"
SYSLOG_NETWORKS="${GENERATED_ROOT}/syslog-ng/config/device_networks.conf"

read -r -a NETWORKS <<< "${DEVICE_NETWORKS}"
if [ ${#NETWORKS[@]} -eq 0 ]; then
  echo "DEVICE_NETWORKS is empty. Set it in .env (see .env.sample)." >&2
  exit 1
fi
for NETWORK in "${NETWORKS[@]}"; do
  if [[ ! "${NETWORK}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$ ]]; then
    echo "DEVICE_NETWORKS has to be IPv4 addresses or prefixes separated by spaces: ${NETWORK}" >&2
    exit 1
  fi
done

# Both files are written in place. A container that mounts the single
# file would keep seeing the old one if it were replaced.
{
  echo "# generated from DEVICE_NETWORKS in .env by scripts/generate_device_networks.sh"
  for NETWORK in "${NETWORKS[@]}"; do
    echo "allow = ${NETWORK}"
  done
} > "${FREERADIUS_NETWORKS}"

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
