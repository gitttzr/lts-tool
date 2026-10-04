#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/linux-server-tool.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/netplan"
cat > "$work/netplan/50-cloud-init.yaml" <<'EOF'
network:
  version: 2
  ethernets:
    eth0:
      match: {macaddress: '00:16:3e:12:34:56'}
      set-name: eth0
      dhcp4: true
      dhcp6: true
      dhcp4-overrides: {route-metric: 100}
      dhcp6-overrides: {route-metric: 100}
      nameservers: {addresses: [100.100.2.136], search: [internal.example]}
      routes: [{to: 192.0.2.0/24, via: 10.0.0.1}]
EOF
netplan_write_dns "$work/netplan" '223.5.5.5 223.6.6.6'
/usr/bin/python3 - "$work/netplan/50-cloud-init.yaml" <<'PY'
import sys, yaml
c = yaml.safe_load(open(sys.argv[1]))['network']['ethernets']['eth0']
assert c['dhcp4'] and c['dhcp6']
assert c['nameservers']['addresses'] == ['223.5.5.5', '223.6.6.6']
assert c['nameservers']['search'] == ['internal.example']
assert c['dhcp4-overrides'] == {'route-metric': 100, 'use-dns': False}
assert c['dhcp6-overrides']['use-dns'] is False
assert c['routes'][0]['via'] == '10.0.0.1'
assert c['match']['macaddress'] == '00:16:3e:12:34:56'
PY
cp "$work/netplan/50-cloud-init.yaml" "$work/expected"
netplan_write_dns "$work/netplan" '223.5.5.5 223.6.6.6'
cmp "$work/expected" "$work/netplan/50-cloud-init.yaml"
if command -v netplan >/dev/null; then
    mkdir -p "$work/root/etc/netplan"
    cp "$work/netplan/50-cloud-init.yaml" "$work/root/etc/netplan/"
    netplan generate --root-dir "$work/root"
    grep -qx 'DNS=223.5.5.5' "$work/root/run/systemd/network/10-netplan-eth0.network"
    grep -qx 'UseDNS=false' "$work/root/run/systemd/network/10-netplan-eth0.network"
fi
systemctl() { return 1; }
timeout() { return 0; }
dns_addresses() { echo 100.100.2.136; }
if dns_verify_safe; then exit 1; fi
dns_addresses() { :; }
if dns_verify_safe; then exit 1; fi
dns_addresses() { echo 127.0.0.53; }
if dns_verify_safe; then exit 1; fi
dns_addresses() { echo 223.5.5.5; }
dns_verify_safe
timeout() { return 1; }
if dns_verify_safe; then exit 1; fi
# The installer must stop before downloads even when called from a conditional.
curl() { touch "$work/download-started"; return 1; }
dns_check() { return 1; }
if (tailscale_install) >/dev/null 2>&1; then exit 1; fi
[[ ! -e $work/download-started ]]
dns_check() { return 0; }
timeout() { return 0; }
dns_addresses() { echo 100.100.2.136; }
if (tailscale_install) >/dev/null 2>&1; then exit 1; fi
[[ ! -e $work/download-started ]]
echo 'PASS: Netplan DNS persistence, DHCP/routes preserved, idempotency, conflict/unknown/resolution fail-closed preflight'
(
    attempt=0
    dns_has_conflict() { ((attempt+=1)); ((attempt < 3)) && return 2; return 1; }
    sleep() { :; }
    dns_verify_safe() { [[ $attempt == 3 ]]; }
    dns_wait_safe
)
(
    systemctl() { return 0; }
    ip() { echo 'default via 10.0.0.1 dev eth0'; }
    netplan() { [[ $1 == apply ]]; }
    networkctl() { echo "$*" >> "$work/networkctl"; }
    networkd_dns_override() { [[ $1 == eth0 && $2 == '223.5.5.5 223.6.6.6' ]]; }
    resolvectl() { [[ $* == 'dns eth0 223.5.5.5 223.6.6.6' ]]; }
    timeout() { shift; [[ $1 != 60s ]] || shift; "$@"; }
    dns_wait_safe() { :; }
    netplan_apply_dns '223.5.5.5 223.6.6.6' "$work"
    [[ $(sed -n '1p' "$work/networkctl") == reload ]]
    [[ $(sed -n '2p' "$work/networkctl") == 'reconfigure eth0' ]]
)
echo 'PASS: asynchronous DNS wait and explicit networkd uplink reconfiguration'
(
    NETWORKD_CONFIG=$work/networkd
    networkctl() { echo 'Network File: /run/systemd/network/10-netplan-eth0.network'; }
    printf '#!/bin/bash\nset -eu\n' > "$work/restore.sh"
    networkd_dns_override eth0 '223.5.5.5 223.6.6.6' "$work"
    cfg=$NETWORKD_CONFIG/10-netplan-eth0.network.d/90-lts-tool-dns.conf
    grep -qx 'DNS=223.5.5.5' "$cfg"
    grep -qx 'DNS=' "$cfg"
    grep -qx 'UseDNS=false' "$cfg"
    grep -q 'resolvectl revert eth0' "$work/restore.sh"
    networkctl() { echo 'Network File: /etc/systemd/network/unrelated.network'; }
    if networkd_dns_override eth0 '223.5.5.5' "$work"; then exit 1; fi
)
echo 'PASS: persistent loaded-file DNS override, rollback and unsupported-file refusal'
netplan_auto_dns "$work/netplan"
/usr/bin/python3 - "$work/netplan/50-cloud-init.yaml" <<'PY'
import sys, yaml
c = yaml.safe_load(open(sys.argv[1]))['network']['ethernets']['eth0']
assert c['dhcp4'] and c['dhcp6']
assert 'addresses' not in c['nameservers']
assert c['nameservers']['search'] == ['internal.example']
assert c['dhcp4-overrides'] == {'route-metric': 100, 'use-dns': True}
assert c['dhcp6-overrides']['use-dns'] is True
assert c['routes'][0]['via'] == '10.0.0.1'
PY
cp "$work/netplan/50-cloud-init.yaml" "$work/auto-expected"
netplan_auto_dns "$work/netplan"
cmp "$work/auto-expected" "$work/netplan/50-cloud-init.yaml"
if command -v netplan >/dev/null; then
    cp "$work/netplan/50-cloud-init.yaml" "$work/root/etc/netplan/"
    netplan generate --root-dir "$work/root"
    ! grep -q '^DNS=' "$work/root/run/systemd/network/10-netplan-eth0.network"
    ! grep -qx 'UseDNS=false' "$work/root/run/systemd/network/10-netplan-eth0.network"
fi
mkdir "$work/static"
printf 'network:\n  version: 2\n  ethernets:\n    eth0:\n      dhcp4: false\n      addresses: [192.0.2.1/24]\n' > "$work/static/static.yaml"
cp "$work/static/static.yaml" "$work/static-original"
if netplan_auto_dns "$work/static" 2>/dev/null; then exit 1; fi
cmp "$work/static-original" "$work/static/static.yaml"
echo 'PASS: restore DHCP DNS, preserve routing/search, repeat safely, generated config, refuse static-only setup'
(
    mkdir -p "$work/sys/eth0" "$work/leases"
    echo 2 > "$work/sys/eth0/ifindex"
    echo 'DNS=100.100.2.136 100.100.2.138' > "$work/leases/2"
    resolvectl() { echo 'Link 2 (eth0): 119.29.29.29 223.5.5.5'; }
    if dhcp_dns_verified eth0 "$work/leases" "$work/sys"; then exit 1; fi
    resolvectl() { echo 'Link 2 (eth0): 100.100.2.138 100.100.2.136'; }
    dhcp_dns_verified eth0 "$work/leases" "$work/sys"
    rm "$work/leases/2"
    if dhcp_dns_verified eth0 "$work/leases" "$work/sys"; then exit 1; fi
)
echo 'PASS: default DNS must match actual DHCP lease, stale public DNS and missing lease rejected'
(
    echo 'DNS=100.100.2.136 100.100.2.138' > "$work/leases/2"
    timeout() { shift; "$@"; }
    resolvectl() { [[ $* == 'dns eth0 100.100.2.136 100.100.2.138' ]]; }
    dhcp_dns_refresh eth0 "$work/leases" "$work/sys"
    echo 'DNS=invalid' > "$work/leases/2"
    if dhcp_dns_refresh eth0 "$work/leases" "$work/sys"; then exit 1; fi
)
echo 'PASS: refresh link DNS from actual lease, reject invalid lease addresses'
(
    NETPLAN_RUNTIME=$work/generated
    netplan() {
        [[ $(umask) == 0022 ]]
        mkdir -p "$NETPLAN_RUNTIME"
        echo '[Network]' > "$NETPLAN_RUNTIME/10-netplan-eth0.network"
        chmod 600 "$NETPLAN_RUNTIME/10-netplan-eth0.network"
    }
    chown() { [[ $1 == root:systemd-network ]]; }
    runuser() { [[ $(stat -c %a "$NETPLAN_RUNTIME/10-netplan-eth0.network") == 640 ]]; }
    umask 077
    netplan_generate
    [[ $(stat -c %a "$NETPLAN_RUNTIME") == 755 ]]
    [[ $(stat -c %a "$NETPLAN_RUNTIME/10-netplan-eth0.network") == 640 ]]
    [[ $(umask) == 0077 ]]
)
echo 'PASS: restrictive parent umask, generated network permissions, service readability check, parent umask preserved'
echo 'DNS=100.100.2.136 100.100.2.138' > "$work/leases/2"
dhcp_dns_conflicts eth0 "$work/leases" "$work/sys"
echo 'DNS=183.60.83.19 183.60.82.98' > "$work/leases/2"
if dhcp_dns_conflicts eth0 "$work/leases" "$work/sys"; then exit 1; fi
echo 'PASS: cloud DHCP/Tailscale conflict preflight distinguishes Alibaba DNS and Tencent VPC DNS'
