#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR%/*}"

source "${ROOT_DIR}/.env"

# tests/smoke.sh keeps its own generated files apart
GENERATED_ROOT="${KOITOHAN_GENERATED_ROOT:-${ROOT_DIR}}"

OUT_DIR="${GENERATED_ROOT}/freeradius/config/mods-available"

function domain2dn() {
  local DOMAIN=${1}

  echo "dc=${DOMAIN//./,dc=}"
}

LDAP_SUFFIX=$(domain2dn ${LDAP_DOMAIN})

LDAP_MODULE="${OUT_DIR}/ldap_openldap"

PASSWORD_FILE="${GENERATED_ROOT}/secrets/freeradius_service_account_password"
if [[ ! -s "${PASSWORD_FILE}" ]]; then
  echo "${PASSWORD_FILE} is missing or empty. Run 'make secrets' first." >&2
  exit 1
fi
PASSWORD=$(< "${PASSWORD_FILE}")

# contains the bind password
umask 027

cat <<EOF > ${LDAP_MODULE}
ldap {
    server = "ldaps://${OPENLDAP_CONTAINER_NAME}"

    identity = "uid=${FREERADIUS_SERVICE_ACCOUNT_NAME},ou=ServiceAccounts,${LDAP_SUFFIX}"
    password = "${PASSWORD}"


    # user retrieve
    user {
        base_dn = "ou=People,${LDAP_SUFFIX}"
        filter = "(uid=%{User-Name})"
    }

    # group retrieve (not nesseary in case using memberOf operational attribute)
    #group {
    #    base_dn = "ou=Roles,${LDAP_SUFFIX}"
    #}

    # LDAP attribute → FreeRADIUS attribute
    update {
        #control.Password.With-Header += 'userPassword'
        # += takes every value. := would keep the first one only, and
        # authz_vendor_role has to see all the roles of the user.
        control.LDAP-Group += 'memberOf'
    }

    # TLS
    tls {
        ca_file = /etc/freeradius/certs/ca.crt
        certificate_file = /etc/freeradius/certs/client.crt
        private_key_file = /etc/freeradius/certs/client.key
    }

    # authentication method
    #set_auth = yes
    dereference = yes
    chase_referrals = yes

    # FreeRADIUS finds out that OpenLDAP closed a connection only when it
    # next uses it. With these, a request that meets such a connection, or
    # none at all, waits for a new one. Without them it fails at once and
    # the login is rejected: the first two logins after a restart of
    # OpenLDAP, and every login while OpenLDAP is down, where no reply is
    # what lets the devices turn to another server or to their local
    # accounts. pool is for the searches, bind_pool for the binds of the
    # users.
    pool {
        backlog_on_failed_conn = yes
    }
    bind_pool {
        backlog_on_failed_conn = yes
    }
}
EOF
