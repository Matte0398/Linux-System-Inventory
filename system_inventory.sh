#!/bin/bash

#########################################################################
## Description: Collect and display Linux system inventory information
##              Supports section selection and a JSON output
##
## Author: Matteo Z.
#########################################################################

# Report pipeline failures even when the last command succeeds.
set -o pipefail

# Use the C locale for consistent command output and parsing.
export LC_ALL=C

readonly SCRIPT_VERSION='2.0.0'
readonly REPORT_TITLE='LINUX SYSTEM INFORMATION'
readonly TITLE_COLOR=$'\033[1;32m'
readonly HEADING_COLOR=$'\033[1;36m'
readonly COLOR_RESET=$'\033[0m'
readonly TAB=$'\t'

# Report order: each section is collected by the matching collect_<section> function.
readonly ALL_SECTIONS=(system cpu memory storage network ports services security updates)

# Section title and description, separated by '|'.
declare -A SECTION_INFO=(
    [system]='SYSTEM|Hostname, OS, kernel, uptime, hardware, virtualization, time, users'
    [cpu]='CPU|CPU model, cores, threads, load average'
    [memory]='MEMORY|RAM and swap usage'
    [storage]='STORAGE|Block devices, filesystem and inode usage'
    [network]='NETWORK|Gateways, DNS servers, interfaces'
    [ports]='LISTENING PORTS|Listening TCP/UDP sockets'
    [services]='SERVICES|Systemd state, running and failed units'
    [security]='SECURITY|SELinux, AppArmor, firewall, SSH, admin users'
    [updates]='PACKAGES AND UPDATES|Installed packages, pending/security updates, reboot required'
)

print_usage() {
    cat << EOF
Usage: ${0##*/} [-s LIST] [-x LIST] [-J] [-o FILE [-f]] [-h]

Collect and display Linux system inventory information.

OPTIONS:
    -s LIST    Collect only the listed sections (comma-separated)
    -x LIST    Skip the listed sections (comma-separated)
    -J         Show the output in JSON format (single line)
    -o FILE    Show the report and also save it to FILE (mode 600)
    -f         Overwrite FILE without asking (required when there is no terminal, e.g. cron)
    -h         Show this help message

SECTIONS (default: all):
$(for section in "${ALL_SECTIONS[@]}"; do printf '    %-10s %s\n' "$section" "${SECTION_INFO[$section]#*|}"; done)

EXAMPLES:
    ${0##*/} -s system,cpu,memory
    ${0##*/} -x ports,updates -o /root/inventory.txt
    ${0##*/} -J | jq .                    (-J is required to pipe the output to jq)
    ${0##*/} -J -o /root/host.json -f     (cron: overwrite the previous report)

NOTES:
    Some details (serial number, SSH settings, port owners) require root.
    Colors are disabled when the output is not a terminal or NO_COLOR is set.
    Exit codes: 0 complete, 1 error, 2 invalid usage, 3 completed with collection warnings.
EOF
}


usage_error() {
    printf 'Error: %s\n' "$1" >&2
    printf "Run '%s -h' for usage.\n" "${0##*/}" >&2
    exit 2
}


command_exists() {
    command -v "$1" >/dev/null 2>&1
}


# Return success if VALUE is one of the given items: in_list VALUE ITEM...
in_list() {
    local wanted="$1" item
    shift

    for item in "$@"; do [[ "$item" == "$wanted" ]] && return 0; done

    return 1
}


# Read the first line of a file into REPLY; fails if the file is unreadable or empty.
read_line() {
    REPLY=''
    [[ -r "$1" ]] && { IFS= read -r REPLY < "$1"; } 2>/dev/null
    [[ -n "$REPLY" ]]
}


# Join non-empty, unique standard input lines with a separator.
join_values() {
    awk -v separator="${1:-, }" 'NF && !seen[$0]++ { result = result (result != "" ? separator : "") $0 } END { print result }'
}


# Format a size in KiB as a human-readable binary unit, e.g. 8222320 -> "7.8 GiB".
format_kib() {
    awk -v kib="$1" 'BEGIN {
        split("KiB MiB GiB TiB PiB", unit, " ")
        u = 1
        while (kib >= 1024 && u < 5) { kib /= 1024; u++ }
        if (u == 1) printf "%d %s\n", kib, unit[u]
        else printf "%.1f %s\n", kib, unit[u]
    }'
}


# Print the given systemd units that are currently active.
active_units() {
    local state unit_index=0
    local -a units=("$@")

    while IFS= read -r state; do
        [[ "$state" == active ]] && printf '%s\n' "${units[unit_index]}"

        unit_index=$((unit_index + 1))
    done < <(timeout 10 systemctl is-active "${units[@]}" 2>/dev/null)
}


# Record a collection warning (also printed on standard error in text mode).
warn_collection() {
    warnings+=("$1")

    # In JSON mode the warnings are part of the output itself.
    (( json_output )) || printf 'Warning: %s\n' "$1" >&2
}


# Store a field (or a table when COLUMNS is given) for the current section: add_field KEY LABEL VALUE [COLUMNS].
add_field() {
    item_section+=("$current_section")
    item_key+=("$1")
    item_label+=("$2")
    item_value+=("${3:-}")
    item_columns+=("${4:-}")
}


# Append a tab-separated row to the table variable named by $1 (empty cells become "-").
table_row() {
    local destination="$1" cell row=''
    shift

    for cell in "$@"; do
        cell="${cell//$TAB/ }"

        [[ -z "${cell//[[:space:]]/}" ]] && cell='-'

        row+="${row:+$TAB}$cell"
    done

    printf -v "$destination" '%s%s\n' "${!destination}" "$row"
}


# Capture a command's output into the variable named by $1 (partial output from a command that exits with an error is kept)
capture_information() {
    local destination="$1" description="$2" captured_output status
    shift 2
    printf -v "$destination" '%s' ''

    if ! command_exists "$1"; then
        warn_collection "$description unavailable: command '$1' not found!"
        return 1
    fi

    captured_output="$(timeout 30 "$@" 2>/dev/null)"
    status=$?

    if [[ -z "${captured_output//[[:space:]]/}" ]]; then
        case "$status" in
            0) warn_collection "$description unavailable: command '$1' returned no data!" ;;
            124) warn_collection "$description unavailable: command '$1' timed out!" ;;
            *) warn_collection "$description unavailable: command '$1' failed; check permissions and supported options!" ;;
        esac

        return 1
    fi

    printf -v "$destination" '%s' "$captured_output"
    (( status == 0 )) || warn_collection "$description may be incomplete: command '$1' exited with status $status!"
}


# Print the value of the first "KEY<SEPARATOR>value" line from standard input, without spaces and quotes.
get_value() {
    awk -v prefix="$1$2" 'index($0, prefix) == 1 {
        value = substr($0, length(prefix) + 1)
        gsub(/^[ \t"\047]+|[ \t"\047]+$/, "", value)
        print value
        exit
    }'
}


collect_system() {
    local fqdn='' up_seconds uptime='' boot_epoch boot_time='' dmi_name
    local -A dmi=()
    local virtualization='' in_container=0 boot_mode='' timedatectl_output='' timezone='' ntp='' users=''

    add_field HOSTNAME 'Hostname' "$(uname -n)"

    # 'hostname -f' can block on DNS timeouts, so it runs with a time limit.
    command_exists hostname && fqdn="$(timeout 5 hostname -f 2>/dev/null)"
    add_field FQDN 'FQDN' "$fqdn"

    if [[ -r /etc/os-release ]]; then
        add_field OS 'Operating system' "$(get_value PRETTY_NAME = < /etc/os-release)"
        add_field OS_ID '' "$(get_value ID = < /etc/os-release)"
        add_field OS_VERSION '' "$(get_value VERSION_ID = < /etc/os-release)"
    else
        warn_collection "Operating system information unavailable: cannot read /etc/os-release!"
        add_field OS 'Operating system' ''
    fi

    add_field KERNEL 'Kernel' "$(uname -sr)"
    add_field ARCHITECTURE 'Architecture' "$(uname -m)"

    if read_line /proc/uptime; then
        up_seconds="${REPLY%%.*}"
        uptime="$((up_seconds / 86400)) day(s), $((up_seconds % 86400 / 3600)) hour(s), $((up_seconds % 3600 / 60)) minute(s)"
    else
        warn_collection "Uptime unavailable: cannot read /proc/uptime!"
    fi

    add_field UPTIME 'Uptime' "$uptime"

    boot_epoch="$(awk '$1 == "btime" { print $2; exit }' /proc/stat 2>/dev/null)"

    [[ "$boot_epoch" =~ ^[0-9]+$ ]] && boot_time="$(date -d "@$boot_epoch" '+%Y-%m-%d %H:%M:%S %z')"

    add_field LAST_BOOT 'Last boot' "$boot_time"

    # Hardware data from DMI; firmware placeholders such as "To be filled by O.E.M." are discarded.
    for dmi_name in sys_vendor product_name product_serial; do
        read_line "/sys/class/dmi/id/$dmi_name" || continue

        case "${REPLY,,}" in
            'to be filled by o.e.m.'|'default string'|'not specified'|'none'|'system product name'|'system manufacturer'|'system serial number') ;;
            *) dmi[$dmi_name]="$REPLY" ;;
        esac
    done

    # The serial number file exists but is readable only by root.
    [[ -e /sys/class/dmi/id/product_serial && ! -r /sys/class/dmi/id/product_serial ]] && dmi[product_serial]='Requires root'

    add_field VENDOR 'Vendor' "${dmi[sys_vendor]:-}"
    add_field MODEL 'Model' "${dmi[product_name]:-}"
    add_field SERIAL 'Serial number' "${dmi[product_serial]:-}"

    if command_exists systemd-detect-virt; then
        virtualization="$(systemd-detect-virt 2>/dev/null)"

        [[ "$virtualization" == none ]] && virtualization='None (physical)'

        systemd-detect-virt --container --quiet 2>/dev/null && in_container=1
    fi

    add_field VIRTUALIZATION 'Virtualization' "$virtualization"

    # Inside a container the firmware of the host is not meaningful.
    if (( ! in_container )); then
        [[ -d /sys/firmware/efi ]] && boot_mode='UEFI' || boot_mode='BIOS (legacy)'
    fi

    add_field BOOT_MODE 'Boot mode' "$boot_mode"

    if command_exists timedatectl; then
        timedatectl_output="$(timeout 5 timedatectl show 2>/dev/null)"
        timezone="$(get_value Timezone = <<< "$timedatectl_output")"
        ntp="$(get_value NTPSynchronized = <<< "$timedatectl_output")"
    fi

    if [[ -z "$timezone" && -L /etc/localtime ]]; then
        timezone="$(readlink /etc/localtime)"
        timezone="${timezone##*zoneinfo/}"
    fi

    add_field TIMEZONE 'Time zone' "$timezone"
    add_field NTP_SYNCHRONIZED 'NTP synchronized' "$ntp"

    if command_exists who; then
        users="$(who 2>/dev/null | awk '{ print $1 }' | sort -u | join_values ', ')"
        users="${users:-None}"
    else
        warn_collection "User sessions unavailable: command 'who' not found!"
    fi

    add_field LOGGED_USERS 'Logged-in users' "$users"
}


collect_cpu() {
    local cpu_data threads sockets cores_per_socket threads_per_core cores='' load1 load5 load15

    capture_information cpu_data "CPU information" lscpu
    threads="$(get_value 'CPU(s)' : <<< "$cpu_data")"
    sockets="$(get_value 'Socket(s)' : <<< "$cpu_data")"
    cores_per_socket="$(get_value 'Core(s) per socket' : <<< "$cpu_data")"
    threads_per_core="$(get_value 'Thread(s) per core' : <<< "$cpu_data")"

    if [[ "$sockets" =~ ^[0-9]+$ && "$cores_per_socket" =~ ^[0-9]+$ ]]; then
        cores=$((sockets * cores_per_socket))
    elif [[ "$threads" =~ ^[0-9]+$ && "$threads_per_core" =~ ^[1-9][0-9]*$ ]]; then
        # ARM systems often report clusters instead of sockets.
        cores=$((threads / threads_per_core))
    fi

    add_field MODEL 'CPU model' "$(get_value 'Model name' : <<< "$cpu_data")"
    add_field VENDOR 'Vendor' "$(get_value 'Vendor ID' : <<< "$cpu_data")"
    add_field LOGICAL_CPUS 'Logical CPUs' "$threads"
    add_field CORES 'Physical cores' "$cores"
    add_field SOCKETS 'Sockets' "$sockets"
    add_field THREADS_PER_CORE 'Threads per core' "$threads_per_core"

    if [[ -r /proc/loadavg ]] && read -r load1 load5 load15 _ < /proc/loadavg; then
        add_field LOAD_AVERAGE 'Load average' "$load1, $load5, $load15 (1, 5, 15 min)"
    else
        warn_collection "Load average unavailable: cannot read /proc/loadavg!"
        add_field LOAD_AVERAGE 'Load average' ''
    fi
}


collect_memory() {
    local mem_total mem_available swap_total swap_free mem_used swap_used swap=''

    if [[ ! -r /proc/meminfo ]]; then
        warn_collection "Memory information unavailable: cannot read /proc/meminfo!"
        return
    fi

    read -r mem_total mem_available swap_total swap_free < <(awk '
        $1 == "MemTotal:" { total = $2 }
        $1 == "MemAvailable:" { available = $2 }
        $1 == "SwapTotal:" { swap_total = $2 }
        $1 == "SwapFree:" { swap_free = $2 }
        END { print total + 0, available + 0, swap_total + 0, swap_free + 0 }' /proc/meminfo)

    if (( mem_total <= 0 )); then
        warn_collection "Memory information is incomplete or unsupported!"
        return
    fi

    mem_used=$((mem_total - mem_available))
    swap_used=$((swap_total - swap_free))

    if (( swap_total > 0 )); then
        swap="$(format_kib "$swap_used") used / $(format_kib "$swap_total") total ($((swap_used * 100 / swap_total))%)"
    else
        swap='Not configured'
    fi

    add_field TOTAL 'RAM total' "$(format_kib "$mem_total")"
    add_field USED 'RAM used' "$(format_kib "$mem_used") ($((mem_used * 100 / mem_total))%)"
    add_field AVAILABLE 'RAM available' "$(format_kib "$mem_available") ($((mem_available * 100 / mem_total))%)"
    add_field SWAP 'Swap' "$swap"
}


collect_storage() {
    local block_data='' block_rows='' fs_data='' inode_data='' fs_rows=''

    # Exclude RAM disks (major 1) and loop devices (major 7); -P prints KEY="value" pairs.
    if capture_information block_data "Block devices" lsblk -P -e 1,7 -o NAME,TYPE,FSTYPE,SIZE,MOUNTPOINT,MODEL; then
        block_rows="$(awk '{
            line = $0; row = ""; count = 0
            while (match(line, /[A-Z:%-]+="[^"]*"/)) {
                value = substr(line, RSTART, RLENGTH)
                sub(/^[^=]*="/, "", value); sub(/"$/, "", value); gsub(/^ +| +$/, "", value)
                row = row (count++ ? "\t" : "") (value == "" ? "-" : value)
                line = substr(line, RSTART + RLENGTH)
            }
            print row
        }' <<< "$block_data")"$'\n'
    fi

    add_field BLOCK_DEVICES 'Block devices' "$block_rows" 'NAME TYPE FSTYPE SIZE MOUNTPOINT MODEL'

    capture_information fs_data "Filesystem usage" df -kPT
    inode_data="$(timeout 30 df -iP 2>/dev/null)"

    if [[ -n "$fs_data" ]]; then
        fs_rows="$(awk '
            function human(kib) {
                split("KiB MiB GiB TiB PiB", unit, " ")
                u = 1
                while (kib >= 1024 && u < 5) { kib /= 1024; u++ }
                return (u == 1) ? sprintf("%d %s", kib, unit[u]) : sprintf("%.1f %s", kib, unit[u])
            }
            BEGIN {
                count = split("tmpfs devtmpfs squashfs efivarfs ramfs nsfs proc sysfs cgroup cgroup2 devpts mqueue tracefs debugfs securityfs pstore bpf autofs configfs fusectl binfmt_misc hugetlbfs rpc_pipefs fuse.gvfsd-fuse fuse.portal", list, " ")
                for (i = 1; i <= count; i++) skip[list[i]] = 1
            }
            FILENAME == ARGV[1] {
                if (FNR > 1) { mount = $6; for (i = 7; i <= NF; i++) mount = mount " " $i; inode[mount] = $5 }
                next
            }
            FNR == 1 { next }
            {
                mount = $7; for (i = 8; i <= NF; i++) mount = mount " " $i
                if ($2 in skip || $3 !~ /^[0-9]+$/ || $3 == 0 || seen[mount]++) next
                # Container roots are overlays; other overlay mounts are usually duplicates.
                if ($2 == "overlay" && mount != "/") next
                inode_use = (inode[mount] ~ /^[0-9]+%$/) ? inode[mount] : "-"
                printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", mount, $2, human($3), human($4), human($5), $6, inode_use, $1
            }' <(printf '%s\n' "$inode_data") <(printf '%s\n' "$fs_data"))"
    fi

    add_field FILESYSTEMS 'Filesystem usage' "${fs_rows:+$fs_rows$'\n'}" 'MOUNT TYPE SIZE USED AVAIL USE IUSE SOURCE'
}


collect_network() {
    local dns='' dns_search='' upstream gateways='' family route_output address_lines='' rows=''
    local interface_dir interface mac state mtu family address
    local -A ipv4=() ipv6=()
    local stub_pattern='^127\.0\.0\.5[34](, 127\.0\.0\.5[34])*$'

    if [[ -r /etc/resolv.conf ]]; then
        dns="$(awk '$1 == "nameserver" { print $2 }' /etc/resolv.conf | join_values ', ')"
        dns_search="$(awk '$1 == "search" || $1 == "domain" { for (i = 2; i <= NF; i++) print $i }' /etc/resolv.conf | join_values ', ')"
    else
        warn_collection "DNS configuration unavailable: cannot read /etc/resolv.conf!"
    fi

    if [[ "$dns" =~ $stub_pattern ]] && command_exists resolvectl; then
        upstream="$(timeout 5 resolvectl dns 2>/dev/null | awk '{ sub(/^[^:]*:[ \t]*/, ""); for (i = 1; i <= NF; i++) print $i }' | join_values ', ')"

        [[ -n "$upstream" ]] && dns="$upstream (via systemd-resolved)"
    fi

    if command_exists ip; then
        for family in 4 6; do
            route_output="$(ip "-$family" route show default 2>/dev/null)"
            gateways+="$(awk '{
                via = ""; dev = ""
                for (i = 1; i < NF; i++) { if ($i == "via") via = $(i + 1); if ($i == "dev") dev = $(i + 1) }
                if (via != "") print via (dev != "" ? " (" dev ")" : "")
            }' <<< "$route_output")"$'\n'
        done

        gateways="$(printf '%s' "$gateways" | join_values ', ')"
        gateways="${gateways:-None}"
        capture_information address_lines "Interface addresses" ip -o addr show
    else
        warn_collection "Gateways and addresses unavailable: command 'ip' not found!"
    fi

    while read -r _ interface family address _; do
        interface="${interface%%@*}"

        case "$family" in
            inet) ipv4[$interface]+="${ipv4[$interface]:+, }$address" ;;
            inet6) ipv6[$interface]+="${ipv6[$interface]:+, }$address" ;;
        esac
    done <<< "$address_lines"

    for interface_dir in /sys/class/net/*; do
        [[ -d "$interface_dir" ]] || continue

        interface="${interface_dir##*/}"
        mac=''; state=''; mtu=''
        read_line "$interface_dir/address" && mac="$REPLY"
        read_line "$interface_dir/operstate" && state="$REPLY"
        read_line "$interface_dir/mtu" && mtu="$REPLY"
        table_row rows "$interface" "$state" "$mac" "$mtu" "${ipv4[$interface]:-}" "${ipv6[$interface]:-}"
    done

    add_field DEFAULT_GATEWAY 'Default gateway' "$gateways"
    add_field DNS_SERVERS 'DNS servers' "$dns"
    add_field DNS_SEARCH 'DNS search' "$dns_search"
    add_field INTERFACES 'Interfaces' "$rows" 'INTERFACE STATE MAC MTU IPV4 IPV6'
}


collect_ports() {
    local raw='' rows='' options='-tuln'

    # Process names are only visible to root.
    (( is_root )) && options='-tulnp'

    if capture_information raw "Listening sockets" ss "$options"; then
        rows="$(awk '
            $1 == "Netid" || NF < 5 { next }
            {
                protocol = $1; local_address = $5; process = "-"
                if (NF >= 7 && match($0, /users:\(\("[^"]+"/)) process = substr($0, RSTART + 9, RLENGTH - 10)
                port = local_address; sub(/.*:/, "", port)
                address = local_address; sub(/:[^:]*$/, "", address); gsub(/^\[|\]$/, "", address)
                if (seen[protocol SUBSEP address SUBSEP port]++) next
                printf "%s\t%s\t%s\t%s\n", protocol, (address == "" ? "*" : address), port, process
            }' <<< "$raw" | sort -t "$TAB" -k3,3n -k1,1)"
    fi

    add_field LISTENING_SOCKETS 'Listening sockets' "$(awk 'NF { count++ } END { print count + 0 }' <<< "$rows")"

    (( is_root )) || add_field PROCESS_NAMES 'Process names' 'Requires root'

    add_field SOCKETS 'Sockets' "${rows:+$rows$'\n'}" 'PROTO ADDRESS PORT PROCESS'
}


collect_services() {
    local state running failed_output rows='' failed_count=0 unit sub_state description

    if (( ! has_systemd )); then
        add_field SYSTEMD_STATE 'Systemd state' 'Not running'
        return
    fi

    # States such as degraded or offline legitimately return nonzero.
    state="$(timeout 10 systemctl is-system-running 2>/dev/null)"

    case "$state" in
        running|initializing|starting|degraded|maintenance|stopping|offline) ;;
        *) warn_collection "Systemd state lookup failed!"; state='' ;;
    esac

    add_field SYSTEMD_STATE 'Systemd state' "$state"

    running="$(timeout 10 systemctl list-units --type=service --state=running --no-legend --plain --no-pager 2>/dev/null | awk 'NF { count++ } END { print count + 0 }')" || \
        { warn_collection "Running services lookup failed!"; running=''; }
    add_field RUNNING_SERVICES 'Running services' "$running"

    if failed_output="$(timeout 10 systemctl list-units --state=failed --no-legend --plain --no-pager 2>/dev/null)"; then
        while read -r unit _ _ sub_state description; do
            [[ -n "$unit" ]] || continue

            failed_count=$((failed_count + 1))
            table_row rows "$unit" "$sub_state" "$description"
        done <<< "$failed_output"

        add_field FAILED_UNITS_COUNT 'Failed units' "$failed_count"
        add_field FAILED_UNITS 'Failed units list' "$rows" 'UNIT STATE DESCRIPTION'
    else
        warn_collection "Failed units lookup failed!"
        add_field FAILED_UNITS_COUNT 'Failed units' ''
    fi
}


collect_security() {
    local selinux='Not available' apparmor='Not available' firewall='' ssh_server='Not installed' sshd_settings admins=''

    if command_exists getenforce; then
        selinux="$(getenforce 2>/dev/null)"
    elif read_line /sys/fs/selinux/enforce; then
        [[ "$REPLY" == 1 ]] && selinux='Enforcing' || selinux='Permissive'
    fi

    if read_line /sys/module/apparmor/parameters/enabled; then
        [[ "$REPLY" == Y ]] && apparmor='Enabled' || apparmor='Disabled'
    fi

    # Note: ufw.service may be active even when the ufw rules are disabled ('ufw status' as root).
    (( has_systemd )) && firewall="$(active_units firewalld ufw nftables netfilter-persistent iptables | join_values ', ')"

    add_field SELINUX 'SELinux' "$selinux"
    add_field APPARMOR 'AppArmor' "$apparmor"
    add_field FIREWALL 'Firewall service' "${firewall:-None detected}"

    if command_exists sshd; then
        ssh_server='Not running'
        (( has_systemd )) && [[ -n "$(active_units ssh sshd)" ]] && ssh_server='Running'
    fi

    add_field SSH_SERVER 'SSH server' "$ssh_server"

    if command_exists sshd && (( is_root )); then
        sshd_settings="$(timeout 5 sshd -T 2>/dev/null)"
        add_field SSH_PORTS 'SSH port(s)' "$(awk '$1 == "port" { print $2 }' <<< "$sshd_settings" | join_values ', ')"
        add_field SSH_ROOT_LOGIN 'SSH root login' "$(awk '$1 == "permitrootlogin" { print $2; exit }' <<< "$sshd_settings")"
        add_field SSH_PASSWORD_AUTH 'SSH password auth' "$(awk '$1 == "passwordauthentication" { print $2; exit }' <<< "$sshd_settings")"
    elif command_exists sshd; then
        add_field SSH_SETTINGS 'SSH settings' 'Requires root'
    fi

    command_exists getent && admins="$(getent group sudo wheel admin 2>/dev/null | awk -F: '{ count = split($4, member, ","); for (i = 1; i <= count; i++) print member[i] }' | sort -u | join_values ', ')"

    add_field ADMIN_USERS 'Admin group members' "${admins:-None}"
    admins="$(awk -F: '$3 == 0 && $1 != "root" { print $1 }' /etc/passwd 2>/dev/null | join_values ', ')"
    add_field OTHER_UID0_USERS 'Other UID 0 users' "${admins:-None}"
}


collect_updates() {
    local package_manager='' manager installed='' available='' security='' metadata_path='' metadata='' output modified days
    local reboot='' modules_dir=/lib/modules running_kernel newest_kernel

    if command_exists apt-get && [[ -f /var/lib/dpkg/status ]]; then
        package_manager='apt'
    else
        for manager in dnf yum zypper pacman; do
            command_exists "$manager" && { package_manager="$manager"; break; }
        done
    fi

    # Updates are read from the local metadata cache: the repositories are never contacted.
    case "$package_manager" in
        apt)
            installed="$(dpkg-query -W -f '${Status}\n' 2>/dev/null | awk '$NF == "installed" { count++ } END { print count + 0 }')"

            if output="$(timeout 120 apt-get -s -o Debug::NoLocking=1 dist-upgrade 2>/dev/null)"; then
                available="$(awk '/^Inst / && /\[/ { count++ } END { print count + 0 }' <<< "$output")"
                security="$(awk '/^Inst / && /\[/ && /-security/ { count++ } END { print count + 0 }' <<< "$output")"
            else
                warn_collection "Pending updates unavailable: 'apt-get -s dist-upgrade' failed!"
            fi

            metadata_path=/var/lib/apt/lists ;;
        dnf|yum)
            installed="$(rpm -qa 2>/dev/null | awk 'END { print NR }')"
            output="$(timeout 120 "$package_manager" -q -C check-update 2>/dev/null)"

            case $? in
                0) available=0 ;;
                100) available="$(awk '/^(Obsoleting|Security:)/ { exit } NF == 3 && $1 ~ /\./ { count++ } END { print count + 0 }' <<< "$output")" ;;
                *) warn_collection "Pending updates unavailable: the $package_manager metadata cache may be missing (run '$package_manager makecache')!" ;;
            esac

            if [[ -n "$available" ]] && output="$(timeout 120 "$package_manager" -q -C updateinfo list --security 2>/dev/null)"; then
                security="$(awk 'NF >= 3 { count++ } END { print count + 0 }' <<< "$output")"
            fi

            metadata_path="/var/cache/$package_manager" ;;
        zypper)
            installed="$(rpm -qa 2>/dev/null | awk 'END { print NR }')"

            if output="$(timeout 120 zypper --non-interactive --no-refresh list-updates 2>/dev/null)"; then
                available="$(awk '/^v / { count++ } END { print count + 0 }' <<< "$output")"
            else
                warn_collection "Pending updates unavailable: 'zypper list-updates' failed!"
            fi

            if output="$(timeout 120 zypper --non-interactive --no-refresh list-patches --category security 2>/dev/null)"; then
                security="$(awk '/\| *needed *\|/ { count++ } END { print count + 0 }' <<< "$output")"
            fi

            metadata_path=/var/cache/zypp/raw ;;
        pacman)
            installed="$(pacman -Qq 2>/dev/null | awk 'END { print NR }')"
            # pacman -Qu exits 1 when there is nothing to upgrade.
            available="$(pacman -Qu 2>/dev/null | awk 'NF { count++ } END { print count + 0 }')"
            metadata_path=/var/lib/pacman/sync ;;
        *)
            warn_collection "Package information unavailable: no supported package manager found!" ;;
    esac

    if [[ -e "$metadata_path" ]] && modified="$(stat -c %Y "$metadata_path" 2>/dev/null)"; then
        days=$(( ($(date +%s) - modified) / 86400 ))
        metadata="Updated $days day(s) ago"
        (( days > 7 )) && metadata+=' (update counts may be outdated)'
    fi

    [[ -d "$modules_dir" ]] || modules_dir=/usr/lib/modules
    running_kernel="$(uname -r)"

    if [[ -f /var/run/reboot-required ]]; then
        reboot='Yes'
    elif compgen -G "$modules_dir/*" >/dev/null; then
        newest_kernel="$(printf '%s\n' "$modules_dir"/* | awk -F/ '{ print $NF }' | sort -V | tail -n 1)"

        if [[ ! -d "$modules_dir/$running_kernel" ]]; then
            reboot="Yes (modules of running kernel $running_kernel are missing)"
        elif [[ "$newest_kernel" != "$running_kernel" ]]; then
            reboot="Yes (running $running_kernel, newest installed $newest_kernel)"
        else
            reboot='No'
        fi
    fi

    add_field PACKAGE_MANAGER 'Package manager' "$package_manager"
    add_field INSTALLED_PACKAGES 'Installed packages' "$installed"
    add_field UPDATES_AVAILABLE 'Updates available' "$available"
    add_field SECURITY_UPDATES 'Security updates' "$security"
    add_field PACKAGE_METADATA 'Package metadata' "$metadata"
    add_field REBOOT_REQUIRED 'Reboot required' "$reboot"
}


print_field() {
    local value="$2"
    [[ -z "${value//[[:space:]]/}" ]] && value='N/A'
    printf '%-20s: %s\n' "$1" "$value"
}

# Print the header and the tab-separated rows as aligned columns.
print_table() {
    [[ -n "$2" ]] || { printf 'None\n'; return; }

    printf '%s\n%s' "${1// /$TAB}" "$2" | awk -F '\t' '
        {
            rows = NR
            if (NF > columns) columns = NF
            for (i = 1; i <= NF; i++) { cell[NR, i] = $i; if (length($i) > width[i]) width[i] = length($i) }
        }
        END {
            for (r = 1; r <= rows; r++) {
                line = ""
                for (i = 1; i < columns; i++) line = line sprintf("%-" width[i] "s  ", cell[r, i])
                print line cell[r, columns]
            }
        }'
}


print_report() {
    local section index warning printed status='Complete'

    printf '%s\n' "$REPORT_TITLE"
    print_field 'Generated' "$generated_at"
    print_field 'Sections' "$(printf '%s\n' "${selected_sections[@]}" | join_values ', ')"

    for section in "${selected_sections[@]}"; do
        printf '\n[ %s ]\n%s\n' "${SECTION_INFO[$section]%%|*}" '------------------------------------------------------------'
        printed=0

        for index in "${!item_key[@]}"; do
            [[ "${item_section[index]}" == "$section" ]] || continue

            if [[ -n "${item_columns[index]}" ]]; then
                (( printed )) && printf '\n'
                printf '%s:\n' "${item_label[index]}"
                print_table "${item_columns[index]}" "${item_value[index]}"
            elif [[ -n "${item_label[index]}" ]]; then
                print_field "${item_label[index]}" "${item_value[index]}"
            else
                continue
            fi

            printed=1
        done
    done

    printf '\n[ SUMMARY ]\n%s\n' '------------------------------------------------------------'
    print_field 'Collection warnings' "${#warnings[@]}"

    for warning in "${warnings[@]}"; do
        printf '  - %s\n' "$warning"
    done

    (( ${#warnings[@]} > 0 )) && status='Incomplete report (see collection warnings)'
    print_field 'Status' "$status"
}


colorize_report() {
    local line

    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            "$REPORT_TITLE") printf '%s%s%s\n' "$TITLE_COLOR" "$line" "$COLOR_RESET" || return 1 ;;
            '[ '*' ]') printf '%s%s%s\n' "$HEADING_COLOR" "$line" "$COLOR_RESET" || return 1 ;;
            *) printf '%s\n' "$line" || return 1 ;;
        esac
    done
}


json_escape() {
    local input="$1"
    input="${input//\\/\\\\}"
    input="${input//\"/\\\"}"
    input="${input//$'\n'/\\n}"
    input="${input//$'\r'/\\r}"
    input="${input//$'\t'/\\t}"
    input="${input//[[:cntrl:]]/}"
    printf '%s' "$input"
}

# Convert a table into a list of JSON objects whose keys are the column names.
json_table() {
    local line index value object objects=''
    local -a headers cells
    read -r -a headers <<< "$1"

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue

        IFS="$TAB" read -r -a cells <<< "$line"
        object=''

        for index in "${!headers[@]}"; do
            value="${cells[index]:-}"

            [[ "$value" == '-' ]] && value=''

            object+="${object:+,}\"${headers[index]}\":\"$(json_escape "$value")\""
        done

        objects+="${objects:+,}{$object}"
    done <<< "$2"

    printf '%s' "$objects"
}


json_output() {
    local section index members json warning list='' status='COMPLETE'

    json="{\"REPORT\":{\"TITLE\":\"$REPORT_TITLE\",\"VERSION\":\"$SCRIPT_VERSION\""
    json+=",\"GENERATED\":\"$(json_escape "$generated_at")\""
    json+=",\"SECTIONS\":\"$(printf '%s\n' "${selected_sections[@]}" | join_values ',')\"}"

    for section in "${selected_sections[@]}"; do
        members=''

        for index in "${!item_key[@]}"; do
            [[ "${item_section[index]}" == "$section" ]] || continue

            if [[ -n "${item_columns[index]}" ]]; then
                members+="${members:+,}\"${item_key[index]}\":[$(json_table "${item_columns[index]}" "${item_value[index]}")]"
            else
                members+="${members:+,}\"${item_key[index]}\":\"$(json_escape "${item_value[index]}")\""
            fi
        done

        json+=",\"${section^^}\":{$members}"
    done

    for warning in "${warnings[@]}"; do
        list+="${list:+,}\"$(json_escape "$warning")\""
    done

    (( ${#warnings[@]} > 0 )) && status='INCOMPLETE'

    json+=",\"WARNINGS\":[$list],\"STATUS\":\"$status\"}"
    printf '%s\n' "$json"
}


# Check that the output file (-o) is writable and ask before overwriting it, unless -f is given.
check_output_file() {
    local directory answer
    directory="$(dirname -- "$output_file")"

    [[ -d "$output_file" ]] && { printf "Error: '%s' is a directory!\n" "$output_file" >&2; exit 1; }
    [[ -d "$directory" ]] || { printf "Error: directory '%s' does not exist!\n" "$directory" >&2; exit 1; }

    if [[ ! -e "$output_file" ]]; then
        [[ -w "$directory" ]] || { printf "Error: cannot create files in '%s'!\n" "$directory" >&2; exit 1; }
        return
    fi

    # Try to open the file for writing without changing it (detects cases that [[ -w ]] misses, even for root).
    if ! { : >> "$output_file"; } 2>/dev/null; then
        printf "Error: cannot write '%s'; check permissions and owner (files of other users in /tmp are protected by fs.protected_regular).\n" "$output_file" >&2
        exit 1
    fi

    if (( ! force_overwrite )); then
        # Without a terminal (cron, systemd timers) nobody can answer: stop instead of waiting.
        if ! { : < /dev/tty; } 2>/dev/null; then
            printf "Error: '%s' already exists; use -f to overwrite it.\n" "$output_file" >&2
            exit 1
        fi

        # The question is asked on the terminal, so it also works with '| jq' or '> file'.
        read -r -p "File '$output_file' already exists. Overwrite? [y/N] " answer < /dev/tty

        case "${answer,,}" in
            y|yes|s|si) ;;
            *) printf 'Aborted: the existing file was not modified.\n' >&2; exit 1 ;;
        esac
    fi

    # umask only applies to new files: make an overwritten report private as well.
    chmod 600 -- "$output_file" 2>/dev/null
}


# Validate a comma-separated section list (-s / -x) and store it in parsed_sections.
parse_section_list() {
    local item
    local -a items
    parsed_sections=()
    IFS=',' read -r -a items <<< "${1,,}"

    for item in "${items[@]}"; do
        item="${item//[[:space:]]/}"
        [[ -n "$item" ]] || continue
        in_list "$item" "${ALL_SECTIONS[@]}" || usage_error "unknown section: $item (use -h to list them)"
        parsed_sections+=("$item")
    done

    (( ${#parsed_sections[@]} > 0 )) || usage_error "empty section list"
}


########## MAIN ##########

item_section=() item_key=() item_label=() item_value=() item_columns=()
warnings=() parsed_sections=() excluded_sections=()
base_sections=("${ALL_SECTIONS[@]}")
current_section=''
json_output=0
output_file=''
force_overwrite=0
is_root=0
(( EUID == 0 )) && is_root=1

while getopts ':s:x:Jo:fh' option; do
    case "$option" in
        s) parse_section_list "$OPTARG"; base_sections=("${parsed_sections[@]}") ;;
        x) parse_section_list "$OPTARG"; excluded_sections+=("${parsed_sections[@]}") ;;
        J) json_output=1 ;;
        o) output_file="$OPTARG" ;;
        f) force_overwrite=1 ;;
        h) print_usage; exit 0 ;;
        :) usage_error "option -$OPTARG requires a value" ;;
        *) usage_error "unknown option: -$OPTARG" ;;
    esac
done

shift $((OPTIND - 1))
(( $# == 0 )) || usage_error "unexpected argument: $1"

selected_sections=()

for section in "${ALL_SECTIONS[@]}"; do
    in_list "$section" "${base_sections[@]}" || continue
    in_list "$section" "${excluded_sections[@]}" && continue
    selected_sections+=("$section")
done

(( ${#selected_sections[@]} > 0 )) || usage_error "all sections were excluded"

# timeout keeps a hung command (DNS, D-Bus, package manager) from blocking the report.
required_commands=(awk sort timeout)

[[ -n "$output_file" ]] && required_commands+=(tee)

for required_command in "${required_commands[@]}"; do
    if ! command_exists "$required_command"; then
        printf 'Error: required command not found: %s\n' "$required_command" >&2
        exit 1
    fi
done

[[ -n "$output_file" ]] && check_output_file

use_color=0

(( ! json_output )) && [[ -t 1 && "${TERM:-dumb}" != dumb && -z "${NO_COLOR:-}" ]] && use_color=1

generated_at="$(date '+%Y-%m-%d %H:%M:%S %z')"

# systemctl may exist without systemd running (containers): check it once for all sections.
has_systemd=0

command_exists systemctl && [[ -d /run/systemd/system ]] && has_systemd=1

for current_section in "${selected_sections[@]}"; do
    "collect_$current_section"
done

report_writer=print_report

(( json_output )) && report_writer=json_output

output_status=0

if [[ -n "$output_file" ]]; then
    # New inventory reports are private because they contain host and network data.
    umask 077

    if (( use_color )); then
        "$report_writer" | tee -- "$output_file" | colorize_report || output_status=$?
    else
        "$report_writer" | tee -- "$output_file" || output_status=$?
    fi
elif (( use_color )); then
    "$report_writer" | colorize_report || output_status=$?
else
    "$report_writer" || output_status=$?
fi

if (( output_status != 0 )); then
    printf 'Error: unable to output the report; check the destination and permissions.\n' >&2
    exit 1
fi

(( ${#warnings[@]} > 0 )) && exit 3

exit 0