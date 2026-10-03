#!/usr/bin/env bash
# Simulated kernel/systemd; never touches /etc or the host network.
set -Eeuo pipefail
source "$(dirname "$0")/linux-server-tool.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
BBR_SYSCTL=$work/sysctl/bbr.conf
BBR_MODULES=$work/modules/bbr.conf
BBR_SERVICE=$work/systemd/bbr.service
cc=cubic; qdisc=fq_codel; available='reno cubic'; enabled=no
sysctl() {
    if [[ $1 == -n ]]; then
        case $2 in
            net.ipv4.tcp_available_congestion_control) echo "$available";;
            net.ipv4.tcp_congestion_control) echo "$cc";;
            net.core.default_qdisc) echo "$qdisc";;
        esac
    elif [[ $1 == -w ]]; then cc=bbr; qdisc=fq
    elif [[ $1 == -p ]]; then
        grep -qx 'net.ipv4.tcp_congestion_control = bbr' "$2"
        grep -qx 'net.core.default_qdisc = fq' "$2"
        cc=bbr; qdisc=fq
    else return 1; fi
}
modprobe() { [[ $1 != tcp_bbr ]] || available='reno cubic bbr'; }
systemctl() {
    case $1 in
        enable) enabled=yes;;
        is-enabled) [[ $enabled == yes ]];;
        restart) sysctl -p "$BBR_SYSCTL";;
        daemon-reload) :;;
        *) return 1;;
    esac
}
bbr_enable >/dev/null
[[ $cc == bbr && $qdisc == fq && $enabled == yes ]]
grep -qx 'tcp_bbr' "$BBR_MODULES"
grep -q '^After=.*systemd-sysctl.service procps.service' "$BBR_SERVICE"
grep -qx 'WantedBy=multi-user.target' "$BBR_SERVICE"
cp "$BBR_SYSCTL" "$work/expected"
bbr_enable >/dev/null
cmp "$work/expected" "$BBR_SYSCTL"
# Simulate reboot: an older sysctl configuration wins first, then our boot unit.
cc=cubic; qdisc=fq_codel
systemctl restart lts-tool-bbr.service
[[ $cc == bbr && $qdisc == fq ]]
# Unsupported kernel and denied kernel writes must not save persistent settings.
BBR_SYSCTL=$work/unsupported.conf
available='reno cubic'
modprobe() { return 1; }
if (bbr_enable >/dev/null 2>&1); then exit 1; fi
[[ ! -e $BBR_SYSCTL ]]
available='reno cubic bbr'
modprobe() { return 0; }
sysctl() {
    [[ $1 == -n ]] && { echo 'reno cubic bbr'; return 0; }
    return 1
}
if (bbr_enable >/dev/null 2>&1); then exit 1; fi
[[ ! -e $BBR_SYSCTL ]]
echo 'PASS: BBR enable, idempotency, simulated reboot, unsupported kernel, denied writes'
