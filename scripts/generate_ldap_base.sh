#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR%/*}"

source "${ROOT_DIR}/.env"

# tests/smoke.sh keeps its own generated files apart
GENERATED_ROOT="${KOITOHAN_GENERATED_ROOT:-${ROOT_DIR}}"

OUT_DIR="${GENERATED_ROOT}/openldap/ldif"

function domain2dn() {
  local DOMAIN=${1}

  echo "dc=${DOMAIN//./,dc=}"
}

LDAP_SUFFIX=$(domain2dn ${LDAP_DOMAIN})

PEOPLE_LDIF="${OUT_DIR}/100-People.ldif"
ROLES_LDIF="${OUT_DIR}/200-Roles.ldif"
PPOLICY_LDIF="${OUT_DIR}/400-PPolicy.ldif"

POLICIES_DN="ou=Policies,${LDAP_SUFFIX}"

# an .env from before ppolicy does not have these, and an empty value
# would stop OpenLDAP in the middle of the seed
for NAME in PPOLICY_MIN_LENGTH PPOLICY_MAX_FAILURE PPOLICY_FAILURE_WINDOW PPOLICY_LOCKOUT_DURATION; do
  if [[ ! "${!NAME:-}" =~ ^[0-9]+$ ]]; then
    echo "${NAME} is not a number. Copy it from .env.sample to .env." >&2
    exit 1
  fi
done

# Made by earlier versions. The seed loads every file here, so these
# would bring back the service accounts and an access control that the
# entrypoint now writes itself.
rm -f "${OUT_DIR}/300-ServiceAccounts.ldif" "${OUT_DIR}/900-ACL.ldif"

# read by the root of the OpenLDAP container only
umask 077

cat <<EOF > ${PEOPLE_LDIF}
dn: ou=People,${LDAP_SUFFIX}
objectClass: organizationalUnit
ou: People
EOF


cat <<EOF > ${ROLES_LDIF}
dn: ou=Roles,${LDAP_SUFFIX}
objectClass: organizationalUnit
ou: Roles

dn: cn=admin,ou=Roles,${LDAP_SUFFIX}
objectClass: groupOfUniqueNames
cn: admin
uniqueMember: 

dn: cn=operator,ou=Roles,${LDAP_SUFFIX}
objectClass: groupOfUniqueNames
cn: operator
uniqueMember: 

dn: cn=readonly,ou=Roles,${LDAP_SUFFIX}
objectClass: groupOfUniqueNames
cn: readonly
uniqueMember: 
EOF


# The overlay refuses hashed passwords (pwdCheckQuality: 2), so an LDIF
# that carries one would have to go in before this. None does now. The
# order inside matters: the policy needs the module.
#
# The values are set by a replace, apart from the entries. That way the
# file can be applied again to a running directory (ldapmodify -c), and
# the values follow .env.
cat <<EOF > ${PPOLICY_LDIF}
dn: cn=module{0},cn=config
changetype: modify
add: olcModuleLoad
olcModuleLoad: ppolicy

dn: olcOverlay=ppolicy,olcDatabase={1}mdb,cn=config
changetype: add
objectClass: olcOverlayConfig
objectClass: olcPPolicyConfig
olcOverlay: ppolicy
olcPPolicyDefault: cn=default,${POLICIES_DN}
olcPPolicyHashCleartext: TRUE
olcPPolicyUseLockout: FALSE

dn: ${POLICIES_DN}
changetype: add
objectClass: organizationalUnit
ou: Policies

dn: cn=default,${POLICIES_DN}
changetype: add
objectClass: device
objectClass: pwdPolicy
cn: default
pwdAttribute: userPassword

dn: cn=default,${POLICIES_DN}
changetype: modify
replace: pwdMinLength
pwdMinLength: ${PPOLICY_MIN_LENGTH}
-
replace: pwdCheckQuality
pwdCheckQuality: 2
-
replace: pwdLockout
pwdLockout: TRUE
-
replace: pwdMaxFailure
pwdMaxFailure: ${PPOLICY_MAX_FAILURE}
-
replace: pwdFailureCountInterval
pwdFailureCountInterval: ${PPOLICY_FAILURE_WINDOW}
-
replace: pwdLockoutDuration
pwdLockoutDuration: ${PPOLICY_LOCKOUT_DURATION}
EOF
