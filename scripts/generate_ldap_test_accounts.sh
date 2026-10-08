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

TESTACCOUNTS_LDIF="${OUT_DIR}/250-TestAccounts.ldif"
TESTACCOUNTROLES_LDIF="${OUT_DIR}/260-TestAccountRoles.ldif"

cat <<EOF > ${TESTACCOUNTS_LDIF}
dn: uid=admin01,ou=People,${LDAP_SUFFIX}
objectClass: inetOrgPerson
uid: admin01
cn: Admin01 TEST
sn: TEST
givenName: Admin
userPassword: $(slappasswd -s 'passadmin')

dn: uid=operator01,ou=People,${LDAP_SUFFIX}
objectClass: inetOrgPerson
uid: operator01
cn: Operator01 TEST
sn: TEST
givenName: Operator
userPassword: $(slappasswd -s 'passoperator')

dn: uid=readonly01,ou=People,${LDAP_SUFFIX}
objectClass: inetOrgPerson
uid: readonly01
cn: Readonly01 TEST
sn: TEST
givenName: Readonly
userPassword: $(slappasswd -s 'passreadonly')
EOF


cat <<EOF > ${TESTACCOUNTROLES_LDIF}
dn: cn=admin,ou=Roles,${LDAP_SUFFIX}
changetype: modify
add: uniqueMember
uniqueMember: uid=admin01,ou=People,${LDAP_SUFFIX}

dn: cn=operator,ou=Roles,${LDAP_SUFFIX}
changetype: modify
add: uniqueMember
uniqueMember: uid=operator01,ou=People,${LDAP_SUFFIX}

dn: cn=readonly,ou=Roles,${LDAP_SUFFIX}
changetype: modify
add: uniqueMember
uniqueMember: uid=readonly01,ou=People,${LDAP_SUFFIX}
EOF
