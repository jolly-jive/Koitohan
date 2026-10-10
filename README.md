# Koitohan

A little and kawaii network backend server.

[日本語](README.ja.md)

Koitohan is a Docker Compose stack that gives network devices a login backend and a log collector. It is built for a Raspberry Pi 5 and small or lab networks.

- **OpenLDAP** holds the users and their roles.
- **FreeRADIUS** authenticates device logins against LDAP and returns the privilege attributes each vendor expects.
- **syslog-ng** collects syslog from the devices, one directory per host.

You manage users and roles (`admin`, `operator`, `readonly`) in one place. Koitohan translates a role into what each device understands, such as `shell:priv-lvl=15` for Cisco or `Aruba-Priv-Admin-User = 15` for ArubaOS-CX.

## About the name

*Koitohan* (こいとはん) is a word from the speech of Osaka. In Osaka merchant families, a daughter of the house is called *itohan*. The word is said to come from *itoshii* ("dear") or *itokenai* ("young and innocent"), and it means a daughter her parents cherish. When a family has two or more daughters, the youngest is *ko-itohan*, the "little itohan".

Full-featured management servers for large networks already exist. Koitohan does not aim to be one of those fat servers. It aims to be small enough to run on a Raspberry Pi, to offer management functions a little better than the bare minimum, and still to take availability into account. It is a small and dear server, so it is named Koitohan.

Redundancy for availability is not implemented yet.

## Status

Koitohan is at the verification stage. It is not hardened for production use.

| Function | Component | Status |
| --- | --- | --- |
| Directory | OpenLDAP (`osixia/openldap`) | Working |
| Authentication and authorization | FreeRADIUS 4.x (`freeradius/rocky10`) | Working |
| Log collection | syslog-ng (`linuxserver/syslog-ng`) | Working |
| Log rotation | logrotate on the Docker host | Planned |
| File distribution | tftpd-hpa | Planned |
| DHCP and DNS | Kea, BIND9 | Undecided |

FreeRADIUS 4.x is a development version. Koitohan uses it ahead of its official release.

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
make up
```

Change every password in `.env` before you run `make`. The values in `.env.sample` are public.

`make` creates `freeradius/config/clients.conf` from `clients.conf.sample`. Replace the sample clients with your own devices before you run `make up`.

Use `make up` instead of calling `docker compose up` directly on a fresh checkout. It makes sure the generated files exist before Docker mounts them.

## Configuration

### `.env`

`.env` is the single source of configuration. The scripts and `compose.yaml` all read it.

| Variable | Meaning |
| --- | --- |
| `LDAP_DOMAIN` | Domain of the directory. `example.com` becomes the suffix `dc=example,dc=com`. |
| `LDAP_ORGANISATION` | Organization name stored in the directory. |
| `LDAP_ADMIN_PASSWORD` | Password of the LDAP data administrator (`cn=admin,<suffix>`). |
| `LDAP_CONFIG_PASSWORD` | Password of the LDAP configuration administrator. |
| `FREERADIUS_SERVICE_ACCOUNT_NAME` | Account FreeRADIUS uses to search the directory. |
| `FREERADIUS_SERVICE_ACCOUNT_PASSWORD` | Password of that account. |
| `OPENLDAP_CONTAINER_NAME` | Container name of OpenLDAP. |
| `FREERADIUS_CONTAINER_NAME` | Container name of FreeRADIUS. |
| `SYSLOG_CONTAINER_NAME` | Container name of syslog-ng. |
| `DOCKER_SUBNET` | Subnet of the Docker network that connects the containers, in CIDR notation. |

The container names of OpenLDAP and FreeRADIUS are also the host names in their certificates. If you change them, regenerate the certificates with `make clean && make`.

Set `DOCKER_SUBNET` to a range that does not overlap the networks your devices are on or any network the host reaches. Apply a change with `make down && make up`.

Keep `DOCKER_SUBNET` inside a private address range. FreeRADIUS accepts requests only from private address ranges and loopback (see [RADIUS clients](#radius-clients)), so with any other range, RADIUS requests sent from the Docker host itself may be rejected.

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

| `nas_type` | Attribute | admin | operator | readonly |
| --- | --- | --- | --- | --- |
| `cisco` | `Cisco-AVPair` | `shell:priv-lvl=15` | `shell:priv-lvl=7` | `shell:priv-lvl=1` |
| `aruba-cx` | `Aruba-Priv-Admin-User` | 15 | 7 | 1 |
| `aruba-ap` | none | accept | reject | reject |
| `fortinet`, `fortigate` | `Fortinet-Group-Name` | `super_admin` | `readonly` | `readonly` |
| `juniper` | `Juniper-Local-User-Name` | `superuser` | `operator` | `read-only` |
| `palo-alto` | `PaloAlto-Admin-Role` | `superuser` | `readonly` | `readonly` |
| `service-type`, `rfc2865` | `Service-Type` | `Administrative-User` | `NAS-Prompt-User` | `Login-User` |
| `ietf-mpl`, `allied` | `Management-Privilege-Level` | 15 | 7 | 1 |
| `nothing`, `no`, `none` | none | accept | accept | accept |

Any other value falls back to `Management-Privilege-Level`.

The values for Fortinet, Juniper and Palo Alto are names of profiles or users on the device. Define matching ones on the device.

FreeRADIUS accepts requests only from private address ranges (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`) and loopback.

### Users and roles

Users live under `ou=People`. Roles are `groupOfUniqueNames` entries under `ou=Roles`. Add a user to a role by adding the user's DN to the role's `uniqueMember`.

Koitohan does not include a tool for managing users. Use any LDAP client against `ldaps://<host>:636` with the CA certificate `CA/default-ca.pem`.

For a quick trial, `make ldap_testaccounts` generates three test users (`admin01`, `operator01`, `readonly01`), one per role. Their passwords are written in `scripts/generate_ldap_test_accounts.sh`. Run it before the first `make up`, and do not use it outside a lab.

### Changing the directory seed

OpenLDAP loads the generated LDIF files only on its first start with an empty database. To apply changes to `.env` or the LDIF files afterwards, you have to delete `openldap/data/` and `openldap/config/` and start again. This deletes every user and role in the directory.

## Ports

| Port | Service |
| --- | --- |
| 1812/udp | RADIUS authentication |
| 514/udp, 514/tcp | syslog |
| 636/tcp | LDAPS |

Port 1813/udp is also published, but RADIUS accounting is not implemented yet.

## Logs

| Path | Content |
| --- | --- |
| `syslog-ng/log/Hosts/<host>/<host>.log` | Syslog from each device |
| `syslog-ng/log/debug.log` | Every raw message, for troubleshooting |
| `freeradius/log/` | FreeRADIUS authentication logs |

Nothing rotates these files yet. `debug.log` in particular grows without limit.

## Commands

```sh
make                    # certs + ldap_dir + freeradius_conf
make certs              # private CA, server and client certificates
make ldap_dir           # LDIF files for OUs, roles, the service account and ACLs
make freeradius_conf    # FreeRADIUS LDAP module config and clients.conf
make ldap_testaccounts  # LDIF files for the test users
make up                 # start the stack
make down               # stop the stack
make clean              # delete generated certificates, LDIF files and config
```

Check the FreeRADIUS configuration without starting the stack:

```sh
docker compose run --rm --no-deps freeradius radiusd -XC
```

Follow the logs of a service:

```sh
docker compose logs -f freeradius
```

## Known limitations

- A user who belongs to no role is still accepted, with no privilege attribute. What happens next depends on the device.
- A user who belongs to more than one role has no defined precedence.
- The `freeradius` and `syslog-ng` images are not pinned to a version.

## Security notes

These files contain private keys, shared secrets or passwords. Git ignores all of them. Keep them out of backups and copies that others can read.

- `.env`
- `CA/`
- `freeradius/config/clients.conf`
- `freeradius/config/mods-available/ldap_openldap`
- `openldap/ldif/*.ldif`

RADIUS logins use PAP, so the shared secret of each client is what protects the user's password on the wire. Use a long random secret for each device.

## Documentation

- [Basic design](docs/basic-design.md) (Japanese)

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
