# Linux System Inventory

A Bash utility that collects inventory information about a Linux host — system, hardware, CPU, memory, storage, network, listening ports, services, security and package updates — and prints it as a readable report or as JSON.

Run [system_inventory.sh](system_inventory.sh) directly with the required system utilities; no agent is installed. Collection reads local system information and package metadata. Hostname resolution can issue DNS requests; package repositories are not deliberately refreshed.

---

## Contents

- [Features](#features)
- [Repository structure](#repository-structure)
- [Supported distributions](#supported-distributions)
- [Requirements](#requirements)
- [Usage](#usage)
- [Options](#options)
- [Sections](#sections)
- [Output formats](#output-formats)
- [Example files](#example-files)
- [Saving the report to a file](#saving-the-report-to-a-file)
- [Running as root or as a normal user](#running-as-root-or-as-a-normal-user)
- [Exit codes](#exit-codes)
- [Troubleshooting](#troubleshooting)
- [Limitations](#limitations)
- [License](#license)

---

## Features

- **9 selectable sections**: collect everything or only what you need (`-s`, `-x`); unselected sections are not collected at all.
- **Two output formats** built from the same data: an aligned text report or single-line JSON for automation (`-J`).
- **File output**: reports request owner-only permissions (`600`); existing files require confirmation (or `-f`) before report output is written.
- **Local inventory collection**: inspected system configuration is not modified; package update counts come from local metadata caches without an explicit repository refresh.
- **Partial reports**: selected collection commands have time limits and record warnings for missing tools or collection failures. Captured partial output is retained when available.
- **Collection status**: recorded warnings are listed in text and JSON reports and reflected in the exit code.

---

## Repository structure

```text
Linux-System-Inventory/
|-- examples/
|   |-- inventory.json
|   `-- inventory.txt
|-- LICENSE
|-- README.md
`-- system_inventory.sh
```

## Supported distributions

The utility includes package-manager handling for these families. This table describes implemented compatibility.

| Family  | Distributions                                                     | Package manager |
| ------- | ----------------------------------------------------------------- | --------------- |
| Debian  | Debian, Ubuntu and derivatives                                    | `apt`           |
| Red Hat | RHEL, Rocky Linux, AlmaLinux, Oracle Linux, CentOS Stream, Fedora | `dnf` / `yum`   |
| SUSE    | SLES, openSUSE Leap, openSUSE Tumbleweed                          | `zypper`        |
| Arch    | Arch Linux, Manjaro, EndeavourOS                                  | `pacman`        |

Other distributions may provide the local inventory fields when the required Bash and GNU utilities are available. Missing optional tools can result in `N/A`, `Not available`, omitted fields or collection warnings, depending on the collector. Alpine Linux and BusyBox-only environments are outside the intended compatibility scope.

---

## Requirements

**Required**

- Bash 4.0 or later
- `awk`, `sort` and GNU `timeout`, which are checked before collection; `tee` is also checked when `-o` is used.
- Standard utilities including `cat`, `uname` and GNU `date`; `dirname` and `chmod` for file output; `readlink`, GNU `stat` and `tail` for the corresponding collection fields.
- Read access to the relevant `/proc`, `/sys` and `/etc` files. Output directories must already exist and be writable.
- `jq` only if you want to query or pretty-print JSON reports.

**Collection tools** (availability depends on the distribution and installation profile)

| Command                                                         | Package                      | Used by                                     |
| --------------------------------------------------------------- | ---------------------------- | ------------------------------------------- |
| `lscpu`, `lsblk`                                                | util-linux                   | `cpu`, `storage`                            |
| `df`                                                            | coreutils                    | `storage`                                   |
| `ip`, `ss`                                                      | iproute2                     | `network`, `ports`                          |
| `systemctl`, `systemd-detect-virt`, `timedatectl`, `resolvectl` | systemd                      | `system`, `network`, `services`, `security` |
| `who`, `getent`, `hostname`                                     | coreutils / glibc / hostname | `system`, `security`                        |
| `getenforce`                                                    | SELinux utilities            | `security`                                  |
| `sshd`                                                          | OpenSSH server               | `security`                                  |
| `apt-get`/`dpkg-query`, `dnf`/`yum`/`rpm`, `zypper`, `pacman`   | package manager              | `updates`                                   |

---

## Usage

```
system_inventory.sh [-s LIST] [-x LIST] [-J] [-o FILE [-f]] [-h]
```

From the project directory, run a report or request help:

```bash
bash system_inventory.sh
bash system_inventory.sh -h
```

See the options below for section selection, JSON output and file saving, and the [sample reports](#example-files) for the resulting formats.

---

## Options

| Option    | Description                                                                             |
| --------- | --------------------------------------------------------------------------------------- |
| `-s LIST` | Collect only the listed sections (comma-separated, case-insensitive).                   |
| `-x LIST` | Skip the listed sections (comma-separated). Can be combined with `-s`.                  |
| `-J`      | Print the report as JSON on a single line.                                              |
| `-o FILE` | Show the report and also save it to `FILE` (requests mode `600`).                       |
| `-f`      | Overwrite `FILE` without asking. Needed to replace an existing file without a terminal. |
| `-h`      | Show the help, including the list of sections.                                          |

Sections are always printed in the standard order, regardless of the order given in `-s`.

---

## Sections

| Section    | Content                                                             |
| ---------- | ------------------------------------------------------------------- |
| `system`   | Hostname, OS, kernel, uptime, hardware, virtualization, time, users |
| `cpu`      | CPU model, cores, threads, load average                             |
| `memory`   | RAM and swap usage                                                  |
| `storage`  | Block devices, filesystem and inode usage                           |
| `network`  | Gateways, DNS servers, interfaces                                   |
| `ports`    | Listening TCP/UDP sockets                                           |
| `services` | Systemd state, running and failed units                             |
| `security` | SELinux, AppArmor, firewall, SSH, admin users                       |
| `updates`  | Installed packages, pending/security updates, reboot required       |

### Fields per section

The first column is the JSON key, the second the label used in the text report.

<details>
<summary><b>system</b></summary>

| JSON key           | Text label       | Source / notes                                                            |
| ------------------ | ---------------- | ------------------------------------------------------------------------- |
| `HOSTNAME`         | Hostname         | `uname -n`                                                                |
| `FQDN`             | FQDN             | `hostname -f`, limited to 5 seconds (it can hang on DNS problems)         |
| `OS`               | Operating system | `PRETTY_NAME` from `/etc/os-release` (parsed, never executed)             |
| `OS_ID`            | _(JSON only)_    | `ID` from `/etc/os-release`, e.g. `rhel`, `ubuntu`                        |
| `OS_VERSION`       | _(JSON only)_    | `VERSION_ID` from `/etc/os-release`                                       |
| `KERNEL`           | Kernel           | `uname -sr`                                                               |
| `ARCHITECTURE`     | Architecture     | `uname -m`                                                                |
| `UPTIME`           | Uptime           | `/proc/uptime`                                                            |
| `LAST_BOOT`        | Last boot        | Boot time from `/proc/stat`                                               |
| `VENDOR`           | Vendor           | DMI (`/sys/class/dmi/id`), firmware placeholders discarded                |
| `MODEL`            | Model            | DMI                                                                       |
| `SERIAL`           | Serial number    | DMI, readable only by root (`Requires root` otherwise)                    |
| `VIRTUALIZATION`   | Virtualization   | `systemd-detect-virt` (e.g. `kvm`, `vmware`, `docker`, `None (physical)`) |
| `BOOT_MODE`        | Boot mode        | `UEFI` or `BIOS (legacy)`; empty inside containers                        |
| `TIMEZONE`         | Time zone        | `timedatectl`, or the `/etc/localtime` link                               |
| `NTP_SYNCHRONIZED` | NTP synchronized | `timedatectl` (`yes` / `no`)                                              |
| `LOGGED_USERS`     | Logged-in users  | `who`                                                                     |

</details>

<details>
<summary><b>cpu</b></summary>

| JSON key           | Text label       | Source / notes                                                    |
| ------------------ | ---------------- | ----------------------------------------------------------------- |
| `MODEL`            | CPU model        | `lscpu`                                                           |
| `VENDOR`           | Vendor           | `lscpu`                                                           |
| `LOGICAL_CPUS`     | Logical CPUs     | `lscpu`                                                           |
| `CORES`            | Physical cores   | Sockets × cores per socket (or threads ÷ threads per core on ARM) |
| `SOCKETS`          | Sockets          | `lscpu`                                                           |
| `THREADS_PER_CORE` | Threads per core | `lscpu`                                                           |
| `LOAD_AVERAGE`     | Load average     | `/proc/loadavg` (1, 5, 15 minutes)                                |

</details>

<details>
<summary><b>memory</b></summary>

| JSON key    | Text label    | Source / notes                                   |
| ----------- | ------------- | ------------------------------------------------ |
| `TOTAL`     | RAM total     | `/proc/meminfo`                                  |
| `USED`      | RAM used      | Total − available, with percentage               |
| `AVAILABLE` | RAM available | `MemAvailable`, with percentage                  |
| `SWAP`      | Swap          | Used / total and percentage, or `Not configured` |

</details>

<details>
<summary><b>storage</b></summary>

| JSON key        | Text label       | Columns                                                                                |
| --------------- | ---------------- | -------------------------------------------------------------------------------------- |
| `BLOCK_DEVICES` | Block devices    | `NAME TYPE FSTYPE SIZE MOUNTPOINT MODEL` (`lsblk`, without RAM disks and loop devices) |
| `FILESYSTEMS`   | Filesystem usage | `MOUNT TYPE SIZE USED AVAIL USE IUSE SOURCE` (`df`; `IUSE` is the inode usage)         |

Virtual filesystems (`tmpfs`, `proc`, `sysfs`, `cgroup`, `squashfs`, …) and duplicate overlay mounts are excluded.

</details>

<details>
<summary><b>network</b></summary>

| JSON key          | Text label      | Source / notes                                                                        |
| ----------------- | --------------- | ------------------------------------------------------------------------------------- |
| `DEFAULT_GATEWAY` | Default gateway | IPv4 and IPv6 default routes with their interface                                     |
| `DNS_SERVERS`     | DNS servers     | `/etc/resolv.conf`; with systemd-resolved the real upstream servers from `resolvectl` |
| `DNS_SEARCH`      | DNS search      | `search` / `domain` from `/etc/resolv.conf`                                           |
| `INTERFACES`      | Interfaces      | Table: `INTERFACE STATE MAC MTU IPV4 IPV6`                                            |

</details>

<details>
<summary><b>ports</b></summary>

| JSON key            | Text label        | Source / notes                                             |
| ------------------- | ----------------- | ---------------------------------------------------------- |
| `LISTENING_SOCKETS` | Listening sockets | Number of listening TCP/UDP sockets                        |
| `PROCESS_NAMES`     | Process names     | Present only for non-root users (`Requires root`)          |
| `SOCKETS`           | Sockets           | Table: `PROTO ADDRESS PORT PROCESS` (`ss`), sorted by port |

</details>

<details>
<summary><b>services</b></summary>

| JSON key             | Text label        | Source / notes                                              |
| -------------------- | ----------------- | ----------------------------------------------------------- |
| `SYSTEMD_STATE`      | Systemd state     | `running`, `degraded`, … or `Not running` (e.g. containers) |
| `RUNNING_SERVICES`   | Running services  | Number of running service units                             |
| `FAILED_UNITS_COUNT` | Failed units      | Number of failed units                                      |
| `FAILED_UNITS`       | Failed units list | Table: `UNIT STATE DESCRIPTION`                             |

</details>

<details>
<summary><b>security</b></summary>

| JSON key            | Text label          | Source / notes                                                              |
| ------------------- | ------------------- | --------------------------------------------------------------------------- |
| `SELINUX`           | SELinux             | `Enforcing`, `Permissive`, `Disabled` or `Not available`                    |
| `APPARMOR`          | AppArmor            | `Enabled`, `Disabled` or `Not available`                                    |
| `FIREWALL`          | Firewall service    | Active units among firewalld, ufw, nftables, netfilter-persistent, iptables |
| `SSH_SERVER`        | SSH server          | `Running`, `Not running` or `Not installed`                                 |
| `SSH_PORTS`         | SSH port(s)         | Root only, from `sshd -T` (effective configuration)                         |
| `SSH_ROOT_LOGIN`    | SSH root login      | Root only, `PermitRootLogin`                                                |
| `SSH_PASSWORD_AUTH` | SSH password auth   | Root only, `PasswordAuthentication`                                         |
| `SSH_SETTINGS`      | SSH settings        | Present only for non-root users (`Requires root`)                           |
| `ADMIN_USERS`       | Admin group members | Members of `sudo`, `wheel` and `admin`                                      |
| `OTHER_UID0_USERS`  | Other UID 0 users   | Accounts other than root with UID 0                                         |

</details>

<details>
<summary><b>updates</b></summary>

| JSON key             | Text label         | Source / notes                                                                                     |
| -------------------- | ------------------ | -------------------------------------------------------------------------------------------------- |
| `PACKAGE_MANAGER`    | Package manager    | `apt`, `dnf`, `yum`, `zypper` or `pacman`                                                          |
| `INSTALLED_PACKAGES` | Installed packages | Number of installed packages                                                                       |
| `UPDATES_AVAILABLE`  | Updates available  | From the local metadata cache                                                                      |
| `SECURITY_UPDATES`   | Security updates   | apt: `-security` pockets; dnf/yum: `updateinfo`; zypper: security patches; not available on pacman |
| `PACKAGE_METADATA`   | Package metadata   | Age of the metadata cache directory; flagged when older than 7 days                                |
| `REBOOT_REQUIRED`    | Reboot required    | `/var/run/reboot-required` (Debian/Ubuntu), otherwise running kernel vs newest installed kernel    |

</details>

---

## Output formats

### Text (default)

Fields are printed as `Label : value`, tables with aligned columns. Empty values are shown as `N/A`.

### JSON (`-J`)

The JSON is printed on a single line. Its structure is:

| Key                | Content                                                                        |
| ------------------ | ------------------------------------------------------------------------------ |
| `REPORT`           | `TITLE`, `VERSION`, `GENERATED`, `SECTIONS` (comma-separated list)             |
| `SYSTEM`, `CPU`, … | One object per selected section, with the keys listed in [Sections](#sections) |
| `WARNINGS`         | List of collection warnings (empty when complete)                              |
| `STATUS`           | `COMPLETE` or `INCOMPLETE`                                                     |

Conventions:

- Keys are uppercase. Scalar values, including counts, are strings; section objects and table/warning arrays retain their JSON types. Missing scalar values are empty strings (`""`), while unavailable fields may be omitted entirely.
- Tables are lists of objects whose keys are the column names.
- In JSON mode recorded collection warnings appear in `WARNINGS` instead of being printed on stderr. A successfully generated report is JSON only on stdout; usage and fatal errors can produce no JSON. Other command diagnostics may still reach stderr.

---

## Example files

The [examples](examples/) directory contains fictional sample reports:

| File                                      | Contents                                             |
| ----------------------------------------- | ---------------------------------------------------- |
| [inventory.txt](examples/inventory.txt)   | Abbreviated text report for `system,memory,storage`. |
| [inventory.json](examples/inventory.json) | Single-line JSON report for `memory,ports`.          |

HOST1, HOST2 ... are only the placeholders

---

## Saving the report to a file

`-o FILE` prints the report and saves the same content to `FILE` (without colors).

- New report files request owner-only read/write access through `umask 077`. Before overwriting an existing file, the utility attempts `chmod 600`. Effective permissions depend on the filesystem and whether permission changes succeed.
- The file is checked **before** collecting data: the utility stops immediately if the path is a directory, the directory does not exist or the file cannot be written.
- If the file already exists, the utility asks for confirmation on the terminal, including when output is piped. Accepted answers are `y`, `yes`, `s` and `si`; any other answer leaves the file unchanged.
- When the file already exists and no terminal is available, the utility stops with an error unless `-f` is given. Creating a new file does not require `-f`.

| Situation                         | Result                                           |
| --------------------------------- | ------------------------------------------------ |
| File does not exist               | Created with mode `600`                          |
| File exists, interactive terminal | Confirmation prompt (default: no)                |
| File exists, no terminal          | Error: `use -f to overwrite it`, exit code 1     |
| File exists, `-f`                 | Overwritten without asking; attempts `chmod 600` |

---

## Running as root or as a normal user

The utility works without root privileges. It marks protected serial numbers, non-root process-name access and SSH settings with `Requires root` where applicable. SSH settings fields are only added when `sshd` is available; table cells for unavailable process names appear as `-`:

| Detail                                                              | Section    |
| ------------------------------------------------------------------- | ---------- |
| Hardware serial number                                              | `system`   |
| Names of the processes listening on ports                           | `ports`    |
| Effective SSH settings (ports, root login, password authentication) | `security` |

---

## Exit codes

These codes describe recorded collection results:

| Code | Meaning                                                                       |
| ---- | ----------------------------------------------------------------------------- |
| `0`  | Report generated without recorded collection warnings, or help requested      |
| `1`  | Error: missing required command, output file not writable, overwrite declined |
| `2`  | Invalid usage: unknown option or section, missing option value                |
| `3`  | Report produced, but with collection warnings (see `WARNINGS`)                |

Check the command's exit status to distinguish a complete report from collection warnings or a fatal error.

---

## Troubleshooting

| Problem                                                 | Cause and solution                                                                                                                                                                                                                                                                                     |
| ------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `jq: parse error: Invalid numeric literal`              | The text report was piped to `jq`. Add `-J`.                                                                                                                                                                                                                                                           |
| `Error: cannot write 'FILE' ... fs.protected_regular`   | The file is in a sticky directory such as `/tmp` and belongs to another user: the kernel blocks the write even for root. Choose a new filename in a directory owned by the execution account, or correct the existing file ownership and permissions; inspect `sysctl fs.protected_regular` if needed. |
| `Error: 'FILE' already exists; use -f to overwrite it.` | The utility was started without a terminal (cron, systemd). Add `-f`.                                                                                                                                                                                                                                  |
| `Updates available` is `N/A` on RHEL/Fedora             | The dnf/yum metadata cache is missing. Run `dnf makecache` as an administrator, then rerun the inventory (the utility does not refresh the cache).                                                                                                                                                     |
| Update counts look outdated                             | The cache may be old; its directory timestamp is only an approximation. As an administrator, refresh metadata with `apt-get update`, `dnf makecache`, `zypper refresh` or perform the normal full Arch upgrade with `pacman -Syu` (this also installs updates).                                        |
| Hardware fields are `N/A`                               | No DMI data: typical of containers, some ARM boards and some cloud instances.                                                                                                                                                                                                                          |
| `Systemd state : Not running`                           | Systemd is not detected as running. Service counts may be omitted; firewall and SSH labels do not verify independently managed processes.                                                                                                                                                              |
| Exit code 3                                             | Some data could not be collected; the reasons are listed under `Collection warnings` or in `WARNINGS`.                                                                                                                                                                                                 |

---

## Limitations

- Update counts come from the local metadata cache and are only as fresh as the last repository refresh.
- Reboot detection first checks `/var/run/reboot-required`, then compares the running kernel with the newest modules directory by version sorting. That directory may not be the configured boot kernel, and other restart requirements are not exhaustively detected.
- Security updates are not reported on Arch Linux (pacman has no security metadata).
- The firewall field shows which firewall service is active, not the rules; on Ubuntu `ufw.service` can be active while ufw itself is disabled (`ufw status` shows the real state).
- Some commands are not wrapped in `timeout`, and not every missing value generates a warning. A `COMPLETE` report only means no collection warnings were recorded.
- Hostname/FQDN resolution may use DNS. Package-manager operations use local caches, but inventory can still create the requested report and interact with utility state.
- Alpine Linux and BusyBox-only environments are outside the intended compatibility scope.

---

## License

Released under the MIT License. See [LICENSE](LICENSE).
