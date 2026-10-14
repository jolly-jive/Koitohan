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

### Enabling the memory limit (optional)

The OpenSSH container has limits on the number of processes, memory and CPU. The memory limit works only when the memory controller of cgroup is enabled on the Docker host. Raspberry Pi OS disables it by default, and `docker info` warns `No memory limit support`.

To enable it, append `cgroup_enable=memory` to the line in `/boot/firmware/cmdline.txt` and reboot the Docker host.
