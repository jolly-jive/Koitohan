# Logs

[日本語](logs.ja.md)

| Path                                    | Content                                | For the users (SSH)             |
| --------------------------------------- | -------------------------------------- | ------------------------------- |
| `syslog-ng/log/Hosts/<host>/<host>.log` | Syslog from each device                | `/logs/Hosts/<host>/<host>.log` |
| `syslog-ng/log/debug.log`               | Every raw message, for troubleshooting | not visible                     |
| `freeradius/log/`                       | FreeRADIUS authentication logs         | not visible                     |
| `tftpd-hpa/log/tftpd.log`               | TFTP transfers                         | not visible                     |

The users cannot log in to the Docker host, so they read the syslog of the devices by logging in to the OpenSSH container over SSH. How is in the [user guide](user-guide.md#reading-the-logs). The Koitohan administrators read the other logs on the Docker host.

The files under `freeradius/log/` belong to uid 101. Read them with `sudo`.

SSH logins are not logged to a file. See them with `docker compose logs openssh`.

## Rotation

logrotate on the Docker host rotates the files in the table above once a day. `make` generates its configuration as `logrotate/koitohan`. Put it where logrotate reads it.

```sh
make logrotate_conf
sudo install -m 644 -o root -g root logrotate/koitohan /etc/logrotate.d/koitohan
```

`make host_check` checks that the installed file is owned by root, that the group and the others cannot write it (logrotate skips such a file), and that it is the same as `logrotate/koitohan`.

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

## Standard output of the containers

The logs you read with `docker compose logs` (SSH logins, OpenLDAP, TFTP transfers) are kept by the logging driver of Docker. Of these, only the TFTP transfers are kept in a file as well. `compose.yaml` names no driver and follows the configuration of the Docker host.

The default driver of Docker (`json-file`) keeps logs without limit unless you set one. Choose a driver with a limit in `/etc/docker/daemon.json`. For example, this sends the logs to the journal of systemd.

```json
{
  "log-driver": "journald"
}
```

Other choices are `local`, which rotates by default, and `json-file` with `max-size` and `max-file`. The change applies to the containers created after Docker has restarted.
