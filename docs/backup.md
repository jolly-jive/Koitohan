# Backup and restore

[日本語](backup.ja.md)

`bin/backup.sh` puts what Koitohan cannot make again into one archive: the settings, the passwords and keys, the directory of OpenLDAP, and the configurations the devices have uploaded. With the archive and the repository, you can rebuild Koitohan on a new host, for example after the storage of the Raspberry Pi has failed.

## What a backup holds

| In the archive                                     | What it is                                                     |
| -------------------------------------------------- | -------------------------------------------------------------- |
| `.env`                                             | The settings                                                   |
| `freeradius/config/clients.conf`                   | The RADIUS clients and their shared secrets                    |
| `secrets/`                                         | The passwords of the service accounts and of the OpenLDAP administrators |
| `openssh/hostkeys/`                                | The host keys of the OpenSSH container                         |
| `ldap/config.ldif`, `ldap/data.ldif`               | The configuration and the contents of the directory (users, roles, passwords, locks) |
| `tftp-configs.tar`                                 | The files in `tftpd-hpa/tftpboot/configs/`, with their owners and modes |
| `koitohan-backup.txt`                              | When and on which host the backup was taken, and the commit of the repository |

These are left out:

- **The logs** (`syslog-ng/log/`, `freeradius/log/`, `tftpd-hpa/log/`). Koitohan is meant to run as a redundant pair, and the devices send their logs to both servers. The logs of a lost server are on the other one.
- **`tftpd-hpa/tftpboot/firmware/`**. Firmware can be downloaded again from the vendors.
- **What `make` makes again**: the certificates in `CA/`, the LDIF files, the FreeRADIUS LDAP config, the device networks of syslog-ng and the logrotate config. The certificates are used only between the containers of the stack, so a new CA affects nothing outside.
- **The steps done with `sudo`** on the Docker host, such as the image file of `configs/` and `/etc/fstab`. Do them again on a new host.

The directory and `secrets/` have to come from the same backup. The directory knows the passwords of the service accounts, and FreeRADIUS and OpenSSH bind with the ones in `secrets/`.

## Taking a backup

Run `bin/backup.sh` on the Docker host while the stack is running. Give it the directory to write to.

```sh
bin/backup.sh /var/backups/koitohan
```

It writes `koitohan-<host>-<date>-<time>.tar.gz` with the mode 0600. The stack keeps running: the directory is dumped with `slapcat`, which reads a consistent state while OpenLDAP runs.

With `-k`, it deletes the older archives of the same host in that directory once the new one is written, and keeps the given number of them.

```sh
bin/backup.sh -k 14 /var/backups/koitohan
```

### Keep the archive safe

The archive is not encrypted. It holds the shared secrets of the devices, the passwords of the service accounts and of the OpenLDAP administrators, the host keys and the password hashes of the users, all as they are. Anyone who has it can pose as Koitohan to the devices and to the users.

- Keep it where only the Koitohan administrators can read it. Keep the mode 0600 when you copy it.
- Copy it over an encrypted channel, such as `scp` or `rsync` over SSH.
- Keep a copy off the Docker host. A backup on the same storage is lost with it.

### Running it every day

Add a line to the crontab of a Koitohan administrator who can run `docker` (`crontab -e`). Replace `/path/to/koitohan` with the directory of the repository. This example takes a backup at 3:30 every day, keeps 14 of them, and sends the output to the journal of the host.

```sh
# prepare the directory once
sudo install -d -m 700 -o "$USER" -g "$USER" /var/backups/koitohan
```

```
30 3 * * * /path/to/koitohan/bin/backup.sh -k 14 /var/backups/koitohan 2>&1 | logger -t koitohan-backup
```

Check the result with `journalctl -t koitohan-backup`. A successful run prints `wrote <archive>`.

To copy the archives to another host at 3:45, add a line like this. The SSH key it uses must work without a passphrase, so limit what it can do on the other host.

```
45 3 * * * rsync -a /var/backups/koitohan/ backup-host:koitohan/ 2>&1 | logger -t koitohan-backup
```

## Restoring onto a new host

Run these in the directory of the repository, as the user who will run the stack. `<archive>` is the path of the backup.

1. Clone the repository and check out the commit written in the archive. A newer commit may set up the directory differently from the one in the backup.

   ```sh
   git clone https://github.com/jolly-jive/Koitohan.git koitohan
   cd koitohan
   tar -x -O -z -f <archive> koitohan-backup.txt
   git checkout <commit>
   ```

2. Take the settings, the passwords and the host keys out of the archive, then run `make`. `make` keeps the passwords and the host keys it finds, and makes new certificates.

   ```sh
   tar -x -z -f <archive> .env freeradius/config/clients.conf secrets openssh/hostkeys
   make
   ```

3. Do the steps with `sudo` from the [quick start](../README.md#quick-start) and from [TFTP](tftp.md#limit-the-space-uploads-can-use-strongly-recommended), and check them.

   ```sh
   make host_check
   ```

4. Load the directory, then start the stack. `bin/restore_ldap.sh` makes the OpenLDAP container without starting it, loads the directory into its empty data, and marks it so that OpenLDAP does not seed it again.

   ```sh
   bin/restore_ldap.sh <archive>
   make up
   ```

5. Put back the files in `configs/`. They go in through the tftpd-hpa container, which keeps their owners.

   ```sh
   tar -x -O -z -f <archive> tftp-configs.tar | docker compose exec -T tftpd-hpa tar -x -f - -C /tftpboot
   ```

6. Check that a device can log in over RADIUS and that a user can log in over SSH. The host keys are the same as before, so the clients of the users show no warning.

If you checked out an older commit in step 1, go back to the branch you follow with `git switch main`, and apply the changes since then as you would on a running Koitohan.

## Restoring the directory only

When the directory is broken, or a large part of it was deleted by mistake, load the directory of a backup into an empty OpenLDAP. Everything in the directory now is lost, so check that this is what you want first.

```sh
make down
sudo find openldap/data openldap/config -mindepth 1 ! -name .gitkeep -delete
bin/restore_ldap.sh <archive>
make up
```

`bin/restore_ldap.sh` refuses to run while `openldap/data/` or `openldap/config/` has anything in it.

If the passwords of the service accounts have been changed since the backup, `bin/restore_ldap.sh` warns that `secrets/` does not agree with the backup. FreeRADIUS or OpenSSH then cannot bind. After `make up`, give the account named in the warning a new password:

```sh
bin/change_service_account_password.sh freeradius
```

The passwords of the OpenLDAP administrators need nothing: OpenLDAP sets the ones in `secrets/` on every start.

## Restoring `configs/` only

```sh
tar -x -O -z -f <archive> tftp-configs.tar | docker compose exec -T tftpd-hpa tar -x -f - -C /tftpboot
```

A file of the same name in `configs/` is overwritten. Files that are not in the backup stay.

## Things to know

- A restore brings back the directory as it was at the backup. Users added or deleted, roles changed and passwords changed after that are lost, and the locks are as they were then. Tell the users who changed their password since the backup that the old one is back.
- `make up` reads the users again, so SSH logins follow the restored directory without `koitohan-update-users`.
- `bin/restore_ldap.sh` brings back the configuration of the directory (`cn=config`) from the backup as well, including the password policy and the access control.
- The archive has no entries for directories, so unpacking it does not change the mode of any directory in the repository.
