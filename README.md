# Koitohan

A little and kawaii network backend server.

[日本語](README.ja.md)

Koitohan is a Docker Compose stack that gives network devices a login backend, a log collector and a file server. It is built for a Raspberry Pi 5 and small or lab networks.

- **OpenLDAP** holds the users and their roles.
- **FreeRADIUS** authenticates device logins against LDAP and returns the privilege attributes each vendor expects.
- **syslog-ng** collects syslog from the devices, one directory per host.
- **tftpd-hpa** distributes firmware to the devices and receives backups of their configurations.

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
| Log rotation                     | logrotate on the Docker host                    | Planned   |
| DHCP and DNS                     | Kea, BIND9                                      | Undecided |

FreeRADIUS 4.x is a development version. Koitohan uses it ahead of its official release. The image is built from the development branch in [freeradius-server-image](https://github.com/jolly-jive/freeradius-server-image), and `compose.yaml` pins it to one build.

## Requirements

- Docker with the Compose plugin
- GNU Make 4.3 or later
- `openssl`
- `slappasswd` (in the `slapd` package on Debian and Raspberry Pi OS)

## Quick start

```sh
git clone <repository-url> koitohan
cd koitohan

cp .env.sample .env    # then edit .env
make                   # generate certificates, LDIF files and the FreeRADIUS LDAP config
$EDITOR freeradius/config/clients.conf
sudo chown -R 101:101 freeradius/log
make up
```

Change every password in `.env` before you run `make`. The values in `.env.sample` are public.

`make` creates `freeradius/config/clients.conf` from `clients.conf.sample`. Replace the sample clients with your own devices before you run `make up`.

FreeRADIUS runs as uid 101 and writes its logs to `freeradius/log/`. Without the `chown`, it cannot record a login there and rejects every request.

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
| `DOCKER_SUBNET`                       | Subnet of the Docker network that connects the containers, in CIDR notation.   |
| `TZ`                                  | Time zone of every container, as a tz database name such as `Asia/Tokyo`.      |

The container names of OpenLDAP and FreeRADIUS are also the host names in their certificates. If you change them, regenerate the certificates with `make clean && make`.

Set `DOCKER_SUBNET` to a range that does not overlap the networks your devices are on or any network the host reaches. Apply a change with `make down && make up`.

Keep `DOCKER_SUBNET` inside a private address range. FreeRADIUS accepts requests only from private address ranges and loopback (see [RADIUS clients](#radius-clients)), so with any other range, RADIUS requests sent from the Docker host itself may be rejected.

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

Users live under `ou=People`. Roles are `groupOfUniqueNames` entries under `ou=Roles`. Add a user to a role by adding the user's DN to the role's `uniqueMember`.

Koitohan does not include a tool for managing users.

For a quick trial, `make ldap_testaccounts` generates three test users (`admin01`, `operator01`, `readonly01`), one per role. Their passwords are written in `scripts/generate_ldap_test_accounts.sh`. Run it before the first `make up`, and do not use it outside a lab.

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
sudo chown 1000:1000 tftpd-hpa/tftpboot/configs
```

Always run `chown` after `mount`. It changes the owner of the directory inside the image, and the directory underneath stays owned by root. That way, when the image is not mounted, uploads simply fail instead of landing on the host's disk.

If you mount the image after the stack has started, apply it to the container with `docker compose restart tftpd-hpa`.

If you start the stack without these steps, Docker creates `configs/` owned by root, and uploads fail. You can allow them with `sudo chown 1000:1000 tftpd-hpa/tftpboot/configs`, but that leaves uploads with no space limit and is not recommended.

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

## Ports

| Port             | Service               |
| ---------------- | --------------------- |
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

TFTP transfers are not logged to a file. See them with `docker compose logs tftpd-hpa`.

## Commands

```sh
make                    # certs + ldap_dir + freeradius_conf
make certs              # private CA, server and client certificates
make ldap_dir           # LDIF files for OUs, roles, the service account and ACLs
make freeradius_conf    # FreeRADIUS LDAP module config and clients.conf
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

`make test` starts OpenLDAP and FreeRADIUS as a separate project (`koitohan-test`), authenticates as the test users, and compares the reply attributes for every combination of device type and role. At the end it restarts the OpenLDAP container and checks that it comes up again. It publishes no ports and keeps no data, so it does not affect a running stack. Run `make` beforehand. To look into a failed check, keep the test stack up with `KEEP=1 tests/smoke.sh`.

The tftpd-hpa image is built automatically by the first `make up`. After you change `tftpd-hpa/build/`, rebuild it before you start the stack.

```sh
docker compose build tftpd-hpa
make up
```

Follow the logs of a service:

```sh
docker compose logs -f freeradius
```

## Known limitations

- A user who belongs to no role is still accepted, with no privilege attribute. What happens next depends on the device.
- A user who belongs to more than one role has no defined precedence.
- The TFTP server does not restrict the addresses it accepts requests from.
- When OpenLDAP restarts while FreeRADIUS keeps running, for example after `docker compose restart openldap`, FreeRADIUS rejects the logins that follow and then crashes with a segmentation fault. Docker starts it again, and logins work after that. This is a bug in FreeRADIUS 4.x, which is a development version. To avoid the rejected logins, restart FreeRADIUS right after OpenLDAP with `docker compose restart freeradius`. This item will be removed when FreeRADIUS fixes the bug.

## Security notes

These files contain private keys, shared secrets or passwords. Git ignores all of them. Keep them out of backups and copies that others can read.

- `.env`
- `CA/`
- `freeradius/config/clients.conf`
- `freeradius/config/mods-available/ldap_openldap`
- `openldap/ldif/*.ldif`
- `tftpd-hpa/tftpboot/configs/` (device configurations, which can contain password hashes and shared secrets)

`CA/freeradius_client.key` is readable by every user on the Docker host. FreeRADIUS reads it as uid 101, which owns nothing on the host.

RADIUS logins use PAP, so the shared secret of each client is what protects the user's password on the wire. Use a long random secret for each device.

TFTP has neither authentication nor encryption. Anyone who can reach 69/udp and knows a file name can download files from `firmware/` and `configs/`, and can overwrite files in `configs/`. That includes the configurations you have backed up. Publish 69/udp only to a trusted management network.

## Documentation

- [Basic design](docs/basic-design.md) (Japanese)

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
