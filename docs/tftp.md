# TFTP

[日本語](tftp.ja.md)

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

## Limit the space uploads can use (strongly recommended)

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
sudo chown 1000:10001 tftpd-hpa/tftpboot/configs
sudo chmod 2770 tftpd-hpa/tftpboot/configs
```

Always run `chown` and `chmod` after `mount`. The owner, 1000, is tftpd-hpa. The group, 10001, is the users with the role `admin` who log in over SSH. The commands change the directory inside the image, and the directory underneath stays owned by root. That way, when the image is not mounted, uploads simply fail instead of landing on the host's disk.

If you mount the image after the stack has started, apply it to the container with `docker compose restart tftpd-hpa`.

If you start the stack without these steps, Docker creates `configs/` owned by root, and uploads fail. You can allow them with the `chown` and `chmod` above, but that leaves uploads with no space limit and is not recommended.

## Limit for a single file

`TFTP_UPLOAD_MAX_BYTES` in `.env` is the size limit, in bytes, for one uploaded file. The value in `.env.sample` is 16 MB. Apply a change with `make up`.

- This does not limit the total. It cannot stop someone from uploading many small files, so use it together with the image file above.
- An upload over the limit does not get an error. It times out on the device. A file cut off at the limit stays in `configs/`, and you have to delete it by hand. The server log does not record that the upload was cut off.
- The limit does not apply to downloads from `firmware/`.

## Things to know

- Transfer files in binary mode. Some clients, such as the `tftp` command on Linux, default to text (netascii) mode.
- The server replies from a UDP port other than 69. If a transfer from a PC fails, check that the firewall on the PC is not blocking those replies.
- `firmware/` sits directly on the disk of the Docker host. Check the free space before you put large firmware images there.
- The transfers are recorded in `tftpd-hpa/log/tftpd.log`, with the kind of the request (`RRQ` for a download, `WRQ` for an upload), the address of the requester and the file name. `docker compose logs tftpd-hpa` shows the same.
