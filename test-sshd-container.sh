#!/usr/bin/env bash
# Run ONLY inside the disposable CI container, never on a user server.
set -Eeuo pipefail
[[ -f /.dockerenv && ${LTS_SSHD_TEST_CONTAINER:-} == 1 ]] || exit 1
cd /repo
source ./linux-server-tool.sh
work=$(mktemp -d /root/lts-sshd-test.XXXXXXXX)
pid=''
trap '[[ -z $pid ]] || kill "$pid" 2>/dev/null || true; rm -rf "$work"' EXIT
ssh-keygen -A
ssh-keygen -q -t ed25519 -N '' -f "$work/client"
passwd -d root >/dev/null
cat > /etc/ssh/sshd_config <<EOF
Port 22222
ListenAddress 127.0.0.2
HostKey /etc/ssh/ssh_host_ed25519_key
PidFile $work/sshd.pid
AuthorizedKeysFile $work/client.pub
PermitRootLogin prohibit-password
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes yes
EOF
if [[ -d /run/sshd ]]; then rmdir /run/sshd; fi
if /usr/sbin/sshd -t 2> "$work/before.log"; then
    echo 'Expected sshd preflight to fail without /run/sshd' >&2; exit 1
fi
grep -q 'Missing privilege separation directory' "$work/before.log"
validate_sshd
[[ $(stat -c '%a:%u:%g' /run/sshd) == 755:0:0 ]]
start_sshd() {
    /usr/sbin/sshd -D -e > "$work/daemon.log" 2>&1 &
    pid=$!
    for i in {1..30}; do
        if ssh -F /dev/null -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=1 -i "$work/client" -p 22222 "root@$1" true 2>/dev/null; then return; fi
        sleep 0.2
    done
    cat "$work/daemon.log"; return 1
}
start_sshd 127.0.0.2
kill "$pid"; wait "$pid" || true; pid=''
rmdir /run/sshd
# Replace service orchestration only; exercise the actual public-mode config path.
simple_config_check() { :; }
begin_change() { [[ $1 == rescue ]]; validate_sshd; }
keep_ssh_alive() { :; }
finish_change() { [[ $1 == rescue ]]; validate_sshd; }
connection_mode public rescue
grep -qx 'ListenAddress 0.0.0.0' /etc/ssh/sshd_config
! grep -q 'ListenAddress 127.0.0.2' /etc/ssh/sshd_config
start_sshd 127.0.0.1
health_probe_ssh
kill -STOP "$pid"
if health_probe_ssh; then
    kill -CONT "$pid"
    echo 'Expected health probe failure for a suspended sshd' >&2
    exit 1
fi
kill -CONT "$pid"
health_probe_ssh
echo 'PASS: real SSH key exchange detects suspended listener and succeeds after resume'
echo 'PASS: real sshd missing-runtime recovery, private-address login and public-address recovery login'
