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
ACL_LDIF="${OUT_DIR}/900-ACL.ldif"

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
EOF


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
