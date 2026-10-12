ENV_FILE := .env

.PHONY: all certs ldap_dir ldap_testaccounts freeradius_conf ssh_hostkeys test clean up down

all: certs ldap_dir freeradius_conf ssh_hostkeys

### keys and certs
CERT_STAMP := CA/.certs.stamp
CERT_FILES := CA/*.pem CA/*.crt CA/*.key CA/*.csr

certs: $(CERT_STAMP)

$(CERT_STAMP): $(ENV_FILE) scripts/create_certs.sh
	rm -f $(CERT_FILES)
	cd CA && ../scripts/create_certs.sh
	touch $(CERT_STAMP)

### LDAP OUs
LDAP_BASE_LDIFS := \
	openldap/ldif/100-People.ldif \
	openldap/ldif/200-Roles.ldif \
	openldap/ldif/300-ServiceAccounts.ldif \
	openldap/ldif/900-ACL.ldif

ldap_dir: $(LDAP_BASE_LDIFS)

$(LDAP_BASE_LDIFS) &: $(ENV_FILE) scripts/generate_ldap_base.sh
	./scripts/generate_ldap_base.sh

### test accounts
LDAP_TEST_LDIFS := \
	openldap/ldif/250-TestAccounts.ldif \
	openldap/ldif/260-TestAccountRoles.ldif

ldap_testaccounts: $(LDAP_TEST_LDIFS)

$(LDAP_TEST_LDIFS) &: $(ENV_FILE) scripts/generate_ldap_test_accounts.sh
	./scripts/generate_ldap_test_accounts.sh

### FreeRADIUS config
FREERADIUS_LDAP := freeradius/config/mods-available/ldap_openldap
FREERADIUS_CLIENTS := freeradius/config/clients.conf

freeradius_conf: $(FREERADIUS_LDAP) $(FREERADIUS_CLIENTS)

$(FREERADIUS_LDAP): $(ENV_FILE) scripts/generate_freeradius_ldap.sh
	./scripts/generate_freeradius_ldap.sh

$(FREERADIUS_CLIENTS):
	install -m 640 $(FREERADIUS_CLIENTS).sample $@

### sshd host keys
SSH_HOSTKEYS := \
	openssh/hostkeys/ssh_host_ed25519_key \
	openssh/hostkeys/ssh_host_rsa_key

ssh_hostkeys: $(SSH_HOSTKEYS)

# made once and kept, clean included: a new key makes every client warn
openssh/hostkeys/ssh_host_%_key:
	ssh-keygen -q -t $* -N '' -C koitohan -f $@

### smoke test
SMOKE_TEST_LDIFS := \
	tests/ldif/250-TestAccounts.ldif \
	tests/ldif/260-TestAccountRoles.ldif

# does not depend on all, so that a test never regenerates the certificates
test: $(SMOKE_TEST_LDIFS)
	./tests/smoke.sh

$(SMOKE_TEST_LDIFS) &: $(ENV_FILE) scripts/generate_ldap_test_accounts.sh
	./scripts/generate_ldap_test_accounts.sh tests/ldif

### clean 
clean:
	rm -f $(CERT_STAMP) $(CERT_FILES)
	rm -f $(LDAP_BASE_LDIFS) $(LDAP_TEST_LDIFS) $(SMOKE_TEST_LDIFS)
	rm -f $(FREERADIUS_LDAP)

### up and down
# Docker would create a missing source of a bind mount as root
SYSLOG_HOSTS_DIR := syslog-ng/log/Hosts
OPENSSH_CERT := CA/openssh_client.crt

$(SYSLOG_HOSTS_DIR):
	mkdir -p $@

up: freeradius_conf ssh_hostkeys | $(SYSLOG_HOSTS_DIR)
	@test -f $(OPENSSH_CERT) || { echo "$(OPENSSH_CERT) is missing. Run 'make' first."; exit 1; }
	docker compose up -d

down:
	docker compose down
