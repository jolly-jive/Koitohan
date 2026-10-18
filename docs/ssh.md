# The OpenSSH container

[日本語](ssh.ja.md)

The users cannot log in to the Docker host. Instead, there is a container they log in to over SSH, with the same user name and password as on the devices. There they read the logs of the devices, and the users with the role `admin` put firmware and take out configuration backups. They see only the logs and the files that are mounted for their role.

How the users work there is in the [user guide](user-guide.md). Replace the host name and the port number in it with the values of your installation before you hand it out. This page covers what the Koitohan administrators set up.

## Password rules

passwdqc checks the new password that a user sets with `passwd`. `PASSWDQC_MIN` in `.env` sets the minimum length for each number of character classes (upper case, lower case, digits and others). The value in `.env.sample`, `12,10,10,8,8`, means the following.

| Character classes used | Minimum length |
| ---------------------- | -------------- |
| 3 or more              | 8              |
| 2                      | 10             |
| 1                      | 12             |

An upper case letter at the beginning and a digit at the end do not count as classes. `Password1`, for example, counts as one class. Apply a change with `make up`.

Apart from this, OpenLDAP checks a minimum length by itself (see [Password policy](configuration.md#password-policy)). Keep the smallest value of `PASSWDQC_MIN` at `PPOLICY_MIN_LENGTH` or above.

## Applying changes to users and roles

The OpenSSH container reads the directory when it starts and builds the list of users who can log in. `bin/manage_users.sh` rebuilds the list after every change, so there is usually nothing to do. Rebuild the list yourself after you change the directory without the script.

```sh
docker compose exec openssh koitohan-update-users
```

A change of role does not reach the sessions that are already logged in. To apply it at once, rebuild the list and then close the sessions of that user. `<uidNumber>` is the `uidNumber` of the user.

```sh
docker compose exec openssh pkill -KILL -u <uidNumber>
```

## Sources of SSH

The OpenSSH container accepts connections only from the networks listed in `OPENSSH_ALLOWED_NETWORKS`. It is written like `DEVICE_NETWORKS`.

```sh
OPENSSH_ALLOWED_NETWORKS='10.0.0.0/8 172.16.0.0/12 192.168.0.0/16'
```

The default is all the private address ranges. If the terminals of your users are on known networks (the office LAN, the range a VPN hands out, a jump host), list only those. The networks of the devices need not be in it.

A connection from elsewhere is dropped without a reply. It never gets as far as trying a password, so nobody outside can lock a user by guessing (see [Password policy](configuration.md#password-policy)).

The container sees a connection from the Docker host itself as coming from the gateway of `OPENSSH_SUBNET`. Include `OPENSSH_SUBNET` if you want to try it from the host.

Apply a change with `make up` (the OpenSSH container is made again, and the sessions that are logged in are closed).

## Connections out of the container

`OPENSSH_EGRESS` decides where the logged-in users can connect to from the OpenSSH container.

| Value                            | Where the users can connect to                        | Port forwarding                                        |
| -------------------------------- | ----------------------------------------------------- | ------------------------------------------------------ |
| `ldaps` (the value in `.env.sample`) | OpenLDAP (636/tcp) only                           | Not available                                          |
| `any`                            | Anywhere (the devices, the Docker host, the internet) but syslog and TFTP (514/tcp, 514/udp, 69/udp) | Local forwarding only (`ssh -J`, `ssh -L`)             |

The container does not start when the value is empty or anything else. The same goes when `.env` does not have the variable.

A connection that the value does not let out is refused at once: over TCP the users see `Connection refused`, and otherwise (`ping`, UDP) `Operation not permitted`.

Even with `ldaps`, names are looked up through the DNS of Docker, so outside names can be looked up as well.

`any` is for using the OpenSSH container as a jump host to the devices. Keep the following in mind.

- If you keep the networks of the terminals (`OPENSSH_ALLOWED_NETWORKS`) apart from the networks of the devices, every user who can log in reaches the networks of the devices through this container. The roles make no difference.
- The users also reach the ports of the Docker host itself, such as the host's own sshd.
- Syslog and TFTP are refused, whatever the address, so the users cannot reach them on the devices either. The ports that the Docker host publishes for syslog-ng and tftpd-hpa take no login, and they take what comes from the containers as coming from the Docker host. Through them, every user who can log in could write fake logs of a device, or write into `configs/`, which the roles keep to `admin`. Nothing would record who did it.
- Remote forwarding (`ssh -R`), agent forwarding, X11 forwarding and tunnels are not available with either value.

Port forwarding is not turned off with `any` because it would not help: `nc` and the like do the same.

Apply a change with `make up` (the OpenSSH container is made again, and the sessions that are logged in are closed).

## Enabling the memory limit (optional)

The OpenSSH container has limits on the number of processes, memory and CPU. The memory limit works only when the memory controller of cgroup is enabled on the Docker host. Raspberry Pi OS disables it by default, and `docker info` warns `No memory limit support`.

To enable it, append `cgroup_enable=memory` to the line in `/boot/firmware/cmdline.txt` and reboot the Docker host.
