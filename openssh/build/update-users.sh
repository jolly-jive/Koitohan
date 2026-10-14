#!/bin/sh
#
# Makes /etc/passwd and /etc/group again from ou=People of LDAP.
# Writes only the users that have posixAccount and belong to a role.
# On a failure the files stay as they were.
set -eu

RUN_DIR=/run/koitohan
CERT_DIR=/etc/koitohan/certs

LDAP_SUFFIX="dc=$(echo "${LDAP_DOMAIN}" | sed 's/\./,dc=/g')"

umask 022
WORK_DIR=$(mktemp -d "${RUN_DIR}/update-users.XXXXXX")
trap 'rm -rf "${WORK_DIR}"' EXIT

# a password in the arguments would show in ps to the users logged in
LDAPTLS_REQCERT=demand \
LDAPTLS_CACERT="${CERT_DIR}/ca.crt" \
LDAPTLS_CERT="${CERT_DIR}/client.crt" \
LDAPTLS_KEY="${CERT_DIR}/client.key" \
ldapsearch -x -LLL -o ldif-wrap=no \
  -H "${LDAP_URI}" \
  -D "uid=${SERVICE_ACCOUNT_NAME},ou=ServiceAccounts,${LDAP_SUFFIX}" \
  -y "${RUN_DIR}/bindpw" \
  -b "ou=People,${LDAP_SUFFIX}" -s one \
  '(&(objectClass=posixAccount)(memberOf=*))' uid uidNumber memberOf \
  > "${WORK_DIR}/people.ldif"

# the GIDs are fixed and must not change, as files keep them as numbers
awk -v roles_dn="ou=roles,$(echo "${LDAP_SUFFIX}" | tr '[:upper:]' '[:lower:]')" \
    -v passwd="${WORK_DIR}/passwd" -v group="${WORK_DIR}/group" '
function skip(why) {
  print "skipped " dn ": " why > "/dev/stderr"
}

# a user in more than one role gets the weakest of them, as from FreeRADIUS
function weakest() {
  if ("readonly" in roles) return "readonly"
  if ("operator" in roles) return "operator"
  if ("admin" in roles) return "admin"
  return ""
}

function flush(   role) {
  if (dn == "") return

  role = weakest()

  if (uid !~ /^[a-z_][a-z0-9_-]*$/ || length(uid) > 32)
    skip("uid is not usable as a login name")
  else if (uid in taken)
    skip("the name " uid " is already taken")
  else if (num !~ /^[0-9]+$/ || num + 0 < 10000 || num + 0 > 59999)
    skip("uidNumber is out of 10000-59999")
  else if (num + 0 in numbers)
    skip("uidNumber " num " is already taken")
  else if (role == "")
    skip("no role")
  else {
    printf "%s:x:%d:10000::/:/bin/sh\n", uid, num > passwd
    members[role] = members[role] (members[role] == "" ? "" : ",") uid
    taken[uid] = 1
    numbers[num + 0] = 1
    count++
  }

  dn = uid = num = ""
  split("", roles)
}

BEGIN {
  gid["admin"] = 10001
  gid["operator"] = 10002
  gid["readonly"] = 10003
}

# the accounts of the image come first, and keep their names
FILENAME != ARGV[ARGC - 1] {
  split($0, field, ":")
  taken[field[1]] = 1
  next
}

/^dn:/         { flush(); dn = $0; sub(/^dn::? /, "", dn) }
/^uid: /       { uid = substr($0, 6) }
/^uidNumber: / { num = substr($0, 12) }
/^memberOf: /  {
  value = tolower(substr($0, 11))
  for (role in gid) if (value == "cn=" role "," roles_dn) roles[role] = 1
}

END {
  flush()
  printf "" >> passwd
  print "koitohan:x:10000:" > group
  print "admin:x:10001:" members["admin"] > group
  print "operator:x:10002:" members["operator"] > group
  print "readonly:x:10003:" members["readonly"] > group
  print count + 0 " users"
}' /etc/passwd.base /etc/group.base "${WORK_DIR}/people.ldif"

cat /etc/group.base "${WORK_DIR}/group" > "${WORK_DIR}/group.new"
cat /etc/passwd.base "${WORK_DIR}/passwd" > "${WORK_DIR}/passwd.new"

# a rename, so the readers never see a file half written
mv "${WORK_DIR}/group.new" "${RUN_DIR}/group"
mv "${WORK_DIR}/passwd.new" "${RUN_DIR}/passwd"
