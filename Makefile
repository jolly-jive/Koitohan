ENV_FILE := .env

# A target that a failed recipe has written to is removed, so that a
# half-written file does not pass for an up-to-date one on the next run.
.DELETE_ON_ERROR:

.PHONY: all private_dirs certs ldap_dir freeradius_conf device_networks ssh_hostkeys logrotate_conf host_check test clean up down

all: private_dirs certs ldap_dir freeradius_conf device_networks ssh_hostkeys logrotate_conf

### directories of keys
# Closed to the other users of the Docker host. CA/freeradius_client.key
# has to be 0644 for the container, and this is what keeps it in.
PRIVATE_DIRS := CA openssh/hostkeys

private_dirs:
	chmod 700 $(PRIVATE_DIRS)

### keys and certs
CERT_STAMP := CA/.certs.stamp
CERT_FILES := CA/*.pem CA/*.crt CA/*.key CA/*.csr

certs: $(CERT_STAMP)

$(CERT_STAMP): $(ENV_FILE) scripts/create_certs.sh
	cd CA && ../scripts/create_certs.sh
	touch $(CERT_STAMP)

### LDAP OUs
LDAP_BASE_LDIFS := \
	openldap/ldif/100-People.ldif \
	openldap/ldif/200-Roles.ldif \
	openldap/ldif/400-PPolicy.ldif

ldap_dir: $(LDAP_BASE_LDIFS)

$(LDAP_BASE_LDIFS) &: $(ENV_FILE) scripts/generate_ldap_base.sh
	./scripts/generate_ldap_base.sh

### FreeRADIUS config
FREERADIUS_LDAP := freeradius/config/mods-available/ldap_openldap
FREERADIUS_CLIENTS := freeradius/config/clients.conf

freeradius_conf: $(FREERADIUS_LDAP) $(FREERADIUS_CLIENTS)

$(FREERADIUS_LDAP): $(ENV_FILE) scripts/generate_freeradius_ldap.sh
	./scripts/generate_freeradius_ldap.sh

$(FREERADIUS_CLIENTS):
	install -m 640 $(FREERADIUS_CLIENTS).sample $@

### networks of the devices
# syslog-ng limits the source by itself, in its own syntax. FreeRADIUS
# and tftpd-hpa take DEVICE_NETWORKS from compose.yaml.
DEVICE_NETWORKS_FILES := \
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

### state of the Docker host
# what make does not make: the steps done by hand with sudo
host_check:
	./bin/check_host.sh

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
# the last of the certificates, and one that earlier versions did not make
REPLICATION_CERT := CA/openldap_replication.crt

$(SYSLOG_HOSTS_DIR):
	mkdir -p $@

up: private_dirs freeradius_conf device_networks ssh_hostkeys | $(SYSLOG_HOSTS_DIR)
	@test -f $(REPLICATION_CERT) || { echo "$(REPLICATION_CERT) is missing. Run 'make' first."; exit 1; }
	docker compose up -d

down:
	docker compose down
