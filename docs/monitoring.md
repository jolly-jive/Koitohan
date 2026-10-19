# Checking the services

[日本語](monitoring.ja.md)

When a service of Koitohan stops, it is easy to miss.

- When RADIUS stops, nobody can log in to the devices, so it gets noticed. But few people log in to network devices every day, and it may first show when someone has to log in to deal with an outage.
- Syslog goes over UDP, and a device says nothing when its messages do not arrive.
- A failed backup of a configuration over TFTP shows only when you want it back.
- When NTP stops serving, the clocks of the devices just drift, quietly.

`bin/check_services.sh` uses each service of the running stack to check that it works. It only checks, and tells nobody. We strongly recommend running it from cron and having its results reach you.

If you have monitoring apart from Koitohan (a monitoring server you already run, for example), checking RADIUS, syslog, TFTP and NTP from there is more reliable. This command is for when there is no such thing.

## What it checks

| Item              | How                                                                                       | NG or WARN when                                    |
| ----------------- | ----------------------------------------------------------------------------------------- | -------------------------------------------------- |
| Containers        | The state of the containers that should be up (with the number of restarts)               | one is not running (NG)                            |
| OpenLDAP          | From the OpenSSH container, binds over LDAPS with its service account                     | the bind fails (NG)                                |
| FreeRADIUS        | Sends Status-Server from inside the container                                             | no answer (NG)                                     |
| syslog-ng         | Asks over its control socket                                                              | no answer (NG)                                     |
| Where logs go     | The space on the filesystem of `syslog-ng/log/`                                           | 90% or more used (WARN)                            |
| tftpd-hpa         | Asks for a missing file from inside the container                                         | no `File not found` comes back (NG)                |
| `configs/`        | The owner as the container sees it, and the space on its filesystem                       | `in.tftpd` cannot write (NG), 90% or more (WARN)   |
| OpenSSH           | Connects to sshd from inside the container                                                | no answer (NG)                                     |
| chrony            | Whether it serves (only when `COMPOSE_PROFILES` has `ntp`)                                | it stopped serving, as the host clock is out of sync (NG) |
| Certificates      | When the certificates in `CA/` expire                                                     | within 30 days (WARN)                              |

Every request goes from inside a container to its loopback, so a narrow `DEVICE_NETWORKS` does not turn it away.

When `configs/` is not owned by `in.tftpd`, most often the image file of [TFTP](tftp.md#limit-the-space-uploads-can-use-strongly-recommended) is not mounted, or was mounted after tftpd-hpa started. The container sees the directory under it, owned by root, and every upload fails.

## Running it

Run it on the Docker host while the stack is up. It needs no `sudo` and changes nothing.

```sh
bin/check_services.sh
```

```
OK    openldap: running since 2026-10-18 19:35:38, restarted 0 times
...
OK    freeradius: answers Status-Server
OK    syslog-ng: answers on its control socket
OK    logs: the filesystem of /path/to/koitohan/syslog-ng/log is 83% full
OK    tftpd-hpa: answers a request
...
OK    certificates: none expires within 30 days
```

It prints a line for each item, `OK`, `NG`, `WARN` or `SKIP`, with what to do for an `NG` or a `WARN`. When there is an `NG`, it exits with 1.

With `-q`, it prints only the `NG` and the `WARN` lines, and nothing when all is well.

### What the RADIUS check needs

The request to FreeRADIUS goes from `127.0.0.1` inside the container, so `clients.conf` needs a client for `127.0.0.1` (`localhost` in `clients.conf.sample`). The command reads its shared secret from `clients.conf`.

```
client localhost {
	ipaddr = 127.0.0.1
	secret = <shared secret>
	nas_type = service-type
}
```

Without one, it prints a `WARN` and skips the RADIUS check. After adding it, load it with `docker compose restart freeradius`.

## Running it on a schedule (recommended)

Add lines to the crontab (`crontab -e`) of a Koitohan administrator who can run `docker`. Replace `/path/to/koitohan` with the directory of the repository.

```
MAILTO=koitohan-admin@example.com
*/15 * * * * /path/to/koitohan/bin/check_services.sh -q
0 8 * * * /path/to/koitohan/bin/check_services.sh
```

- The first line checks every 15 minutes. Cron mails to `MAILTO` only when there is output, and with `-q` there is output only when something is wrong. While it stays wrong, a mail comes every 15 minutes.
- The second line sends the results every morning at 8, also when all is well. This is the "I'm OK".

For `MAILTO` to send mail, the Docker host needs a mail transfer agent. Without mail, write a small script that hands the output to where it should go, and call that from the crontab.

```sh
#!/bin/sh
# sends only when something is wrong. For the morning one, drop -q to send always
OUT=$(/path/to/koitohan/bin/check_services.sh -q 2>&1)
[ -n "${OUT}" ] && printf '%s\n' "${OUT}" | <command that sends>
```

### When the "I'm OK" does not come

When the Docker host itself is down (power, storage, network), this command does not run either, and nothing comes. Then the only sign is that the morning results stop coming. On a day without them, check Koitohan.

## Good to know

- The tftpd-hpa check leaves a line in `tftpd-hpa/log/tftpd.log` each time (`RRQ from 127.0.0.1 filename firmware/koitohan-service-check`): a request to see that the file is missing. Do not put a file of that name in `firmware/`.
- The FreeRADIUS check sees only that it answers Status-Server. It does not check how FreeRADIUS asks OpenLDAP (the client certificate and the service account of FreeRADIUS). To check that, log in from a device.
- It does not remember the last results, so it does not tell only when something changes.
- The thresholds (90% of the space, 30 days for the certificates) are constants at the top of the script.
- `make host_check` checks the setup of the Docker host; this one checks the running services. When `check_services.sh` shows an `NG`, run `make host_check` as well.
