# <img src="docs/images/koitohan.svg" alt="Koitohan icon" width="48" align="absmiddle"> Koitohan

A little and kawaii network backend server.

[日本語](README.ja.md)

Koitohan is a Docker Compose stack that gives network devices a login backend, a log collector and a file server. It is built for a Raspberry Pi 5 and small or lab networks.

- **OpenLDAP** holds the users and their roles.
- **FreeRADIUS** authenticates device logins against LDAP and returns the privilege attributes each vendor expects.
- **syslog-ng** collects syslog from the devices, one directory per host.
- **tftpd-hpa** distributes firmware to the devices and receives backups of their configurations.
- **OpenSSH** gives the users a shell to work in. They use it to read and fetch logs, to put and get the TFTP files, and to change their passwords.
- **chrony** serves the clock of the Docker host to the devices over NTP. It is optional.

You manage users and roles (`admin`, `operator`, `readonly`) in one place. Koitohan translates a role into what each device understands, such as `shell:priv-lvl=15` for Cisco or `Aruba-Priv-Admin-User = 15` for ArubaOS-CX.

## About the name

*Koitohan* (こいとはん) is a word from the speech of Osaka. In Osaka merchant families, a daughter of the house is called *itohan*. The word is said to come from *itoshii* ("dear") or *itokenai* ("young and innocent"), and it means a daughter her parents cherish. When a family has two or more daughters, the youngest is *ko-itohan*, the "little itohan".

Full-featured management servers for large networks already exist. Koitohan does not aim to be one of those fat servers. It aims to be small enough to run on a Raspberry Pi, to offer management functions a little better than the bare minimum, and still to take availability into account. It is a small and dear server, so it is named Koitohan.

Redundancy for availability is not implemented yet.

## Status

Koitohan is at the verification stage. It is not hardened for production use.

| Function                         | Component                                       | Status    |
| -------------------------------- | ----------------------------------------------- | --------- |
| Directory                        | OpenLDAP 2.6 (built here from Alpine)           | Working   |
| Authentication and authorization | FreeRADIUS 4.x (`cayenneryo/freeradius-server`) | Working   |
| Log collection                   | syslog-ng (`linuxserver/syslog-ng`)             | Working   |
| File distribution                | tftpd-hpa (built here from Alpine)              | Working   |
| Workspace for the users          | OpenSSH (built here from Alpine)                | Working   |
| Time (NTP), optional             | chrony (built here from Alpine)                 | Working   |
| Log rotation                     | logrotate on the Docker host                    | Working   |
| DHCP and DNS                     | Kea, BIND9                                      | Undecided |

FreeRADIUS 4.x is a development version. Koitohan uses it ahead of its official release. The image is built from the development branch in [freeradius-server-image](https://github.com/jolly-jive/freeradius-server-image). Koitohan builds its own image on one build of it, pinned in `freeradius/build/Dockerfile`, and adds the packet filter that limits the sources of the requests.

## Requirements

- Docker with the Compose plugin
- GNU Make 4.3 or later
- `openssl`
- `slappasswd` (in the `slapd` package on Debian and Raspberry Pi OS)
- `ssh-keygen`. `make test` also uses `ssh` from OpenSSH 8.4 or later and a `curl` that supports TFTP.
- `logrotate`, which rotates the logs
- The clock of the Docker host kept in sync with NTP (`systemd-timesyncd` does this by default on Raspberry Pi OS). The containers use the host clock, and so do the times in the logs.

## Quick start

```sh
git clone https://github.com/jolly-jive/Koitohan.git koitohan
cd koitohan

cp .env.sample .env    # then edit .env
make                   # generate certificates, passwords, LDIF files, the FreeRADIUS LDAP config, the sshd host keys and the logrotate config
$EDITOR freeradius/config/clients.conf
sudo chown -R 101:101 freeradius/log
sudo chown 1000:10001 tftpd-hpa/tftpboot/firmware
sudo chmod 2770 tftpd-hpa/tftpboot/firmware
sudo install -m 644 -o root -g root logrotate/koitohan /etc/logrotate.d/koitohan
make host_check        # check the steps above
make up
```

There are no passwords in `.env`. `make` generates the passwords of the OpenLDAP administrators and of the service accounts of FreeRADIUS and OpenSSH, and puts them in `secrets/` (see [OpenLDAP administrator passwords](docs/configuration.md#openldap-administrator-passwords) and [Service account passwords](docs/configuration.md#service-account-passwords)).

`make` creates `freeradius/config/clients.conf` from `clients.conf.sample`. Replace the sample clients with your own devices before you run `make up`.

FreeRADIUS runs as uid 101 and writes its logs to `freeradius/log/`. Without the `chown`, it cannot record a login there and rejects every request.

The `install` hands the configuration of the log rotation to logrotate on the Docker host (see [Rotation](docs/logs.md#rotation)).

The `chown` and `chmod` on `firmware/` open the directory to the users with the role `admin`, and to no other user who logs in over SSH (see the [user guide](docs/user-guide.md#handing-out-firmware-and-taking-out-configurations-admin-only)). The steps in [TFTP](docs/tftp.md) do the same for `configs/`.

`make host_check` checks the state of the Docker host that `make` does not make: the steps above done with `sudo`, the image file of [TFTP](docs/tftp.md), the memory controller that [SSH](docs/ssh.md) needs, and the sync of the clock. It runs without `sudo`, changes nothing, and prints `OK`, `NG`, `WARN` or `SKIP` for each item, with what to do for an `NG` or a `WARN`. It fails when there is an `NG`. A `WARN` is a recommended step that was left out. Run it again whenever you have changed the host or regenerated the logrotate config.

Use `make up` instead of calling `docker compose up` directly on a fresh checkout. It makes sure the generated files exist before Docker mounts them.

Once it is up, check with `bin/check_services.sh` that each service works. A service of Koitohan that stops is easy to miss, so we strongly recommend running it from cron (see [Checking the services](docs/monitoring.md)).

## Ports

| Port             | Service               |
| ---------------- | --------------------- |
| 2222/tcp         | SSH (the number is `OPENSSH_PORT`) |
| 1812/udp         | RADIUS authentication |
| 514/udp, 514/tcp | syslog                |
| 69/udp           | TFTP                  |
| 636/tcp          | LDAPS                 |
| 123/udp          | NTP (only with `COMPOSE_PROFILES='ntp'`) |

Every port is published on IPv4 only. IPv6 is not supported.

RADIUS accounting (1813/udp) is not provided. The logins are recorded in the detail logs of FreeRADIUS, and the logouts and the operations in the syslog of the devices.

## Commands

```sh
make                    # private_dirs + certs + secrets + ldap_dir + freeradius_conf + device_networks + ssh_hostkeys + logrotate_conf
make private_dirs       # close the directories of keys and passwords to everyone but their owner
make certs              # private CA, server and client certificates
make secrets            # passwords of the service accounts and of the OpenLDAP administrators (kept if they already exist)
make ldap_dir           # LDIF files for OUs, roles, the service accounts, the password policy and ACLs
make freeradius_conf    # FreeRADIUS LDAP module config and clients.conf
make device_networks    # the device networks, in the config of syslog-ng
make ssh_hostkeys       # sshd host keys (kept if they already exist)
make logrotate_conf     # config for logrotate on the Docker host
make host_check         # check the state of the Docker host that make does not make
make test               # smoke test
make up                 # start the stack
make down               # stop the stack
make clean              # delete generated certificates, LDIF files and config
bin/manage_users.sh     # add and delete users, change a role, set a new password, unlock
bin/change_service_account_password.sh   # change the password of a service account
bin/change_ldap_admin_password.sh        # change the passwords of the OpenLDAP administrators
bin/backup.sh           # take a backup of the running stack
bin/restore_ldap.sh     # load the directory of a backup into an empty OpenLDAP
bin/check_services.sh   # check that each service of the running stack works
```

Check the FreeRADIUS configuration without starting the stack:

```sh
docker compose run --rm --no-deps freeradius radiusd -XC
```

Check authentication and authorization end to end:

```sh
make test
```

`make test` starts every container as a separate project (`koitohan-test`), adds test users with `bin/manage_users.sh`, authenticates as them, and compares the reply attributes for every combination of device type and role. It also checks that FreeRADIUS makes a detail log again after the rotation has moved it away. For RADIUS, syslog, TFTP and NTP, it checks that traffic from the networks in `DEVICE_NETWORKS` arrives and that traffic from elsewhere does not. It also checks that a TFTP transfer is recorded in the file, and that the NTP server answers that it is not synchronized once the host clock goes out of sync. It then logs in over SSH as a user of each role and checks the permissions on the directories, the reading of a compressed log and a password change. After that it runs each operation of `bin/manage_users.sh` and checks the password policy (the minimum length, the lock and the unlock) and the change of the passwords of the service accounts and of the OpenLDAP administrators. Then it restarts the OpenLDAP container and checks that it comes up again. It checks that `bin/check_services.sh` reports nothing wrong while all is well, and reports a wrong owner of `configs/`, a stopped syslog-ng and an NTP server that stopped serving. At the end it takes a backup with `bin/backup.sh`, makes OpenLDAP again with empty data, restores the backup with `bin/restore_ldap.sh` and checks that the users and the files in `configs/` are back. It publishes no ports, keeps no data and generates passwords of its own (`tests/generated/`), so it does not affect a running stack. Run `make` beforehand. To look into a failed check, keep the test stack up with `KEEP=1 tests/smoke.sh`.

The OpenLDAP, FreeRADIUS, tftpd-hpa, OpenSSH and chrony images are built automatically by the first `make up`. After you change `openldap/build/`, `freeradius/build/`, `tftpd-hpa/build/`, `openssh/build/` or `chrony/build/`, rebuild them before you start the stack.

```sh
docker compose build openldap freeradius tftpd-hpa openssh chrony
make up
```

`make clean` keeps the sshd host keys (`openssh/hostkeys/`). A new host key makes the client of every user show a warning. It keeps the passwords in `secrets/` as well (see [Service account passwords](docs/configuration.md#service-account-passwords) and [OpenLDAP administrator passwords](docs/configuration.md#openldap-administrator-passwords)).

Follow the logs of a service:

```sh
docker compose logs -f freeradius
```

## Known limitations

- Changes to users and roles made without `bin/manage_users.sh` do not reach SSH logins until you run `koitohan-update-users`.
- A logged-in user can get around the password check of `passwd`. The check is there to prevent weak passwords set by carelessness. Even then, the minimum length that OpenLDAP checks by itself (`PPOLICY_MIN_LENGTH`) holds.
- Anyone who can reach the login prompt of a network device or the SSH port can lock a user whose name they know, by sending wrong passwords. A lock ends by itself when its time is over (see [Password policy](docs/configuration.md#password-policy)).
- By default, a user logged in over SSH reaches nothing but OpenLDAP from the OpenSSH container. Names are still looked up through the DNS of Docker, outside names as well. With `OPENSSH_EGRESS='any'` the user can connect to the Docker host and to outside networks (see [Connections out of the container](docs/ssh.md#connections-out-of-the-container)).
- When OpenLDAP restarts while FreeRADIUS keeps running, for example after `docker compose restart openldap`, FreeRADIUS rejects the first few logins that follow (two, in our tests), and logins work after that. FreeRADIUS notices that its connections to OpenLDAP are broken only when it uses them, and fails the login that found out. To avoid the rejected logins, restart FreeRADIUS right after OpenLDAP with `docker compose restart freeradius`.

## Security notes

These files contain private keys, shared secrets or passwords. Git ignores all of them. Keep them out of backups and copies that others can read. The archive that `bin/backup.sh` writes holds most of them, unencrypted (see [Backup and restore](docs/backup.md#keep-the-archive-safe)).

- `CA/`
- `freeradius/config/clients.conf`
- `freeradius/config/mods-available/ldap_openldap`
- `openldap/ldif/*.ldif`
- `openssh/hostkeys/`
- `secrets/`
- `tftpd-hpa/tftpboot/configs/` (device configurations, which can contain password hashes and shared secrets)

`make` and `make up` close `CA/`, `secrets/` and `openssh/hostkeys/` to everyone but their owner (0700). `CA/freeradius_client.key` has the mode 0644, because FreeRADIUS reads it as uid 101 inside the container. The mode of the directory is what keeps it from the other users of the Docker host, so do not loosen it.

The private key of the CA is deleted once the certificates are issued. `make certs` makes a new CA every time, so the key is not needed again.

The device logs under `syslog-ng/log/Hosts/` are readable by every user on the Docker host, so that the users who log in over SSH can read them.

RADIUS logins use PAP, so the shared secret of each client is what protects the user's password on the wire. Use a long random secret for each device.

TFTP has neither authentication nor encryption. Anyone who can reach 69/udp and knows a file name can download files from `firmware/` and `configs/`, and can overwrite files in `configs/`. That includes the configurations you have backed up. Publish 69/udp only to a trusted management network.

## Documentation

For the users, who log in to the devices:

- [User guide](docs/user-guide.md): what Koitohan does for them, roles, reading the logs, firmware and configurations, passwords

For the Koitohan administrators:

- [Configuration](docs/configuration.md): `.env`, device networks, serving the time, RADIUS clients, users and roles, passwords
- [TFTP](docs/tftp.md): handing out firmware and backing up configs, limits on uploads
- [The OpenSSH container](docs/ssh.md): what the container for the users is for, password rules, sources
- [Logs](docs/logs.md): where the logs are and how they rotate
- [Backup and restore](docs/backup.md): what a backup holds, running it every day, restoring onto a new host
- [Checking the services](docs/monitoring.md): checking that the services work, and doing it on a schedule (recommended)
- [Device configuration examples](docs/devices/README.md): settings on the network devices, sent by contributors
- [Basic design](docs/basic-design.md) (Japanese)

## Contributing

Configuration examples for network devices are especially welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Copyright 2026 Cayenne Ryo

Licensed under the [Apache License 2.0](LICENSE). See also [NOTICE](NOTICE).

## Ice cream

If Koitohan saves you some trouble, buy me an ice cream. 🍦

*This is a request, not a license term. Koitohan is under Apache-2.0, with no extra conditions.*
