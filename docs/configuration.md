# Configuration

[日本語](configuration.ja.md)

## `.env`

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
| `TFTP_UPLOAD_MAX_BYTES`               | Size limit, in bytes, for one file uploaded over TFTP. See [TFTP](tftp.md).      |
| `OPENSSH_CONTAINER_NAME`              | Container name of OpenSSH.                                                     |
| `OPENSSH_HOSTNAME`                    | Host name of the OpenSSH container. It appears in the prompt of the shell.     |
| `OPENSSH_PORT`                        | Port of the Docker host that publishes SSH. Keep it apart from the host's own sshd. |
| `OPENSSH_SUBNET`                      | Subnet of the Docker network that connects only OpenSSH and OpenLDAP, in CIDR notation. |
| `OPENSSH_ALLOWED_NETWORKS`            | Networks that SSH connections are accepted from. See [Sources of SSH](ssh.md#sources-of-ssh). |
| `OPENSSH_EGRESS`                      | Where the users can connect to from the OpenSSH container: `none`, `any`, or `ssh` and `icmp` separated by a space. See [Connections out of the container](ssh.md#connections-out-of-the-container). |
| `OPENSSH_SERVICE_ACCOUNT_NAME`        | Account the OpenSSH container uses to search the directory.                    |
| `PASSWDQC_MIN`                        | Minimum lengths of the passwords `passwd` accepts. See [Password rules](ssh.md#password-rules). |
| `PPOLICY_MIN_LENGTH`                  | Minimum length of the passwords OpenLDAP accepts. See [Password policy](#password-policy). |
| `PPOLICY_MAX_FAILURE`                 | Number of failed logins that locks a user.                                     |
| `PPOLICY_FAILURE_WINDOW`              | Time in which the failures are counted, in seconds.                            |
| `PPOLICY_LOCKOUT_DURATION`            | Time a lock lasts, in seconds.                                                 |
| `DOCKER_SUBNET`                       | Subnet of the Docker network that connects the containers, in CIDR notation.   |
| `DEVICE_NETWORKS`                     | Networks that RADIUS, syslog and TFTP are accepted from. See [Device networks](#device-networks). |
| `TZ`                                  | Time zone of every container, as a tz database name such as `Asia/Tokyo`.      |

The container names of OpenLDAP, FreeRADIUS and OpenSSH are also the host names in their certificates. If you change them, regenerate the certificates with `make clean && make`.

Set `DOCKER_SUBNET` and `OPENSSH_SUBNET` to ranges that do not overlap the networks your devices are on, any network the host reaches, or each other. Apply a change with `make down && make up`.

## Device networks

FreeRADIUS, syslog-ng and the TFTP server accept traffic only from the networks listed in `DEVICE_NETWORKS`. List IPv4 addresses or prefixes, separated by spaces.

```sh
DEVICE_NETWORKS='10.0.0.0/8 172.16.0.0/12 192.168.0.0/16'
```

The default is all the private address ranges. If your devices are managed from known networks, list only those. Anything that arrives from elsewhere is dropped without a reply.

- RADIUS is open only to the devices that are in these networks and also registered in `clients.conf` (see [RADIUS clients](#radius-clients)).
- For TFTP, include the addresses that the devices use when they fetch firmware from their boot loader.
- The containers see what the Docker host itself sends as coming from the gateway of `DOCKER_SUBNET`. Include `DOCKER_SUBNET` if you want to try the services from the host.
- The sources of SSH (the workspace container) have a variable of their own (see [Sources of SSH](ssh.md#sources-of-ssh)).

Apply a change with `make down && make up`.

`OPENSSH_HOSTNAME` is the name that tells the users which server they are logged in to. The prompt looks like `alice@koitohan:/logs/Hosts$`. When you run more than one Koitohan, give each a different name. Apply a change with `make up`.

`TZ` sets the time zone of the timestamps in the logs each container writes. Apply a change with `make up`.

## RADIUS clients

Describe the network devices in `freeradius/config/clients.conf`. `ipaddr` takes the address of one device, or a range of addresses such as `192.168.10.0/24`. The devices in a range share the shared secret and the `nas_type`. The `nas_type` of a client selects the reply attributes for that device.

```
client core-switch {
	ipaddr = 192.168.1.1
	secret = changeme
	nas_type = cisco
}

client access-switches {
	ipaddr = 192.168.10.0/24
	secret = changeme
	nas_type = aruba-cx
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

### Local authentication on the devices

How a network device configured for RADIUS chooses between RADIUS and its local authentication depends on the device and its configuration. In what we have checked so far, some devices fall back to local authentication only when the RADIUS server does not reply, and do not try local authentication when the RADIUS server rejects the user (or accepts them). Not every device necessarily behaves this way, though. Some devices probably let you set the order of authentication and try local authentication first. Check the manual and the actual behavior of your devices.

On devices that behave as described above, keep the following in mind.

- Keep a local emergency account on each device. Use it to log in while Koitohan is down.
- Locked users and users without a role are rejected, so they do not fall back to the local authentication of the device.
- FreeRADIUS does not reply to requests from devices that are not in `clients.conf`, or from outside `DEVICE_NETWORKS`. The device then falls back to local authentication, so local passwords still work, and it is easy to miss that RADIUS is not in use. After you register a device, make sure that you can log in to it with a Koitohan account and that a record appears under `freeradius/log/radacct/<device address>/`.

On devices set to try local authentication first, users who have a local account on the device can log in regardless of their lock or role in Koitohan.

## Users and roles

Add and delete users, change a role, set a new password and unlock a user with `bin/manage_users.sh` on the Docker host. Run it while the stack is up.

```sh
bin/manage_users.sh add alice operator            # add. A third argument gives the full name
bin/manage_users.sh role alice admin              # change the role
bin/manage_users.sh passwd alice                  # set a new password
bin/manage_users.sh unlock alice                  # unlock
bin/manage_users.sh delete alice                  # delete
```

- A user has one role: `admin`, `operator` or `readonly`. A user who belongs to no role is rejected on every device. A user put into more than one role without the script is treated as the weakest of them (`readonly`, then `operator`, then `admin`), both on the devices and over SSH.
- `add` and `passwd` ask for the password on the terminal. It is checked by the same rules as when a user changes it with `passwd` (see [Password rules](ssh.md#password-rules)). Ask the user to log in over SSH and change the password you set.
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

## Password policy

The rules for passwords are enforced in two places.

| Place                                | What it enforces                                                    |
| ------------------------------------ | ------------------------------------------------------------------- |
| `passwd` and `bin/manage_users.sh`   | Minimum lengths by character classes (`PASSWDQC_MIN`, see [Password rules](ssh.md#password-rules)) |
| OpenLDAP (the ppolicy overlay)       | A minimum length (`PPOLICY_MIN_LENGTH`) and the lock                |

OpenLDAP refuses a password that is written as a hash, as it cannot check its length. Set the passwords of the users with `bin/manage_users.sh` or `passwd`.

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

## Service account passwords

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

## OpenLDAP administrator passwords

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

The script generates the two passwords, replaces the files in `secrets/`, recreates the OpenLDAP container and checks that the new passwords work. Every login fails until OpenLDAP is up again. FreeRADIUS is restarted afterwards because it refuses logins for a while after OpenLDAP has restarted (see [Known limitations](../README.md#known-limitations)).

If the script stops halfway, run it again. It does not need the current passwords.

## Changing the directory seed

OpenLDAP loads the generated LDIF files only on its first start with an empty database. To apply changes to `.env` or the LDIF files afterwards, you have to delete `openldap/data/` and `openldap/config/` and start again. This deletes every user and role in the directory. A change of `PPOLICY_*` is the exception and needs no deletion (see [Password policy](#password-policy)).

OpenLDAP does not start when it fails to load an LDIF file. Look at `docker compose logs openldap` for the cause, correct the LDIF file and start again.
