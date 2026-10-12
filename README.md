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
make                   # generate certificates, the service account passwords, LDIF files, the FreeRADIUS LDAP config and the sshd host keys
$EDITOR freeradius/config/clients.conf
sudo chown -R 101:101 freeradius/log
sudo chown 1000:10001 tftpd-hpa/tftpboot/firmware
sudo chmod 2770 tftpd-hpa/tftpboot/firmware
make up
```

Change every password in `.env` before you run `make`. The values in `.env.sample` are public. The passwords of the service accounts of FreeRADIUS and OpenSSH are not in `.env`: `make` generates them (see [Service account passwords](#service-account-passwords)).

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
| `PASSWDQC_MIN`                        | Minimum lengths of the passwords `passwd` accepts. See [Changing a password](#changing-a-password). |
| `PPOLICY_MIN_LENGTH`                  | Minimum length of the passwords OpenLDAP accepts. See [Password policy](#password-policy). |
| `PPOLICY_MAX_FAILURE`                 | Number of failed logins that locks a user.                                     |
| `PPOLICY_FAILURE_WINDOW`              | Time in which the failures are counted, in seconds.                            |
| `PPOLICY_LOCKOUT_DURATION`            | Time a lock lasts, in seconds.                                                 |
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

Add and delete users, change a role, set a new password and unlock a user with `bin/manage_users.sh` on the Docker host. Run it while the stack is up.

```sh
bin/manage_users.sh add alice operator            # add. A third argument gives the full name
bin/manage_users.sh role alice admin              # change the role
bin/manage_users.sh passwd alice                  # set a new password
bin/manage_users.sh unlock alice                  # unlock
bin/manage_users.sh delete alice                  # delete
```

- A user has one role: `admin`, `operator` or `readonly`. A user who belongs to no role is rejected on every device.
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

To change a password, generate a new one, write it to the directory, then recreate the container. This is the example for FreeRADIUS. Adjust the `uid` and the suffix of the DN to your installation.

```sh
rm secrets/freeradius_service_account_password
make secrets            # generate a new password
docker compose exec -T openldap ldappasswd -Q -Y EXTERNAL -H ldapi:/// -T /dev/stdin \
  'uid=radius,ou=ServiceAccounts,dc=example,dc=com' < secrets/freeradius_service_account_password
make ldap_dir freeradius_conf
docker compose up -d --force-recreate freeradius
```

For OpenSSH, replace `freeradius` in the file name with `openssh`, the `uid` of the DN with the account of OpenSSH, and the service name in the last line with `openssh`. Recreating the OpenSSH container cuts the sessions of the users who are logged in.

When you update from a version that kept these passwords in `.env`, leave `.env` as it is and run `make secrets`. It takes the values of `.env` over to `secrets/`, so the directory needs no change.

```sh
make secrets            # takes the values of .env over to secrets/
# now remove the lines of FREERADIUS_SERVICE_ACCOUNT_PASSWORD and OPENSSH_SERVICE_ACCOUNT_PASSWORD from .env
docker compose build openssh
make up
```

If a value taken over is still the one of `.env.sample`, or a short one, change it with the steps above.

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
make                    # certs + secrets + ldap_dir + freeradius_conf + ssh_hostkeys
make certs              # private CA, server and client certificates
make secrets            # passwords of the service accounts (kept if they already exist)
make ldap_dir           # LDIF files for OUs, roles, the service accounts, the password policy and ACLs
make freeradius_conf    # FreeRADIUS LDAP module config and clients.conf
make ssh_hostkeys       # sshd host keys (kept if they already exist)
make test               # smoke test
make up                 # start the stack
make down               # stop the stack
make clean              # delete generated certificates, LDIF files and config
bin/manage_users.sh     # add and delete users, change a role, set a new password, unlock
```

Check the FreeRADIUS configuration without starting the stack:

```sh
docker compose run --rm --no-deps freeradius radiusd -XC
```

Check authentication and authorization end to end:

```sh
make test
```

`make test` starts OpenLDAP, FreeRADIUS and OpenSSH as a separate project (`koitohan-test`), adds test users with `bin/manage_users.sh`, authenticates as them, and compares the reply attributes for every combination of device type and role. It then logs in over SSH as a user of each role and checks the permissions on the directories and a password change. After that it runs each operation of `bin/manage_users.sh` and checks the password policy (the minimum length, the lock and the unlock). At the end it restarts the OpenLDAP container and checks that it comes up again. It publishes no ports and keeps no data, so it does not affect a running stack. Run `make` beforehand. To look into a failed check, keep the test stack up with `KEEP=1 tests/smoke.sh`.

The tftpd-hpa and OpenSSH images are built automatically by the first `make up`. After you change `tftpd-hpa/build/` or `openssh/build/`, rebuild them before you start the stack.

```sh
docker compose build tftpd-hpa openssh
make up
```

`make clean` keeps the sshd host keys (`openssh/hostkeys/`). A new host key makes the client of every user show a warning. It keeps the passwords of the service accounts (`secrets/`) as well (see [Service account passwords](#service-account-passwords)).

Follow the logs of a service:

```sh
docker compose logs -f freeradius
```

## Known limitations

- A user who belongs to more than one role has no defined precedence.
- The TFTP server does not restrict the addresses it accepts requests from.
- Changes to users and roles made without `bin/manage_users.sh` do not reach SSH logins until you run `koitohan-update-users`.
- A logged-in user can get around the password check of `passwd`. The check is there to prevent weak passwords set by carelessness. Even then, the minimum length that OpenLDAP checks by itself (`PPOLICY_MIN_LENGTH`) holds.
- Anyone who can reach the login prompt of a network device or the SSH port can lock a user whose name they know, by sending wrong passwords. A lock ends by itself when its time is over (see [Password policy](#password-policy)).
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
- `secrets/`
- `tftpd-hpa/tftpboot/configs/` (device configurations, which can contain password hashes and shared secrets)

`CA/freeradius_client.key` is readable by every user on the Docker host. FreeRADIUS reads it as uid 101, which owns nothing on the host.

The device logs under `syslog-ng/log/Hosts/` are readable by every user on the Docker host, so that the users who log in over SSH can read them.

RADIUS logins use PAP, so the shared secret of each client is what protects the user's password on the wire. Use a long random secret for each device.

TFTP has neither authentication nor encryption. Anyone who can reach 69/udp and knows a file name can download files from `firmware/` and `configs/`, and can overwrite files in `configs/`. That includes the configurations you have backed up. Publish 69/udp only to a trusted management network.

## Documentation

- [Basic design](docs/basic-design.md) (Japanese)

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
