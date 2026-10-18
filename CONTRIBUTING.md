# Contributing

[日本語](CONTRIBUTING.ja.md)

Koitohan is maintained by one person, who has no network devices to try it with. The contribution we want most is configuration examples for network devices.

## Configuration examples for network devices

A configuration example shows what to set on a device so that it uses Koitohan:

- RADIUS login, and which `nas_type` to give the device in `clients.conf`
- sending syslog
- TFTP: downloading firmware from `firmware/` and backing up the configuration to `configs/`

One file covers one kind of device and its operating system, for example Cisco IOS XE or ArubaOS-CX. A partial example, such as RADIUS alone, is welcome too. Say what you did not check.

Examples checked on a virtual image of the device, such as a simulator or a virtual appliance from the vendor, are welcome as well. Say which image you used. Examples from the vendors themselves are welcome too.

### What to check

Check what you can on your device, and record the results in the table at the top of the example.

- Logins with the roles `admin`, `operator` and `readonly` each get the privileges you expect.
- When Koitohan rejects a user (a wrong password, a locked user, or a user without a role), does the device fall back to its local authentication? Can it be set to do so, or to try local authentication first?
- When Koitohan does not reply, does the device fall back to its local authentication?
- Syslog from the device appears under `syslog-ng/log/Hosts/`. Which name does the directory get (the host name or the address of the device)?
- The device downloads a file from `firmware/` over TFTP.
- The device uploads its configuration to `configs/` over TFTP.

The behavior around local authentication differs between devices, and [Local authentication on the devices](docs/configuration.md#local-authentication-on-the-devices) only says what we have seen so far. Your results help us correct that section.

### How to send it

1. Copy [docs/devices/TEMPLATE.md](docs/devices/TEMPLATE.md) to `docs/devices/<vendor>-<os>.md`, in lowercase with hyphens, for example `cisco-ios-xe.md`.
2. Fill it in, and add a row to the table in [docs/devices/README.md](docs/devices/README.md).
3. Open a pull request.

If you would rather not open a pull request, open an issue and paste the filled-in template there.

Write in English. If you prefer Japanese, send it in Japanese, and the maintainer will translate it.

The maintainer cannot check the examples on real devices. They are published as you report them, with your name, the date and the firmware version you used.

### Before you send it

Remove anything secret from what you paste:

- the RADIUS shared secret, passwords and password hashes, SNMP communities, keys
- addresses and host names of your network: use the documentation addresses `192.0.2.0/24`, `198.51.100.0/24` and `203.0.113.0/24`, and names such as `koitohan.example.com`

Configurations backed up to `configs/` usually contain password hashes and shared secrets, so do not paste them as they are.

## A new vendor

If your device needs reply attributes that Koitohan does not return yet (see the table of `nas_type` in [RADIUS clients](docs/configuration.md#radius-clients)), open an issue with:

- the vendor, the device and its operating system
- the name of the attribute, and where its dictionary is defined
- the values for `admin`, `operator` and `readonly`

Adding a vendor takes changes in four places of FreeRADIUS and the smoke test, so it is easier for the maintainer to make them. A configuration example for the device helps as well.

## Other contributions

Bug reports and fixes to the documentation are welcome as issues or pull requests. For a pull request that changes the stack, run `make test` and make sure that all the checks pass.

## License

Contributions are accepted under the Apache License 2.0, the license of this repository (see section 5 of [LICENSE](LICENSE)). No separate agreement is needed.
