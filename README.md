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
| Log rotation                     | logrotate on the Docker host                    | Working   |
| DHCP and DNS                     | Kea, BIND9                                      | Undecided |

FreeRADIUS 4.x is a development version. Koitohan uses it ahead of its official release. The image is built from the development branch in [freeradius-server-image](https://github.com/jolly-jive/freeradius-server-image), and `compose.yaml` pins it to one build.

## Requirements

- Docker with the Compose plugin
- GNU Make 4.3 or later
- `openssl`
- `slappasswd` (in the `slapd` package on Debian and Raspberry Pi OS)
- `ssh-keygen`. `make test` also uses `ssh` from OpenSSH 8.4 or later and a `curl` that supports TFTP.
- `logrotate`, which rotates the logs

## Quick start

```sh
git clone <repository-url> koitohan
cd koitohan

cp .env.sample .env    # then edit .env
make                   # generate certificates, passwords, LDIF files, the FreeRADIUS LDAP config, the sshd host keys and the logrotate config
$EDITOR freeradius/config/clients.conf
sudo chown -R 101:101 freeradius/log
sudo chown 1000:10001 tftpd-hpa/tftpboot/firmware
sudo chmod 2770 tftpd-hpa/tftpboot/firmware
sudo install -m 644 -o root -g root logrotate/koitohan /etc/logrotate.d/koitohan
make up
```

There are no passwords in `.env`. `make` generates the passwords of the OpenLDAP administrators and of the service accounts of FreeRADIUS and OpenSSH, and puts them in `secrets/` (see [OpenLDAP administrator passwords](#openldap-administrator-passwords) and [Service account passwords](#service-account-passwords)).

`make` creates `freeradius/config/clients.conf` from `clients.conf.sample`. Replace the sample clients with your own devices before you run `make up`.

FreeRADIUS runs as uid 101 and writes its logs to `freeradius/log/`. Without the `chown`, it cannot record a login there and rejects every request.

The `install` hands the configuration of the log rotation to logrotate on the Docker host (see [Rotation](#rotation)).

The `chown` and `chmod` on `firmware/` open the directory to the users with the role `admin`, and to no other user who logs in over SSH (see [Working over SSH](#working-over-ssh)). The steps in [TFTP](#tftp) do the same for `configs/`.

Use `make up` instead of calling `docker compose up` directly on a fresh checkout. It makes sure the generated files exist before Docker mounts them.

## Configuration

### `.env`

`.env` is the single source of configuration. The scripts and `compose.yaml` all read it.

| Variable                              | Meaning                                                                        |
| ------------------------------------- | ------------------------------------------------------------------------------ |
| `LDAP_DOMAIN`                         | Domain of the directory. `example.com` becomes the suffix `dc=example,dc=com`. |
| `LDAP_ORGANISATION`                   | Organization name stored in the directory.                                     |
| `FREERADIUS_SERVICE_ACCOUNT_NAME`     | Account FreeRADIUS uses to search the directory.                               |
| `OPENLDAP_CONTAINER_NAME`             | Container name of OpenLDAP.                                                    |
| `FREERADIUS_CONTAINER_NAME`           | Container name of FreeRADIUS.                                                  |
| `SYSLOG_CONTAINER_NAME`               | Container name of syslog-ng.                                                   |
| `TFTP_CONTAINER_NAME`                 | Container name of tftpd-hpa.                                                   |
| `TFTP_UPLOAD_MAX_BYTES`               | Size limit, in bytes, for one file uploaded over TFTP. See [TFTP](#tftp).      |
| `OPENSSH_CONTAINER_NAME`              | Container name of OpenSSH.                                                     |
| `OPENSSH_HOSTNAME`                    | Host name of the OpenSSH container. It appears in the prompt of the shell.     |
| `OPENSSH_PORT`                        | Port of the Docker host that publishes SSH. Keep it apart from the host's own sshd. |
| `OPENSSH_SUBNET`                      | Subnet of the Docker network that connects only OpenSSH and OpenLDAP, in CIDR notation. |
| `OPENSSH_ALLOWED_NETWORKS`            | Networks that SSH connections are accepted from. See [Sources of SSH](#sources-of-ssh). |
| `OPENSSH_SERVICE_ACCOUNT_NAME`        | Account the OpenSSH container uses to search the directory.                    |
| `PASSWDQC_MIN`                        | Minimum lengths of the passwords `passwd` accepts. See [Changing a password](#changing-a-password). |
| `PPOLICY_MIN_LENGTH`                  | Minimum length of the passwords OpenLDAP accepts. See [Password policy](#password-policy). |
| `PPOLICY_MAX_FAILURE`                 | Number of failed logins that locks a user.                                     |
| `PPOLICY_FAILURE_WINDOW`              | Time in which the failures are counted, in seconds.                            |
| `PPOLICY_LOCKOUT_DURATION`            | Time a lock lasts, in seconds.                                                 |
| `DOCKER_SUBNET`                       | Subnet of the Docker network that connects the containers, in CIDR notation.   |
| `DEVICE_NETWORKS`                     | Networks that RADIUS, syslog and TFTP are accepted from. See [Device networks](#device-networks). |
| `TZ`                                  | Time zone of every container, as a tz database name such as `Asia/Tokyo`.      |

The container names of OpenLDAP, FreeRADIUS and OpenSSH are also the host names in their certificates. If you change them, regenerate the certificates with `make clean && make`.

Set `DOCKER_SUBNET` and `OPENSSH_SUBNET` to ranges that do not overlap the networks your devices are on, any network the host reaches, or each other. Apply a change with `make down && make up`.

### Device networks

FreeRADIUS, syslog-ng and the TFTP server accept traffic only from the networks listed in `DEVICE_NETWORKS`. List IPv4 addresses or prefixes, separated by spaces.

```sh
DEVICE_NETWORKS='10.0.0.0/8 172.16.0.0/12 192.168.0.0/16'
```

The default is all the private address ranges. If your devices are managed from known networks, list only those. Anything that arrives from elsewhere is dropped without a reply.

- RADIUS is open only to the devices that are in these networks and also registered in `clients.conf` (see [RADIUS clients](#radius-clients)).
- For TFTP, include the addresses that the devices use when they fetch firmware from their boot loader.
- The containers see what the Docker host itself sends as coming from the gateway of `DOCKER_SUBNET`. Include `DOCKER_SUBNET` if you want to try the services from the host.
- The sources of SSH (the workspace container) have a variable of their own (see [Sources of SSH](#sources-of-ssh)).

Apply a change with `make down && make up`.

To upgrade from a version without this variable, copy `DEVICE_NETWORKS` from `.env.sample` to `.env`, rebuild the image of the TFTP server and start the stack again.

```sh
docker compose build tftpd-hpa
make down && make up
```

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

FreeRADIUS accepts requests only from the networks in `DEVICE_NETWORKS` (see [Device networks](#device-networks)) and loopback.

### Users and roles

Add and delete users, change a role, set a new password and unlock a user with `bin/manage_users.sh` on the Docker host. Run it while the stack is up.

```sh
bin/manage_users.sh add alice operator            # add. A third argument gives the full name
bin/manage_users.sh role alice admin              # change the role
bin/manage_users.sh passwd alice                  # set a new password
bin/manage_users.sh unlock alice                  # unlock
bin/manage_users.sh delete alice                  # delete
```

- A user has one role: `admin`, `operator` or `readonly`. A user who belongs to no role is rejected on every device. A user put into more than one role without the script is treated as the weakest of them (`readonly`, then `operator`, then `admin`), both on the devices and over SSH.
- `add` and `passwd` ask for the password on the terminal. It is checked by the same rules as when a user changes it with `passwd` (see [Changing a password](#changing-a-password)). Ask the user to log in over SSH and change the password you set.
- A user name takes lowercase letters, digits, `_` and `-`, up to 32 characters.
- `uidNumber` is handed out in order from 10000. A number is never reused, even after its user is deleted. The files a user leaves behind keep the number as their owner. The next number to hand out is kept in `cn=nextUidNumber` in the directory.
- A change reaches SSH logins at once. `delete` and `role` close the sessions of that user.
- `unlock` lifts the lock of a user who failed to log in too many times, without waiting for it to end (see [Password policy](#password-policy)). Setting a new password with `passwd` lifts the lock as well.

In the directory, users live under `ou=People`, and roles are `groupOfUniqueNames` entries under `ou=Roles`. A user belongs to a role when the role's `uniqueMember` holds the user's DN.

`delete`, `role`, `passwd` and `unlock` also work on users who were added without the script. Such a user needs `posixAccount` to log in over SSH. Give a `uidNumber` from 10000 to 59999 that no other user has and that was never used before, and set `gidNumber` to 10000. The first `add` starts the numbers after the highest one in use at that time.

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

### Password policy

The rules for passwords are enforced in two places.

| Place                                | What it enforces                                                    |
| ------------------------------------ | ------------------------------------------------------------------- |
| `passwd` and `bin/manage_users.sh`   | Minimum lengths by character classes (`PASSWDQC_MIN`, see [Changing a password](#changing-a-password)) |
| OpenLDAP (the ppolicy overlay)       | A minimum length (`PPOLICY_MIN_LENGTH`) and the lock                |

A user who keeps failing to log in is locked for a while. With the values in `.env.sample`, 10 failures (`PPOLICY_MAX_FAILURE`) within 5 minutes (`PPOLICY_FAILURE_WINDOW`) lock the user for 5 minutes (`PPOLICY_LOCKOUT_DURATION`).

- Logins on the network devices and logins over SSH share one count of failures. A successful login sets it back to 0.
- While a user is locked, the right password is rejected too. The reply is the same as for a wrong password, so it does not tell that the user is locked.
- A lock ends by itself when its time is over. To lift it at once, use `bin/manage_users.sh unlock <user>`.
- The service accounts of FreeRADIUS and OpenSSH are never locked.

After you change a `PPOLICY_*` value, generate the LDIF files again and apply the policy to the running OpenLDAP. The data in the directory stays.

```sh
make ldap_dir
docker compose exec -T openldap ldapmodify -c -Q -Y EXTERNAL -H ldapi:/// < openldap/ldif/400-PPolicy.ldif
```

It reports `Type or value exists`, `overlay "ppolicy" already in list` and `Already exists` for the module, the overlay and the entries that are already there, which is fine. Only the values are replaced.

The same steps add the policy when you update from a version without ppolicy. Copy `PPOLICY_*` from `.env.sample` to `.env` first. No errors are reported in this case. The passwords of the users who are already there keep working.

Once the policy is applied, OpenLDAP refuses a password that is written as a hash, as it cannot check its length. Set the passwords of the users with `bin/manage_users.sh` or `passwd`.

### Service account passwords

The FreeRADIUS and OpenSSH containers search the directory with a service account each. `make` (`make secrets`) generates the passwords of these accounts and puts them in `secrets/`.

| File                                          | Account                            |
| --------------------------------------------- | ---------------------------------- |
| `secrets/freeradius_service_account_password` | `FREERADIUS_SERVICE_ACCOUNT_NAME`  |
| `secrets/openssh_service_account_password`    | `OPENSSH_SERVICE_ACCOUNT_NAME`     |

Nobody types these passwords in normal operation. To see one, read the file. It has no newline at the end.

```sh
cat secrets/freeradius_service_account_password; echo
```

A file that already exists is kept, and `make clean` keeps it too. If it differed from the password the directory knows, the logins of every user would stop.

To change a password, use `bin/change_service_account_password.sh` on the Docker host. Run it while the stack is up.

```sh
bin/change_service_account_password.sh freeradius
bin/change_service_account_password.sh openssh
```

The script generates a new password, writes it to the directory, replaces the file in `secrets/`, generates the LDIFs and the LDAP configuration of FreeRADIUS again, and recreates the container. Recreating the OpenSSH container cuts the sessions of the users who are logged in.

If the script stops halfway, run it again. It does not need the current password, so the same command also repairs a file in `secrets/` that no longer matches the directory.

Use the script as well when you update from a version that kept these passwords in `.env`. The values of `.env` are not read any more, and the passwords that `make` generates do not match the directory, so the script writes them to it. SSH logins fail until it has finished.

### OpenLDAP administrator passwords

OpenLDAP has two administrators that log in with a password. Neither is subject to the access control or to the password policy. `make` (`make secrets`) generates their passwords and puts them in `secrets/`.

| File                           | Administrator                                          |
| ------------------------------ | ------------------------------------------------------ |
| `secrets/ldap_admin_password`  | Administrator of the data (`cn=admin,<suffix>`)        |
| `secrets/ldap_config_password` | Administrator of the configuration (`cn=admin,cn=config`) |

The scripts of this stack use neither password. Work from the Docker host goes through `ldapi:///` inside the container, which makes you an administrator without a password (`docker compose exec openldap ldapsearch -Q -Y EXTERNAL -H ldapi:/// ...`). You need a password only when you connect an LDAP client to port 636, and you can pass it as the file (`ldapsearch -y secrets/ldap_admin_password`). The files have no newline at the end.

The OpenLDAP container sets the passwords from the files again on every start. A password that you change in the directory alone goes back on the next start.

A file that already exists is kept, and `make clean` keeps it too.

To change the passwords, use `bin/change_ldap_admin_password.sh` on the Docker host. Run it while the stack is up.

```sh
bin/change_ldap_admin_password.sh
docker compose restart freeradius
```

The script generates the two passwords, replaces the files in `secrets/`, recreates the OpenLDAP container and checks that the new passwords work. Every login fails until OpenLDAP is up again. FreeRADIUS is restarted afterwards because it refuses logins for a while after OpenLDAP has restarted (see [Known limitations](#known-limitations)).

If the script stops halfway, run it again. It does not need the current passwords.

When you update from a version that kept these passwords in `.env` (`LDAP_ADMIN_PASSWORD`, `LDAP_CONFIG_PASSWORD`), switch over as follows. The OpenLDAP container is recreated and sets the generated passwords as it starts. Delete the two lines from `.env` afterwards.

```sh
make secrets
make up
docker compose restart freeradius
```

Do not run OpenLDAP with `--loglevel debug` in `compose.yaml`. The image would write the passwords it reads from the files to its log.

```sh
# first remove the lines of FREERADIUS_SERVICE_ACCOUNT_PASSWORD and OPENSSH_SERVICE_ACCOUNT_PASSWORD from .env
make
docker compose build openssh
make up
bin/change_service_account_password.sh freeradius
bin/change_service_account_password.sh openssh
```

### Changing the directory seed

OpenLDAP loads the generated LDIF files only on its first start with an empty database. To apply changes to `.env` or the LDIF files afterwards, you have to delete `openldap/data/` and `openldap/config/` and start again. This deletes every user and role in the directory. A change of `PPOLICY_*` is the exception and needs no deletion (see [Password policy](#password-policy)).

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
- The transfers are recorded in `tftpd-hpa/log/tftpd.log`, with the kind of the request (`RRQ` for a download, `WRQ` for an upload), the address of the requester and the file name. `docker compose logs tftpd-hpa` shows the same.

## Working over SSH

Users log in to the OpenSSH container over SSH, with the same user name and password they use on the network devices. The port is `OPENSSH_PORT` in `.env`, 2222 in `.env.sample`. Public key authentication is not supported yet.

```sh
ssh -p 2222 alice@<host>

# pick one kind of message out of today's logs of every device
ssh -p 2222 alice@<host> 'grep -h LINK-3 /logs/Hosts/*/*.log' > link.txt

# the same for the logs of 2026-10-10 (logs two or more days old are compressed)
ssh -p 2222 alice@<host> 'zgrep -h LINK-3 /logs/Hosts/*/*.log-2026-10-10.gz' > link.txt

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

Apart from this, OpenLDAP checks a minimum length by itself (see [Password policy](#password-policy)). Keep the smallest value of `PASSWDQC_MIN` at `PPOLICY_MIN_LENGTH` or above.

### Applying changes to users and roles

The OpenSSH container reads the directory when it starts and builds the list of users who can log in. `bin/manage_users.sh` rebuilds the list after every change, so there is usually nothing to do. Rebuild the list yourself after you change the directory without the script.

```sh
docker compose exec openssh koitohan-update-users
```

A change of role does not reach the sessions that are already logged in. To apply it at once, rebuild the list and then close the sessions of that user. `<uidNumber>` is the `uidNumber` of the user.

```sh
docker compose exec openssh pkill -KILL -u <uidNumber>
```

### Sources of SSH

The OpenSSH container accepts connections only from the networks listed in `OPENSSH_ALLOWED_NETWORKS`. It is written like `DEVICE_NETWORKS`.

```sh
OPENSSH_ALLOWED_NETWORKS='10.0.0.0/8 172.16.0.0/12 192.168.0.0/16'
```

The default is all the private address ranges. If the terminals of your users are on known networks (the office LAN, the range a VPN hands out, a jump host), list only those. The networks of the devices need not be in it.

A connection from elsewhere is dropped without a reply. It never gets as far as trying a password, so nobody outside can lock a user by guessing (see [Password policy](#password-policy)).

The container sees a connection from the Docker host itself as coming from the gateway of `OPENSSH_SUBNET`. Include `OPENSSH_SUBNET` if you want to try it from the host.

Apply a change with `make up` (the OpenSSH container is made again, and the sessions that are logged in are closed).

To upgrade from a version without this variable, copy `OPENSSH_ALLOWED_NETWORKS` from `.env.sample` to `.env`, rebuild the image and start the stack again.

```sh
docker compose build openssh
make up
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

- `ldapadd` adds the service account for OpenSSH. It reports `Already exists` for the entries that are already there, which is fine. Apply the password policy after this step (see [Password policy](#password-policy)). Applied first, it refuses the hashed passwords in this LDIF file.
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

Every port is published on IPv4 only. IPv6 is not supported.

RADIUS accounting (1813/udp) is not provided. The logins are recorded in the detail logs of FreeRADIUS, and the logouts and the operations in the syslog of the devices.

## Logs

| Path                                    | Content                                |
| --------------------------------------- | -------------------------------------- |
| `syslog-ng/log/Hosts/<host>/<host>.log` | Syslog from each device                |
| `syslog-ng/log/debug.log`               | Every raw message, for troubleshooting |
| `freeradius/log/`                       | FreeRADIUS authentication logs         |
| `tftpd-hpa/log/tftpd.log`               | TFTP transfers                         |

The files under `freeradius/log/` belong to uid 101. Read them with `sudo`.

SSH logins are not logged to a file. See them with `docker compose logs openssh`.

### Rotation

logrotate on the Docker host rotates the files in the table above once a day. `make` generates its configuration as `logrotate/koitohan`. Put it where logrotate reads it.

```sh
make logrotate_conf
sudo install -m 644 -o root -g root logrotate/koitohan /etc/logrotate.d/koitohan
```

| File                                               | Name after the rotation               | Days kept |
| -------------------------------------------------- | ------------------------------------- | --------- |
| `syslog-ng/log/Hosts/<host>/<host>.log`            | `<host>.log-2026-10-10.gz`            | 1096 (three years) |
| `syslog-ng/log/debug.log`                          | `debug.log-2026-10-10.gz`             | 7         |
| `freeradius/log/radius.log`                        | `radius.log-2026-10-10.gz`            | 1096      |
| `freeradius/log/radacct/<client>/auth-detail`, `reply-detail` | `auth-detail-2026-10-10.gz`, `reply-detail-2026-10-10.gz` | 1096 |
| `tftpd-hpa/log/tftpd.log`                          | `tftpd.log-2026-10-10.gz`             | 1096      |

- The date in the name is the date of the content. The rotation happens when logrotate runs after the date has changed.
- The file of the day before stays uncompressed for one more day (`<host>.log-2026-10-10`).
- A day without a single line leaves no file.
- logrotate only takes note of a file it sees for the first time, and starts rotating it the day after.
- The generated configuration contains the absolute path of the repository and the name of the syslog-ng container (`SYSLOG_CONTAINER_NAME` in `.env`). Run the two lines above again after you move the repository or change the container name.
- To keep the files for another number of days, change the values at the top of `scripts/generate_logrotate.sh`, then run the same two lines.
- To try the configuration, use `sudo logrotate -d /etc/logrotate.d/koitohan`. It changes nothing, and shows the files and what it would do with them.

In earlier versions, FreeRADIUS split its detail logs (`auth-detail`, `reply-detail`) by day itself, with the date in the name (`auth-detail-2026-9-2`). When you update a running environment, recreate the FreeRADIUS and OpenSSH containers.

```sh
docker compose build openssh    # brings zgrep, which reads the compressed logs
make up                         # recreates FreeRADIUS with the new detail log config, and OpenSSH from the new image
```

The files with the earlier names stay as they are. Delete them if you do not need them.

Earlier versions did not keep the TFTP transfers in a file. When you update a running environment, rebuild the image of the TFTP server, start it again, and install the logrotate configuration again.

```sh
docker compose build tftpd-hpa
make up
make logrotate_conf
sudo install -m 644 -o root -g root logrotate/koitohan /etc/logrotate.d/koitohan
```

### Standard output of the containers

The logs you read with `docker compose logs` (SSH logins, OpenLDAP, TFTP transfers) are kept by the logging driver of Docker. Of these, only the TFTP transfers are kept in a file as well. `compose.yaml` names no driver and follows the configuration of the Docker host.

The default driver of Docker (`json-file`) keeps logs without limit unless you set one. Choose a driver with a limit in `/etc/docker/daemon.json`. For example, this sends the logs to the journal of systemd.

```json
{
  "log-driver": "journald"
}
```

Other choices are `local`, which rotates by default, and `json-file` with `max-size` and `max-file`. The change applies to the containers created after Docker has restarted.

## Commands

```sh
make                    # private_dirs + certs + secrets + ldap_dir + freeradius_conf + device_networks + ssh_hostkeys + logrotate_conf
make private_dirs       # close the directories of keys and passwords to everyone but their owner
make certs              # private CA, server and client certificates
make secrets            # passwords of the service accounts and of the OpenLDAP administrators (kept if they already exist)
make ldap_dir           # LDIF files for OUs, roles, the service accounts, the password policy and ACLs
make freeradius_conf    # FreeRADIUS LDAP module config and clients.conf
make device_networks    # the device networks, in the config of FreeRADIUS and of syslog-ng
make ssh_hostkeys       # sshd host keys (kept if they already exist)
make logrotate_conf     # config for logrotate on the Docker host
make test               # smoke test
make up                 # start the stack
make down               # stop the stack
make clean              # delete generated certificates, LDIF files and config
bin/manage_users.sh     # add and delete users, change a role, set a new password, unlock
bin/change_service_account_password.sh   # change the password of a service account
bin/change_ldap_admin_password.sh        # change the passwords of the OpenLDAP administrators
```

Check the FreeRADIUS configuration without starting the stack:

```sh
docker compose run --rm --no-deps freeradius radiusd -XC
```

Check authentication and authorization end to end:

```sh
make test
```

`make test` starts every container as a separate project (`koitohan-test`), adds test users with `bin/manage_users.sh`, authenticates as them, and compares the reply attributes for every combination of device type and role. It also checks that FreeRADIUS makes a detail log again after the rotation has moved it away. For syslog and TFTP, it checks that traffic from the networks in `DEVICE_NETWORKS` arrives and that traffic from elsewhere does not. It also checks that a TFTP transfer is recorded in the file. It then logs in over SSH as a user of each role and checks the permissions on the directories, the reading of a compressed log and a password change. After that it runs each operation of `bin/manage_users.sh` and checks the password policy (the minimum length, the lock and the unlock) and the change of the passwords of the service accounts and of the OpenLDAP administrators. At the end it restarts the OpenLDAP container and checks that it comes up again. It publishes no ports, keeps no data and generates passwords of its own (`tests/generated/`), so it does not affect a running stack. Run `make` beforehand. To look into a failed check, keep the test stack up with `KEEP=1 tests/smoke.sh`.

The tftpd-hpa and OpenSSH images are built automatically by the first `make up`. After you change `tftpd-hpa/build/` or `openssh/build/`, rebuild them before you start the stack.

```sh
docker compose build tftpd-hpa openssh
make up
```

`make clean` keeps the sshd host keys (`openssh/hostkeys/`). A new host key makes the client of every user show a warning. It keeps the passwords in `secrets/` as well (see [Service account passwords](#service-account-passwords) and [OpenLDAP administrator passwords](#openldap-administrator-passwords)).

Follow the logs of a service:

```sh
docker compose logs -f freeradius
```

## Known limitations

- Changes to users and roles made without `bin/manage_users.sh` do not reach SSH logins until you run `koitohan-update-users`.
- A logged-in user can get around the password check of `passwd`. The check is there to prevent weak passwords set by carelessness. Even then, the minimum length that OpenLDAP checks by itself (`PPOLICY_MIN_LENGTH`) holds.
- Anyone who can reach the login prompt of a network device or the SSH port can lock a user whose name they know, by sending wrong passwords. A lock ends by itself when its time is over (see [Password policy](#password-policy)).
- A user logged in over SSH can connect from the OpenSSH container to the Docker host and to outside networks. The Docker network keeps them only from the containers other than OpenLDAP.
- When OpenLDAP restarts while FreeRADIUS keeps running, for example after `docker compose restart openldap`, FreeRADIUS rejects the logins that follow and then crashes with a segmentation fault. Docker starts it again, and logins work after that. This is a bug in FreeRADIUS 4.x, which is a development version. To avoid the rejected logins, restart FreeRADIUS right after OpenLDAP with `docker compose restart freeradius`. This item will be removed when FreeRADIUS fixes the bug.

## Security notes

These files contain private keys, shared secrets or passwords. Git ignores all of them. Keep them out of backups and copies that others can read.

- `CA/`
- `freeradius/config/clients.conf`
- `freeradius/config/mods-available/ldap_openldap`
- `openldap/ldif/*.ldif`
- `openssh/hostkeys/`
- `secrets/`
- `tftpd-hpa/tftpboot/configs/` (device configurations, which can contain password hashes and shared secrets)

`make` and `make up` close `CA/`, `secrets/` and `openssh/hostkeys/` to everyone but their owner (0700). `CA/freeradius_client.key` has the mode 0644, because FreeRADIUS reads it as uid 101 inside the container. The mode of the directory is what keeps it from the other users of the Docker host, so do not loosen it.

The private key of the CA is deleted once the certificates are issued. `make certs` makes a new CA every time, so the key is not needed again. If an earlier version left `CA/default-ca-key.pem` and `CA/*.csr` behind, delete them.

The device logs under `syslog-ng/log/Hosts/` are readable by every user on the Docker host, so that the users who log in over SSH can read them.

RADIUS logins use PAP, so the shared secret of each client is what protects the user's password on the wire. Use a long random secret for each device.

TFTP has neither authentication nor encryption. Anyone who can reach 69/udp and knows a file name can download files from `firmware/` and `configs/`, and can overwrite files in `configs/`. That includes the configurations you have backed up. Publish 69/udp only to a trusted management network.

## Documentation

- [Basic design](docs/basic-design.md) (Japanese)

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
