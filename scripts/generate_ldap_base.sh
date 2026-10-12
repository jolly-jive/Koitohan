#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"

source "${ROOT_DIR}/.env"

OUT_DIR="${ROOT_DIR}/openldap/ldif"

function domain2dn() {
  local DOMAIN=${1}

  echo ${DOMAIN} \
  | tr . '\n' \
  | awk '{print "dc="$1}' \
  | paste -s -d ','
}

LDAP_SUFFIX=$(domain2dn ${LDAP_DOMAIN})

PEOPLE_LDIF="${OUT_DIR}/100-People.ldif"
ROLES_LDIF="${OUT_DIR}/200-Roles.ldif"
SERVICE_ACCOUNTS_LDIF="${OUT_DIR}/300-ServiceAccounts.ldif"
PPOLICY_LDIF="${OUT_DIR}/400-PPolicy.ldif"
ACL_LDIF="${OUT_DIR}/900-ACL.ldif"

POLICIES_DN="ou=Policies,${LDAP_SUFFIX}"
SERVICE_ACCOUNTS_DN="ou=ServiceAccounts,${LDAP_SUFFIX}"

# an .env from before ppolicy does not have these, and an empty value
# would stop OpenLDAP in the middle of the seed
for NAME in PPOLICY_MIN_LENGTH PPOLICY_MAX_FAILURE PPOLICY_FAILURE_WINDOW PPOLICY_LOCKOUT_DURATION; do
  if [[ ! "${!NAME}" =~ ^[0-9]+$ ]]; then
    echo "${NAME} is not a number. Copy it from .env.sample to .env." >&2
    exit 1
  fi
done

# contains password hashes
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


cat <<EOF > ${SERVICE_ACCOUNTS_LDIF}
dn: ou=ServiceAccounts,${LDAP_SUFFIX}
objectClass: organizationalUnit
ou: ServiceAccounts

dn: uid=${FREERADIUS_SERVICE_ACCOUNT_NAME},ou=ServiceAccounts,${LDAP_SUFFIX}
objectClass: simpleSecurityObject
objectClass: account
uid: ${FREERADIUS_SERVICE_ACCOUNT_NAME}
userPassword: $(slappasswd -s "${FREERADIUS_SERVICE_ACCOUNT_PASSWORD}")

dn: uid=${OPENSSH_SERVICE_ACCOUNT_NAME},ou=ServiceAccounts,${LDAP_SUFFIX}
objectClass: simpleSecurityObject
objectClass: account
uid: ${OPENSSH_SERVICE_ACCOUNT_NAME}
userPassword: $(slappasswd -s "${OPENSSH_SERVICE_ACCOUNT_PASSWORD}")
EOF


# Goes in after every LDIF that carries a hashed password, as the overlay
# refuses those (pwdCheckQuality: 2). The order inside matters too: the
# policies need the module, and the accounts need the policies.
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

dn: cn=serviceaccounts,${POLICIES_DN}
changetype: add
objectClass: device
objectClass: pwdPolicy
cn: serviceaccounts
pwdAttribute: userPassword

dn: cn=serviceaccounts,${POLICIES_DN}
changetype: modify
replace: pwdLockout
pwdLockout: FALSE
EOF

# a locked service account would stop the logins of everybody
for NAME in "${FREERADIUS_SERVICE_ACCOUNT_NAME}" "${OPENSSH_SERVICE_ACCOUNT_NAME}"; do
  cat <<EOF >> ${PPOLICY_LDIF}

dn: uid=${NAME},${SERVICE_ACCOUNTS_DN}
changetype: modify
replace: pwdPolicySubentry
pwdPolicySubentry: cn=serviceaccounts,${POLICIES_DN}
EOF
done

cat <<EOF > ${ACL_LDIF}
dn: olcDatabase={1}mdb,cn=config
changetype: modify
replace: olcAccess
olcAccess: {0}to *
  by dn.exact=gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth manage
  by * break
olcAccess: {1}to attrs=userPassword,shadowLastChange
  by self write
  by dn="cn=admin,${LDAP_SUFFIX}" write
  by anonymous auth
  by * none
olcAccess: {2}to *
  by self read
  by dn="cn=admin,${LDAP_SUFFIX}" write
  by dn="cn=readonly,${LDAP_SUFFIX}" read
  by dn.subtree="ou=ServiceAccounts,${LDAP_SUFFIX}" read
  by * none
EOF
