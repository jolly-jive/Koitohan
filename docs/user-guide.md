# User guide

[日本語](user-guide.ja.md)

This guide is for the people who log in to the network devices that use Koitohan. The server that runs Koitohan is built and run by the Koitohan administrators, whose steps are in the [README](../README.md) and the operating guides.

> To the Koitohan administrators: replace `<host>` and the port number `2222` in this guide with the values of your installation before you hand it out.

## What Koitohan does for you

- **One account logs you in to every device.** Koitohan keeps the user names and passwords in one place, so they need not be registered on each device. What you can do on a device depends on your role.
- **You can read the logs of the devices.** The syslog that the devices send is kept on Koitohan, device by device.
- **You can hand out firmware and take out configuration backups** (role `admin` only). The devices exchange files with Koitohan over TFTP.
- **You can change your password yourself.**

There is a working environment for the users, to work with the logs and the files. Only the Koitohan administrators can log in to the Koitohan server itself. The working environment is a small Linux that you log in to over SSH, and it shows only the logs and the files that your role allows.

## Roles

Each user has one role: `admin`, `operator` or `readonly`. Ask a Koitohan administrator when you need another role.

| Role       | On the devices                            | In the working environment                                |
| ---------- | ----------------------------------------- | --------------------------------------------------------- |
| `admin`    | Administrator, including the configuration | Read the logs, put firmware, take out configurations     |
| `operator` | Operator (the extent depends on the device) | Read the logs                                           |
| `readonly` | Read only                                 | Read the logs                                             |

What a role allows on a device depends on the kind of the device and its configuration. Ask a Koitohan administrator if you are not sure.

## Logging in to the working environment

Log in over SSH with the same user name and password as on the devices. Public key authentication is not supported yet.

```sh
ssh -p 2222 alice@<host>
```

- There are no home directories. Give the paths in the working environment as absolute paths to `scp` and `sftp`.
- You can write only where the table below says "read and write".
- Whether you can connect from the working environment to other hosts, such as the devices, depends on how the Koitohan administrators set it up: not at all, only over SSH and/or with `ping`, or more widely. Where SSH goes out, local port forwarding (`ssh -J`, `ssh -L`) is available as well, to the same places. Other kinds of forwarding are not. Syslog (514/tcp, 514/udp) and TFTP (69/udp) cannot be used toward any host, and `traceroute` is not available. A connection that is not allowed fails at once with `Connection refused` or `Operation not permitted`.

| Path                  | Content                              | admin          | operator       | readonly       |
| --------------------- | ------------------------------------ | -------------- | -------------- | -------------- |
| `/logs/Hosts/`        | Syslog from each device              | read           | read           | read           |
| `/tftpboot/firmware/` | Files distributed to devices         | read and write | none           | none           |
| `/tftpboot/configs/`  | Configurations that devices uploaded | read and write | none           | none           |
| `/tmp/`               | Scratch space (32MB)                 | read and write | read and write | read and write |

What is in `/tmp/` is lost when the working environment is made again. Copy out what you want to keep.

## Reading the logs

The logs of a device are in `/logs/Hosts/<device>/<device>.log`. `<device>` is the host name that the device puts in its syslog (or its address, if the device does not put one).

- The file is switched every day, and the earlier days have the date in their names (`<device>.log-2026-10-10`).
- Files two or more days old are compressed (`<device>.log-2026-10-10.gz`). Read them with `zgrep` and `zcat`.

```sh
# pick one kind of message out of today's logs of every device
ssh -p 2222 alice@<host> 'grep -h LINK-3 /logs/Hosts/*/*.log' > link.txt

# the same for the logs of 2026-10-10
ssh -p 2222 alice@<host> 'zgrep -h LINK-3 /logs/Hosts/*/*.log-2026-10-10.gz' > link.txt

# copy the log of one device for one day to your computer
scp -P 2222 'alice@<host>:/logs/Hosts/core-switch/core-switch.log-2026-10-10.gz' .
```

## Handing out firmware and taking out configurations (admin only)

The devices download over TFTP the files you put in `/tftpboot/firmware/`. The configurations that the devices upload land in `/tftpboot/configs/`.

```sh
# put a firmware image in place
scp -P 2222 image.bin alice@<host>:/tftpboot/firmware/

# copy a configuration backup to your computer
scp -P 2222 alice@<host>:/tftpboot/configs/core-switch.cfg .
```

Devices refer to files as `firmware/<file>` and `configs/<file>`. An example on Cisco IOS:

```
copy running-config tftp://<host>/configs/core-switch.cfg
copy tftp://<host>/firmware/image.bin flash:
```

- A device can download a file you put only if others may read it. Fix a file you put with mode 0600 with `chmod 644`.
- You can read, copy and delete the configurations in `configs/`. You cannot change them in place.
- Transfer in binary mode.

## Changing your password

Log in to the working environment and run `passwd`. The new password also applies to your logins on the devices.

A new password has a minimum length that depends on the number of character classes it uses (upper case, lower case, digits and others). The default values are the following (the Koitohan administrators may have changed them).

| Character classes used | Minimum length |
| ---------------------- | -------------- |
| 3 or more              | 8              |
| 2                      | 10             |
| 1                      | 12             |

An upper case letter at the start and a digit at the end do not count as classes. `Password1`, for example, counts as one class.

## When you cannot log in

**After repeated failures, you are locked out for a while.** Logins on the devices and logins to the working environment share one count of failures. A successful login sets it back to 0.

- While you are locked out, the right password is rejected too. It looks the same as a wrong password.
- The lock ends by itself after a while. If you cannot wait, ask a Koitohan administrator to lift it.

**If you forget your password,** ask a Koitohan administrator to issue a new one. Log in with it, then change it to your own with `passwd`.

**If you cannot connect to the working environment,** these are the likely causes.

- After repeated failures from the same address, the working environment refuses connections from it for a while. Wait, then try again.
- The working environment takes connections only from the networks that the Koitohan administrators chose. If the connection times out with no answer, ask a Koitohan administrator whether your address is in them.
