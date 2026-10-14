ENV_FILE := .env

# A target that a failed recipe has written to is removed, so that a
# half-written file does not pass for an up-to-date one on the next run.
.DELETE_ON_ERROR:

.PHONY: all private_dirs certs secrets ldap_dir freeradius_conf device_networks ssh_hostkeys logrotate_conf test clean up down

all: private_dirs certs secrets ldap_dir freeradius_conf device_networks ssh_hostkeys logrotate_conf

### directories of keys and passwords
# Closed to the other users of the Docker host. CA/freeradius_client.key
# has to be 0644 for the container, and this is what keeps it in.
PRIVATE_DIRS := CA secrets openssh/hostkeys

private_dirs:
	chmod 700 $(PRIVATE_DIRS)

### keys and certs
CERT_STAMP := CA/.certs.stamp
CERT_FILES := CA/*.pem CA/*.crt CA/*.key CA/*.csr

certs: $(CERT_STAMP)

$(CERT_STAMP): $(ENV_FILE) scripts/create_certs.sh
	cd CA && ../scripts/create_certs.sh
	touch $(CERT_STAMP)

### passwords of the service accounts
SECRETS := \
	secrets/freeradius_service_account_password \
	secrets/openssh_service_account_password

### passwords of the administrators of OpenLDAP
LDAP_ADMIN_SECRETS := \
	secrets/ldap_admin_password \
	secrets/ldap_config_password

secrets: $(SECRETS) $(LDAP_ADMIN_SECRETS)

# made once and kept, clean included: the directory knows no other
secrets/%_service_account_password:
	./scripts/generate_service_account_password.sh $*

# made once and kept, clean included: the containers that run hold these
secrets/ldap_%_password:
	./scripts/generate_ldap_admin_password.sh $*

### LDAP OUs
LDAP_BASE_LDIFS := \
	openldap/ldif/100-People.ldif \
	openldap/ldif/200-Roles.ldif \
	openldap/ldif/300-ServiceAccounts.ldif \
	openldap/ldif/400-PPolicy.ldif \
	openldap/ldif/900-ACL.ldif

ldap_dir: $(LDAP_BASE_LDIFS)

$(LDAP_BASE_LDIFS) &: $(ENV_FILE) $(SECRETS) scripts/generate_ldap_base.sh
	./scripts/generate_ldap_base.sh

### FreeRADIUS config
FREERADIUS_LDAP := freeradius/config/mods-available/ldap_openldap
FREERADIUS_CLIENTS := freeradius/config/clients.conf

freeradius_conf: $(FREERADIUS_LDAP) $(FREERADIUS_CLIENTS)

$(FREERADIUS_LDAP): $(ENV_FILE) secrets/freeradius_service_account_password scripts/generate_freeradius_ldap.sh
	./scripts/generate_freeradius_ldap.sh

$(FREERADIUS_CLIENTS):
	install -m 640 $(FREERADIUS_CLIENTS).sample $@

### networks of the devices
# FreeRADIUS and syslog-ng limit the source by themselves, each in its
# own syntax. tftpd-hpa takes DEVICE_NETWORKS from compose.yaml.
DEVICE_NETWORKS_FILES := \
	freeradius/config/device_networks \
	syslog-ng/config/device_networks.conf

device_networks: $(DEVICE_NETWORKS_FILES)

$(DEVICE_NETWORKS_FILES) &: $(ENV_FILE) scripts/generate_device_networks.sh
	./scripts/generate_device_networks.sh

### sshd host keys
SSH_HOSTKEYS := \
	openssh/hostkeys/ssh_host_ed25519_key \
	openssh/hostkeys/ssh_host_rsa_key

ssh_hostkeys: $(SSH_HOSTKEYS)

# made once and kept, clean included: a new key makes every client warn
openssh/hostkeys/ssh_host_%_key:
	ssh-keygen -q -t $* -N '' -C koitohan -f $@

### logrotate config
# installed by hand, with sudo: logrotate runs on the Docker host
LOGROTATE_CONF := logrotate/koitohan

logrotate_conf: $(LOGROTATE_CONF)

$(LOGROTATE_CONF): $(ENV_FILE) scripts/generate_logrotate.sh
	./scripts/generate_logrotate.sh

### smoke test
# does not depend on all, so that a test never regenerates the certificates
test:
	./tests/smoke.sh

### clean 
clean:
	rm -f $(CERT_STAMP) $(CERT_FILES)
	rm -f $(LDAP_BASE_LDIFS)
	rm -f $(FREERADIUS_LDAP)
	rm -f $(DEVICE_NETWORKS_FILES)
	rm -f $(LOGROTATE_CONF)

### up and down
# Docker would create a missing source of a bind mount as root
SYSLOG_HOSTS_DIR := syslog-ng/log/Hosts
OPENSSH_CERT := CA/openssh_client.crt

$(SYSLOG_HOSTS_DIR):
	mkdir -p $@

up: private_dirs secrets freeradius_conf device_networks ssh_hostkeys | $(SYSLOG_HOSTS_DIR)
	@test -f $(OPENSSH_CERT) || { echo "$(OPENSSH_CERT) is missing. Run 'make' first."; exit 1; }
	docker compose up -d

down:
	docker compose down
