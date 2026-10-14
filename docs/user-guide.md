# User guide

[日本語](user-guide.ja.md)

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

- Only users who have `posixAccount` and belong to a role can log in (see [Users and roles](configuration.md#users-and-roles)).
- There are no home directories. With `scp` and `sftp`, give the path on the container as an absolute path.
- Users can write only where the table says so. The contents of `/tmp/` are lost when the container is recreated.
- A device can download firmware placed by a user with the role `admin` only if the file is readable by others. Fix a file placed with mode 0600 with `chmod 644`.
- A user with the role `admin` can read, copy and delete the configurations uploaded by devices, but cannot edit them in place.
- Port forwarding is turned off.
- After repeated authentication failures from one address, sshd refuses connections from that address for a while. This is the default behavior of `PerSourcePenalties` in OpenSSH.

## Changing a password

Run `passwd` in the shell. The new password also applies to logins on the network devices.
