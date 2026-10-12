#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"

source "${ROOT_DIR}/.env"

OUT_DIR="${1:-${ROOT_DIR}/openldap/ldif}"

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

# contains password hashes
umask 077

cat <<EOF > ${TESTACCOUNTS_LDIF}
dn: uid=admin01,ou=People,${LDAP_SUFFIX}
objectClass: inetOrgPerson
objectClass: posixAccount
uid: admin01
uidNumber: 10000
gidNumber: 10000
homeDirectory: /home/admin01
loginShell: /bin/sh
cn: Admin01 TEST
sn: TEST
givenName: Admin
userPassword: $(slappasswd -s 'passadmin')

dn: uid=operator01,ou=People,${LDAP_SUFFIX}
objectClass: inetOrgPerson
objectClass: posixAccount
uid: operator01
uidNumber: 10001
gidNumber: 10000
homeDirectory: /home/operator01
loginShell: /bin/sh
cn: Operator01 TEST
sn: TEST
givenName: Operator
userPassword: $(slappasswd -s 'passoperator')

dn: uid=readonly01,ou=People,${LDAP_SUFFIX}
objectClass: inetOrgPerson
objectClass: posixAccount
uid: readonly01
uidNumber: 10002
gidNumber: 10000
homeDirectory: /home/readonly01
loginShell: /bin/sh
cn: Readonly01 TEST
sn: TEST
givenName: Readonly
userPassword: $(slappasswd -s 'passreadonly')

dn: uid=norole01,ou=People,${LDAP_SUFFIX}
objectClass: inetOrgPerson
objectClass: posixAccount
uid: norole01
uidNumber: 10003
gidNumber: 10000
homeDirectory: /home/norole01
loginShell: /bin/sh
cn: Norole01 TEST
sn: TEST
givenName: Norole
userPassword: $(slappasswd -s 'passnorole')
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
