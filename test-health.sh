#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/linux-server-tool.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
HEALTH_STATE=$work/state
BASE=$work/base
mkdir -p "$HEALTH_STATE" "$BASE"
active=active
result=1
systemctl() {
    if [[ $1 == show ]]; then echo "$active"; return; fi
    printf '%s\n' "$*" >> "$work/restarts"
}
probe() { return "$result"; }
health_check_unit ssh.service probe 200
health_check_unit ssh.service probe 260
[[ ! -f $work/restarts ]]
health_check_unit ssh.service probe 320
[[ $(wc -l < "$work/restarts") == 1 ]]
grep -qx -- '--no-block restart ssh.service' "$work/restarts"
for now in 380 440 500; do health_check_unit ssh.service probe "$now"; done
[[ $(wc -l < "$work/restarts") == 1 ]]
active=inactive
health_check_unit ssh.service probe 560
active=active
for now in 620 680 740; do health_check_unit ssh.service probe "$now"; done
[[ $(wc -l < "$work/restarts") == 1 ]]
health_check_unit ssh.service probe 920
[[ $(wc -l < "$work/restarts") == 2 ]]
result=0
health_check_unit ssh.service probe 980
grep -qx '0 920' "$HEALTH_STATE/ssh.service.state"
result=2
health_check_unit ssh.service probe 1040
grep -qx '0 920' "$HEALTH_STATE/ssh.service.state"
active=inactive
result=1
health_check_unit tailscaled.service probe 1100
[[ $(wc -l < "$work/restarts") == 2 ]]
touch "$BASE/pending"
health_check_unit() { echo 'Should skip pending transaction' >&2; exit 1; }
health_check
(
    timeout() { printf '{"BackendState":"%s"}\n' "$backend"; }
    for backend in Running Stopped NeedsLogin NeedsMachineAuth; do health_probe_tailscale; done
    timeout() { return 124; }
    if health_probe_tailscale; then exit 1; fi
    timeout() { echo 'invalid response'; }
    if health_probe_tailscale; then exit 1; fi
)
(
    timeout() {
        if [[ $3 == /usr/sbin/sshd ]]; then
            printf 'listenaddress 0.0.0.0:15525\nlistenaddress [::]:15525\nlistenaddress 100.96.198.99:15525\n'
        else
            printf '%s\n' "$*" >> "$work/probes"
            return "${scan_result:-0}"
        fi
    }
    health_probe_ssh
    grep -q -- '-p 15525 127.0.0.1$' "$work/probes"
    grep -q -- '-p 15525 ::1$' "$work/probes"
    grep -q -- '-p 15525 100.96.198.99$' "$work/probes"
    scan_result=124
    if health_probe_ssh; then exit 1; fi
    timeout() { return 1; }
    if health_probe_ssh; then exit 1; else [[ $? == 2 ]]; fi
)
echo 'PASS: health thresholds, cooldown across inactive state, deliberate stops, healthy/reset/unknown states, pending skip, local probes and timeouts'
