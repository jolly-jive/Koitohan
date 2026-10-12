# Koitohan

A little and kawaii network backend server.

[日本語](README.ja.md)

Koitohan is a Docker Compose stack that gives network devices a login backend, a log collector and a file server. It is built for a Raspberry Pi 5 and small or lab networks.

- **OpenLDAP** holds the users and their roles.
- **FreeRADIUS** authenticates device logins against LDAP and returns the privilege attributes each vendor expects.
- **syslog-ng** collects syslog from the devices, one directory per host.
- **tftpd-hpa** distributes firmware to the devices and receives backups of their configurations.
- **OpenSSH** gives the users a shell to work in. They use it to read and fetch logs, to put and get the TFTP files, and to change their passwords.

You manage users and roles (`admin`, `operator`, `readonly`) in one place. Koitohan translates a role into what each device understands, such as `shell:priv-lvl=15` for Cisco or `Aruba-Priv-Admin-User = 15` for ArubaOS-CX.

## About the name

*Koitohan* (こいとはん) is a word from the speech of Osaka. In Osaka merchant families, a daughter of the house is called *itohan*. The word is said to come from *itoshii* ("dear") or *itokenai* ("young and innocent"), and it means a daughter her parents cherish. When a family has two or more daughters, the youngest is *ko-itohan*, the "little itohan".

Full-featured management servers for large networks already exist. Koitohan does not aim to be one of those fat servers. It aims to be small enough to run on a Raspberry Pi, to offer management functions a little better than the bare minimum, and still to take availability into account. It is a small and dear server, so it is named Koitohan.

Redundancy for availability is not implemented yet.

## Status

Koitohan is at the verification stage. It is not hardened for production use.

| Function                         | Component                                       | Status    |
| -------------------------------- | ----------------------------------------------- | --------- |
| Directory                        | OpenLDAP (`osixia/openldap`)                    | Working   |
| Authentication and authorization | FreeRADIUS 4.x (`cayenneryo/freeradius-server`) | Working   |
| Log collection                   | syslog-ng (`linuxserver/syslog-ng`)             | Working   |
| File distribution                | tftpd-hpa (built here from Alpine)              | Working   |
| Workspace for the users          | OpenSSH (built here from Alpine)                | Working   |
| Log rotation                     | logrotate on the Docker host                    | Planned   |
| DHCP and DNS                     | Kea, BIND9                                      | Undecided |

FreeRADIUS 4.x is a development version. Koitohan uses it ahead of its official release. The image is built from the development branch in [freeradius-server-image](https://github.com/jolly-jive/freeradius-server-image), and `compose.yaml` pins it to one build.

## Requirements

- Docker with the Compose plugin
- GNU Make 4.3 or later
- `openssl`
- `slappasswd` (in the `slapd` package on Debian and Raspberry Pi OS)
- `ssh-keygen`. `make test` also uses `ssh` from OpenSSH 8.4 or later.

## Quick start

```sh
git clone <repository-url> koitohan
cd koitohan

cp .env.sample .env    # then edit .env
make                   # generate certificates, LDIF files, the FreeRADIUS LDAP config and the sshd host keys
$EDITOR freeradius/config/clients.conf
sudo chown -R 101:101 freeradius/log
sudo chown 1000:10001 tftpd-hpa/tftpboot/firmware
sudo chmod 2770 tftpd-hpa/tftpboot/firmware
make up
```

Change every password in `.env` before you run `make`. The values in `.env.sample` are public.

`make` creates `freeradius/config/clients.conf` from `clients.conf.sample`. Replace the sample clients with your own devices before you run `make up`.

FreeRADIUS runs as uid 101 and writes its logs to `freeradius/log/`. Without the `chown`, it cannot record a login there and rejects every request.

The `chown` and `chmod` on `firmware/` open the directory to the users with the role `admin`, and to no other user who logs in over SSH (see [Working over SSH](#working-over-ssh)). The steps in [TFTP](#tftp) do the same for `configs/`.

Use `make up` instead of calling `docker compose up` directly on a fresh checkout. It makes sure the generated files exist before Docker mounts them.

## Configuration

### `.env`

`.env` is the single source of configuration. The scripts and `compose.yaml` all read it.

| Variable                              | Meaning                                                                        |
| ------------------------------------- | ------------------------------------------------------------------------------ |
| `LDAP_DOMAIN`                         | Domain of the directory. `example.com` becomes the suffix `dc=example,dc=com`. |
| `LDAP_ORGANISATION`                   | Organization name stored in the directory.                                     |
| `LDAP_ADMIN_PASSWORD`                 | Password of the LDAP data administrator (`cn=admin,<suffix>`).                 |
| `LDAP_CONFIG_PASSWORD`                | Password of the LDAP configuration administrator.                              |
| `FREERADIUS_SERVICE_ACCOUNT_NAME`     | Account FreeRADIUS uses to search the directory.                               |
| `FREERADIUS_SERVICE_ACCOUNT_PASSWORD` | Password of that account.                                                      |
| `OPENLDAP_CONTAINER_NAME`             | Container name of OpenLDAP.                                                    |
| `FREERADIUS_CONTAINER_NAME`           | Container name of FreeRADIUS.                                                  |
| `SYSLOG_CONTAINER_NAME`               | Container name of syslog-ng.                                                   |
| `TFTP_CONTAINER_NAME`                 | Container name of tftpd-hpa.                                                   |
| `TFTP_UPLOAD_MAX_BYTES`               | Size limit, in bytes, for one file uploaded over TFTP. See [TFTP](#tftp).      |
| `OPENSSH_CONTAINER_NAME`              | Container name of OpenSSH.                                                     |
| `OPENSSH_HOSTNAME`                    | Host name of the OpenSSH container. It appears in the prompt of the shell.     |
| `OPENSSH_PORT`                        | Port of the Docker host that publishes SSH. Keep it apart from the host's own sshd. |
| `OPENSSH_SUBNET`                      | Subnet of the Docker network that connects only OpenSSH and OpenLDAP, in CIDR notation. |
| `OPENSSH_SERVICE_ACCOUNT_NAME`        | Account the OpenSSH container uses to search the directory.                    |
| `OPENSSH_SERVICE_ACCOUNT_PASSWORD`    | Password of that account.                                                      |
| `PASSWDQC_MIN`                        | Minimum lengths of the passwords `passwd` accepts. See [Changing a password](#changing-a-password). |
| `DOCKER_SUBNET`                       | Subnet of the Docker network that connects the containers, in CIDR notation.   |
| `TZ`                                  | Time zone of every container, as a tz database name such as `Asia/Tokyo`.      |

The container names of OpenLDAP, FreeRADIUS and OpenSSH are also the host names in their certificates. If you change them, regenerate the certificates with `make clean && make`.

Set `DOCKER_SUBNET` and `OPENSSH_SUBNET` to ranges that do not overlap the networks your devices are on, any network the host reaches, or each other. Apply a change with `make down && make up`.

Keep `DOCKER_SUBNET` inside a private address range. FreeRADIUS accepts requests only from private address ranges and loopback (see [RADIUS clients](#radius-clients)), so with any other range, RADIUS requests sent from the Docker host itself may be rejected.

`OPENSSH_HOSTNAME` is the name that tells the users which server they are logged in to. The prompt looks like `alice@koitohan:/logs/Hosts$`. When you run more than one Koitohan, give each a different name. Apply a change with `make up`.

`TZ` sets the time zone of the timestamps in the logs each container writes. Apply a change with `make up`.

### RADIUS clients

Describe each network device in `freeradius/config/clients.conf`. The `nas_type` of a client selects the reply attributes for that device.

```
client core-switch {
	ipaddr = 192.168.1.1
	secret = changeme
	nas_type = cisco
}
```

`nas_type` is matched case-insensitively by prefix.

| `nas_type`                | Attribute                    | admin                 | operator           | readonly           |
| ------------------------- | ---------------------------- | --------------------- | ------------------ | ------------------ |
| `cisco`                   | `Cisco-AVPair`               | `shell:priv-lvl=15`   | `shell:priv-lvl=7` | `shell:priv-lvl=1` |
| `aruba-cx`                | `Aruba-Priv-Admin-User`      | 15                    | 7                  | 1                  |
| `aruba-ap`                | none                         | accept                | reject             | reject             |
| `fortinet`, `fortigate`   | `Fortinet-Group-Name`        | `super_admin`         | `readonly`         | `readonly`         |
| `juniper`                 | `Juniper-Local-User-Name`    | `superuser`           | `operator`         | `read-only`        |
| `palo-alto`               | `PaloAlto-Admin-Role`        | `superuser`           | `readonly`         | `readonly`         |
| `service-type`, `rfc2865` | `Service-Type`               | `Administrative-User` | `NAS-Prompt-User`  | `Login-User`       |
| `ietf-mpl`, `allied`      | `Management-Privilege-Level` | 15                    | 7                  | 1                  |
| `nothing`, `no`, `none`   | none                         | accept                | accept             | accept             |

Any other value falls back to `Management-Privilege-Level`.

The values for Fortinet, Juniper and Palo Alto are names of profiles or users on the device. Define matching ones on the device.

FreeRADIUS accepts requests only from private address ranges (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`) and loopback.

### Users and roles

Users live under `ou=People`. Roles are `groupOfUniqueNames` entries under `ou=Roles`. Add a user to a role by adding the user's DN to the role's `uniqueMember`. A user who belongs to no role is rejected on every device.

Koitohan does not include a tool for managing users.

A user who is to log in over SSH also needs `posixAccount` (see [Working over SSH](#working-over-ssh)).

- Give each user a different `uidNumber` from 10000 to 59999. Never reuse a number, even after you delete its user. The files a user leaves behind keep the number as their owner.
- Set `gidNumber` to 10000.

An example that adds it to an existing user:

```sh
docker compose exec -T openldap ldapmodify -Q -Y EXTERNAL -H ldapi:/// <<'EOF'
dn: uid=alice,ou=People,dc=example,dc=com
changetype: modify
add: objectClass
objectClass: posixAccount
-
add: uidNumber
uidNumber: 10000
-
add: gidNumber
gidNumber: 10000
-
add: homeDirectory
homeDirectory: /home/alice
-
add: loginShell
loginShell: /bin/sh
EOF
```

For a quick trial, `make ldap_testaccounts` generates four test users: `admin01`, `operator01` and `readonly01`, one per role, and `norole01`, which belongs to no role. Their passwords are written in `scripts/generate_ldap_test_accounts.sh`. Run it before the first `make up`, and do not use it outside a lab.

### Changing the directory seed

OpenLDAP loads the generated LDIF files only on its first start with an empty database. To apply changes to `.env` or the LDIF files afterwards, you have to delete `openldap/data/` and `openldap/config/` and start again. This deletes every user and role in the directory.

## TFTP

tftpd-hpa serves `tftpd-hpa/tftpboot/` as the TFTP root. It holds two directories with different roles.

| Directory                      | Purpose                                           | What devices can do |
| ------------------------------ | ------------------------------------------------- | ------------------- |
| `tftpd-hpa/tftpboot/firmware/` | Files you distribute to devices, such as firmware | Download only       |
| `tftpd-hpa/tftpboot/configs/`  | Configuration backups that devices upload         | Download and upload |

Put the files to distribute into `firmware/` on the Docker host. Devices refer to files as `firmware/<file>` and `configs/<file>`. An example on Cisco IOS:

```
copy running-config tftp://<host>/configs/core-switch.cfg
copy tftp://<host>/firmware/image.bin flash:
```

### Limit the space uploads can use (strongly recommended)

TFTP has no authentication. Anyone who can reach 69/udp can write to `configs/`. With no protection, uploaded data uses the disk of the Docker host. When that disk fills up, log collection, the LDAP database and the host itself stop working.

To prevent this, it is strongly recommended to create a fixed-size image file and mount it on `configs/` before the first `make up`. The total size and the number of uploaded files are then bounded by the image, and a full image affects nothing but `configs/`.

Run the following in the repository directory. This example creates a 256 MB image.

```sh
sudo fallocate -l 256M tftpd-hpa/configs.img
sudo mkfs.ext4 -m 0 tftpd-hpa/configs.img
sudo mkdir -p tftpd-hpa/tftpboot/configs
echo "$PWD/tftpd-hpa/configs.img $PWD/tftpd-hpa/tftpboot/configs ext4 loop,noatime,nodev,nosuid,noexec 0 2" | sudo tee -a /etc/fstab
sudo systemctl daemon-reload
sudo mount "$PWD/tftpd-hpa/tftpboot/configs"
sudo chown 1000:10001 tftpd-hpa/tftpboot/configs
sudo chmod 2770 tftpd-hpa/tftpboot/configs
```

Always run `chown` and `chmod` after `mount`. The owner, 1000, is tftpd-hpa. The group, 10001, is the users with the role `admin` who log in over SSH. The commands change the directory inside the image, and the directory underneath stays owned by root. That way, when the image is not mounted, uploads simply fail instead of landing on the host's disk.

If you mount the image after the stack has started, apply it to the container with `docker compose restart tftpd-hpa`.

If you start the stack without these steps, Docker creates `configs/` owned by root, and uploads fail. You can allow them with the `chown` and `chmod` above, but that leaves uploads with no space limit and is not recommended.

### Limit for a single file

`TFTP_UPLOAD_MAX_BYTES` in `.env` is the size limit, in bytes, for one uploaded file. The value in `.env.sample` is 16 MB. Apply a change with `make up`.

- This does not limit the total. It cannot stop someone from uploading many small files, so use it together with the image file above.
- An upload over the limit does not get an error. It times out on the device. A file cut off at the limit stays in `configs/`, and you have to delete it by hand. The server log does not record that the upload was cut off.
- The limit does not apply to downloads from `firmware/`.

### Things to know

- Transfer files in binary mode. Some clients, such as the `tftp` command on Linux, default to text (netascii) mode.
- The server replies from a UDP port other than 69. If a transfer from a PC fails, check that the firewall on the PC is not blocking those replies.
- `firmware/` sits directly on the disk of the Docker host. Check the free space before you put large firmware images there.
- `docker compose logs tftpd-hpa` shows the transfers, with the address of the requester and the file name.

## Working over SSH

Users log in to the OpenSSH container over SSH, with the same user name and password they use on the network devices. The port is `OPENSSH_PORT` in `.env`, 2222 in `.env.sample`. Public key authentication is not supported yet.

```sh
ssh -p 2222 alice@<host>

# pick one kind of message out of the logs of every device
ssh -p 2222 alice@<host> 'grep -h LINK-3 /logs/Hosts/*/*.log' > link.txt

# put a firmware image in place (role admin only)
scp -P 2222 image.bin alice@<host>:/tftpboot/firmware/
```

| Path in the container | Content                             | admin          | operator       | readonly       |
| --------------------- | ----------------------------------- | -------------- | -------------- | -------------- |
| `/logs/Hosts/`        | Syslog from each device             | read           | read           | read           |
| `/tftpboot/firmware/` | Files distributed to devices        | read and write | none           | none           |
| `/tftpboot/configs/`  | Configurations uploaded by devices  | read and write | none           | none           |
| `/tmp/`               | Scratch space (32 MB)               | read and write | read and write | read and write |

- Only users who have `posixAccount` and belong to a role can log in (see [Users and roles](#users-and-roles)).
- There are no home directories. With `scp` and `sftp`, give the path on the container as an absolute path.
- Users can write only where the table says so. The contents of `/tmp/` are lost when the container is recreated.
- A device can download firmware placed by a user with the role `admin` only if the file is readable by others. Fix a file placed with mode 0600 with `chmod 644`.
- A user with the role `admin` can read, copy and delete the configurations uploaded by devices, but cannot edit them in place.
- Port forwarding is turned off.
- After repeated authentication failures from one address, sshd refuses connections from that address for a while. This is the default behavior of `PerSourcePenalties` in OpenSSH.

### Changing a password

Run `passwd` in the shell. The new password also applies to logins on the network devices.

passwdqc checks the new password. `PASSWDQC_MIN` in `.env` sets the minimum length for each number of character classes (upper case, lower case, digits and others). The value in `.env.sample`, `12,10,10,8,8`, means the following.

| Character classes used | Minimum length |
| ---------------------- | -------------- |
| 3 or more              | 8              |
| 2                      | 10             |
| 1                      | 12             |

An upper case letter at the beginning and a digit at the end do not count as classes. `Password1`, for example, counts as one class. Apply a change with `make up`.

### Applying changes to users and roles

The OpenSSH container reads the directory when it starts and builds the list of users who can log in. Rebuild the list after you add or delete a user or change a role.

```sh
docker compose exec openssh koitohan-update-users
```

A change of role does not reach the sessions that are already logged in. To apply it at once, rebuild the list and then close the sessions of that user. `<uidNumber>` is the `uidNumber` of the user.

```sh
docker compose exec openssh pkill -KILL -u <uidNumber>
```

### Enabling the memory limit (optional)

The OpenSSH container has limits on the number of processes, memory and CPU. The memory limit works only when the memory controller of cgroup is enabled on the Docker host. Raspberry Pi OS disables it by default, and `docker info` warns `No memory limit support`.

To enable it, append `cgroup_enable=memory` to the line in `/boot/firmware/cmdline.txt` and reboot the Docker host.

### Adding it to a running installation

When you update from a version without the OpenSSH container, the following steps add it and keep the data in the directory.

```sh
# first, copy OPENSSH_* and PASSWDQC_MIN from .env.sample to .env
make                   # recreate the CA and the certificates, generate the sshd host keys
docker compose exec -T openldap ldapadd -c -Q -Y EXTERNAL -H ldapi:/// < openldap/ldif/300-ServiceAccounts.ldif
sudo chown 1000:10001 tftpd-hpa/tftpboot/firmware tftpd-hpa/tftpboot/configs
sudo chmod 2770 tftpd-hpa/tftpboot/firmware tftpd-hpa/tftpboot/configs
chmod -R go+rX syslog-ng/log/Hosts
make down && make up
```

- `ldapadd` adds the service account for OpenSSH. It reports `Already exists` for the entries that are already there, which is fine.
- The last `chmod` lets the users who log in over SSH read the log directories created so far. Earlier versions created them so that only the owner could enter.
- After that, give `posixAccount` to the users who are to log in over SSH (see [Users and roles](#users-and-roles)) and run `koitohan-update-users`.

## Ports

| Port             | Service               |
| ---------------- | --------------------- |
| 2222/tcp         | SSH (the number is `OPENSSH_PORT`) |
| 1812/udp         | RADIUS authentication |
| 514/udp, 514/tcp | syslog                |
| 69/udp           | TFTP                  |
| 636/tcp          | LDAPS                 |

Port 1813/udp is also published, but RADIUS accounting is not implemented yet.

## Logs

| Path                                    | Content                                |
| --------------------------------------- | -------------------------------------- |
| `syslog-ng/log/Hosts/<host>/<host>.log` | Syslog from each device                |
| `syslog-ng/log/debug.log`               | Every raw message, for troubleshooting |
| `freeradius/log/`                       | FreeRADIUS authentication logs         |

The files under `freeradius/log/` belong to uid 101. Read them with `sudo`.

Nothing rotates these files yet. `debug.log` in particular grows without limit.

TFTP transfers are not logged to a file. See them with `docker compose logs tftpd-hpa`. The same goes for SSH logins, with `docker compose logs openssh`.

## Commands

```sh
make                    # certs + ldap_dir + freeradius_conf + ssh_hostkeys
make certs              # private CA, server and client certificates
make ldap_dir           # LDIF files for OUs, roles, the service account and ACLs
make freeradius_conf    # FreeRADIUS LDAP module config and clients.conf
make ssh_hostkeys       # sshd host keys (kept if they already exist)
make ldap_testaccounts  # LDIF files for the test users
make test               # smoke test
make up                 # start the stack
make down               # stop the stack
make clean              # delete generated certificates, LDIF files and config
```

Check the FreeRADIUS configuration without starting the stack:

```sh
docker compose run --rm --no-deps freeradius radiusd -XC
```

Check authentication and authorization end to end:

```sh
make test
```

`make test` starts OpenLDAP, FreeRADIUS and OpenSSH as a separate project (`koitohan-test`), authenticates as the test users, and compares the reply attributes for every combination of device type and role. It then logs in over SSH as a user of each role and checks the permissions on the directories and a password change. At the end it restarts the OpenLDAP container and checks that it comes up again. It publishes no ports and keeps no data, so it does not affect a running stack. Run `make` beforehand. To look into a failed check, keep the test stack up with `KEEP=1 tests/smoke.sh`.

The tftpd-hpa and OpenSSH images are built automatically by the first `make up`. After you change `tftpd-hpa/build/` or `openssh/build/`, rebuild them before you start the stack.

```sh
docker compose build tftpd-hpa openssh
make up
```

`make clean` keeps the sshd host keys (`openssh/hostkeys/`). A new host key makes the client of every user show a warning.

Follow the logs of a service:

```sh
docker compose logs -f freeradius
```

## Known limitations

- A user who belongs to more than one role has no defined precedence.
- The TFTP server does not restrict the addresses it accepts requests from.
- Changes to users and roles do not reach SSH logins until you run `koitohan-update-users`.
- A logged-in user can get around the password check of `passwd`. The check is there to prevent weak passwords set by carelessness. OpenLDAP itself does not check passwords.
- A user logged in over SSH can connect from the OpenSSH container to the Docker host and to outside networks. The Docker network keeps them only from the containers other than OpenLDAP.
- When OpenLDAP restarts while FreeRADIUS keeps running, for example after `docker compose restart openldap`, FreeRADIUS rejects the logins that follow and then crashes with a segmentation fault. Docker starts it again, and logins work after that. This is a bug in FreeRADIUS 4.x, which is a development version. To avoid the rejected logins, restart FreeRADIUS right after OpenLDAP with `docker compose restart freeradius`. This item will be removed when FreeRADIUS fixes the bug.

## Security notes

These files contain private keys, shared secrets or passwords. Git ignores all of them. Keep them out of backups and copies that others can read.

- `.env`
- `CA/`
- `freeradius/config/clients.conf`
- `freeradius/config/mods-available/ldap_openldap`
- `openldap/ldif/*.ldif`
- `openssh/hostkeys/`
- `tftpd-hpa/tftpboot/configs/` (device configurations, which can contain password hashes and shared secrets)

`CA/freeradius_client.key` is readable by every user on the Docker host. FreeRADIUS reads it as uid 101, which owns nothing on the host.

The device logs under `syslog-ng/log/Hosts/` are readable by every user on the Docker host, so that the users who log in over SSH can read them.

RADIUS logins use PAP, so the shared secret of each client is what protects the user's password on the wire. Use a long random secret for each device.

TFTP has neither authentication nor encryption. Anyone who can reach 69/udp and knows a file name can download files from `firmware/` and `configs/`, and can overwrite files in `configs/`. That includes the configurations you have backed up. Publish 69/udp only to a trusted management network.

## Documentation

- [Basic design](docs/basic-design.md) (Japanese)

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
