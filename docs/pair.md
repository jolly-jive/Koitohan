# Redundant pair

[日本語](pair.ja.md)

Two Koitohan hosts can run as a pair, so that the devices keep logging in when one host is down. Each device uses both hosts as its RADIUS, syslog and NTP servers. The two OpenLDAP servers replicate the directory both ways, and either host takes changes.

So far the pair has been tested with two OpenLDAP containers on one Docker host (the smoke test). What one host cannot show has not been tried on two machines yet: the address in the certificate, the limit on the sources of LDAPS, and a cut in the network between the hosts.

## What the hosts share

| What                                         | Between the hosts                                                    |
| -------------------------------------------- | -------------------------------------------------------------------- |
| Users, roles, passwords, locks               | Replicated by OpenLDAP                                               |
| Logs                                         | Not shared. The devices send them to both hosts.                     |
| `configs/` of TFTP                           | Not shared. The settings of each device decide where it sends.       |
| `firmware/` of TFTP                          | Not shared. Put the files on both hosts.                             |
| `.env`, `clients.conf`, the certificates     | Each host has its own. Each host has a CA of its own.                |

## Settings

Set these in `.env` on each host.

| Variable                    | Host A                         | Host B                         |
| --------------------------- | ------------------------------ | ------------------------------ |
| `OPENLDAP_HOST_ADDRESS`     | the address of host A          | the address of host B          |
| `OPENLDAP_PEER_ADDRESS`     | the address of host B          | the address of host A          |
| `OPENLDAP_ALLOWED_NETWORKS` | the address of host B          | the address of host A          |
| `OPENSSH_HOSTNAME`          | a name of its own              | another name                   |

- The addresses are IPv4, the ones that the two hosts reach each other at. `OPENLDAP_HOST_ADDRESS` goes into the certificate of OpenLDAP, and the other host checks it.
- `LDAP_DOMAIN` has to be the same on both hosts.
- 636/tcp has to get through between the two hosts.
- The password policy is in the directory, so it is shared. Change it on one host (see [Password policy](configuration.md#password-policy)).

## Making a pair from a running Koitohan

Host A is the Koitohan that runs now. Host B is new.

1. On host A, add the settings above to `.env`, then run `make`. The certificates are made again, with the address of host A in them, from a new CA.

2. Set up host B as in the [quick start](../README.md#quick-start), with the `.env` of host A changed as in the table above, and the same `clients.conf`. Run `make`, but do not start it yet.

3. Give each host the CA certificate of the other one: `CA/default-ca.pem` of host A goes to `openldap/peer/ca.pem` of host B, and that of host B to `openldap/peer/ca.pem` of host A. The certificate is not a secret, but check that what arrived is what was sent, for example by comparing the output of this on both ends:

   ```sh
   openssl x509 -noout -fingerprint -sha256 -in openldap/peer/ca.pem
   ```

4. On host A, start the stack again, so that it reads the new certificates and the other host:

   ```sh
   make down && make up
   ```

5. On host B, start the stack. Its OpenLDAP is empty, and receives the whole directory from host A before it serves anything. Until then, FreeRADIUS on host B does not answer and nobody can log in over SSH there. Its log says when it is done:

   ```sh
   make up
   docker compose logs -f openldap    # until "received the data from the other host"
   ```

6. Check both hosts. `bin/check_services.sh` says `OK pair: the same ... entries as the other host`.

7. Add host B to the devices as their second RADIUS, syslog and NTP server.

To make a pair from two new hosts, start host A alone first (`OPENLDAP_PEER_ADDRESS='none'`), so that it seeds the directory, then follow the steps above. Two empty hosts that both name each other wait for each other for good.

## Rules for running a pair

- **Do not manage users on both hosts at the same time.** Either host will do, one at a time. Two changes at once can give two users the same number, or lose one of two changes to a role.
- **Under a brute-force attack, stop FreeRADIUS on both hosts before you change the password.** The failed logins are written on both hosts, and a failure on one host at the moment of the change on the other can bring the old password back. With FreeRADIUS stopped on one host only, the devices turn to the other one. Meanwhile, log in to the devices with their local accounts.

  ```sh
  docker compose stop freeradius     # on both hosts
  bin/manage_users.sh passwd <user>  # on one host
  docker compose start freeradius    # on both hosts
  ```

- **After `make certs` (or a `make` that made the CA again) on one host,** give its new `CA/default-ca.pem` to the other host as `openldap/peer/ca.pem`, and restart OpenLDAP there with `docker compose restart openldap`. Until then, the two hosts do not replicate.
- Keep the clocks of both hosts in sync (`make host_check`). Replication goes by the times of the changes.
- Change `clients.conf` and `firmware/` on both hosts.

## When one host breaks

Delete the persistent data of OpenLDAP on the broken host, and start it. It receives everything from the other host, as host B did in step 5.

```sh
make down
sudo find openldap/data openldap/config -mindepth 1 ! -name .gitkeep -delete
make up
```

To build the host again from nothing, follow [Restoring onto a new host](backup.md#restoring-onto-a-new-host), but leave out `bin/restore_ldap.sh`: the directory comes from the other host. The new host has a new CA, so give it to the other host as in step 3, and restart OpenLDAP there.

## When the two hosts differ

`bin/check_services.sh` compares the two directories, entry by entry, and gives a `WARN`:

- `pair: differs from the other host`: the two hosts hold different entries, and still do after a few seconds. The lines under it show some of them (`only here` and `only there`, with the time of the last change).
  - First see whether replication gets through both ways: run `bin/check_services.sh` on the other host as well. When the other host says `cannot read the other host`, changes do not reach it, and the two catch up once that is fixed.
  - A difference that stays while both hosts read each other does not mend by itself. It can come from a restore of one host while the other kept its data (see [Restoring a pair](backup.md#restoring-a-pair)). Decide which host has the right directory, then delete the persistent data of the other host and start it, as in [When one host breaks](#when-one-host-breaks).
- `pair: cannot read the other host`: the other host is down, the network between them is cut, or the other host does not take this one (its `OPENLDAP_ALLOWED_NETWORKS`, or a CA certificate that was not given again after `make certs`).

## Back to a single host

Set `OPENLDAP_PEER_ADDRESS='none'` and `OPENLDAP_ALLOWED_NETWORKS='none'` on the host that stays, then `make down && make up`. Remove the other host from the devices.

## Restoring a backup

Restore one host only, and let the other one receive. See [Restoring a pair](backup.md#restoring-a-pair).
