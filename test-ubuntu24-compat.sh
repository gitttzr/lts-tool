#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/linux-server-tool.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
SYSTEMD_CONFIG=$work/systemd
SSH_UNIT=ssh.service
mkdir -p "$SYSTEMD_CONFIG/ssh.service.d" "$SYSTEMD_CONFIG/ssh.socket.d" "$work/unrelated"
printf '[Unit]\nRequires=ssh.socket\n' > "$SYSTEMD_CONFIG/ssh.service.d/00-socket.conf"
printf '[Socket]\nListenStream=22\n' > "$SYSTEMD_CONFIG/ssh.socket.d/addresses.conf"
echo unrelated > "$SYSTEMD_CONFIG/ssh.service.d/custom.conf"
# Verify absolute backups work from an unrelated directory and retain layout.
(
    cd "$work/unrelated"
    ssh_save_activation "$work/snapshot"
)
cmp "$SYSTEMD_CONFIG/ssh.service.d/00-socket.conf" "$work/snapshot/activation/${SYSTEMD_CONFIG#/}/ssh.service.d/00-socket.conf"
unit_exists() { [[ $1 == ssh.socket ]]; }
systemctl() {
    printf '%s\n' "$*" >> "$work/events"
    if [[ $1 == show && -f $SYSTEMD_CONFIG/ssh.service.d/00-socket.conf ]]; then echo ssh.socket; fi
    return 0
}
ssh_disable_activation
[[ ! -e $SYSTEMD_CONFIG/ssh.service.d/00-socket.conf ]]
[[ ! -e $SYSTEMD_CONFIG/ssh.socket.d/addresses.conf ]]
[[ $(cat "$SYSTEMD_CONFIG/ssh.service.d/custom.conf") == unrelated ]]
[[ $(head -n1 "$work/events") == daemon-reload ]]
grep -qx 'disable --now ssh.socket' "$work/events"
ssh_restore_activation "$work/snapshot"
grep -qx 'Requires=ssh.socket' "$SYSTEMD_CONFIG/ssh.service.d/00-socket.conf"
ssh_disable_activation
ssh_save_activation "$work/no-dropins"
touch "$SYSTEMD_CONFIG/ssh.service.d/00-socket.conf"
ssh_restore_activation "$work/no-dropins"
[[ ! -e $SYSTEMD_CONFIG/ssh.service.d/00-socket.conf ]]
# An unknown dependency must stop the transition instead of being erased.
systemctl() { [[ $1 != show ]] || echo ssh.socket; return 0; }
if ssh_disable_activation >/dev/null 2>&1; then exit 1; fi
systemctl() { return 1; }
journalctl() { printf '%s\n' "$*" > "$work/journal-args"; }
service_diagnostics ssh.service 2>/dev/null
grep -qx -- '-b -u ssh.service -n 40 --no-pager' "$work/journal-args"
echo 'PASS: absolute backup from unrelated cwd, socket dependency removal and restoration, custom config preservation, unknown dependency refusal, bounded service diagnostics'
systemctl() { [[ $* != *ActiveState* ]] || echo active; return 0; }
if ssh_cleanup_orphan_listeners ssh.service >/dev/null 2>&1; then exit 1; fi
systemctl() { [[ $* != *ActiveState* ]] || echo inactive; return 0; }
ssh_cleanup_orphan_listeners ssh.service
echo 'PASS: no orphan cleanup while service active, empty stopped cgroup is safe'
