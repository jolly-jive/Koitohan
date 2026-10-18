# <Vendor> <OS>

<!--
Copy this file to docs/devices/<vendor>-<os>.md, for example cisco-ios-xe.md.
Replace everything in angle brackets, and remove the sections you did not check.
Remove secrets and use documentation addresses (192.0.2.0/24, 198.51.100.0/24,
203.0.113.0/24) before you send it. See CONTRIBUTING.md.
-->

|              |                                              |
| ------------ | -------------------------------------------- |
| Models       | <models you checked>                         |
| Firmware     | <versions you checked>                       |
| Checked with | <hardware, or the name of the virtual image> |
| `nas_type`   | <value in clients.conf>                      |
| Checked on   | <YYYY-MM-DD>                                 |
| Reported by  | <your name or GitHub account>                |

## What was checked

Result: Yes, No, or Not checked.

| Check                                                                    | Result | Notes |
| ------------------------------------------------------------------------ | ------ | ----- |
| Login with the role `admin` gets the expected privileges                 |        |       |
| Login with the role `operator` gets the expected privileges              |        |       |
| Login with the role `readonly` gets the expected privileges              |        |       |
| When Koitohan rejects a user, the device falls back to local authentication |        | <can it be set to? can local authentication come first?> |
| When Koitohan does not reply, the device falls back to local authentication |        |       |
| Syslog appears under `syslog-ng/log/Hosts/`                              |        | <name of the directory> |
| TFTP download from `firmware/`                                           |        |       |
| TFTP upload of the configuration to `configs/`                           |        |       |

## RADIUS

```
<configuration on the device>
```

<What each role gets on the device, and anything to define on the device, such as profiles named after the reply values.>

## Syslog

```
<configuration on the device>
```

## TFTP

```
<commands on the device>
```

## Notes

<Anything else: differences between models or firmware versions, pitfalls.>
