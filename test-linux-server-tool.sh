#!/usr/bin/env bash
# Non-root regression tests. Never starts services or writes /etc.
set -Eeuo pipefail
source "$(dirname "$0")/linux-server-tool.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
CONF=$work/sshd_config
cat > "$CONF" <<'EOF'
# sample
Port 22
PasswordAuthentication yes
Include /etc/ssh/sshd_config.d/*.conf
EOF
managed_set PasswordAuthentication no
managed_set PubkeyAuthentication yes
managed_set PasswordAuthentication no
[[ $(grep -c '^# BEGIN LINUX-SERVER-TOOL$' "$CONF") == 1 ]]
[[ $(grep -c '^PasswordAuthentication no$' "$CONF") == 1 ]]
[[ $(sed -n '2p' "$CONF") == 'PubkeyAuthentication yes' ]]
grep -qx 'PasswordAuthentication yes' "$CONF"
managed_set ListenAddress $'100.64.1.2\nListenAddress fd7a:115c:a1e0::1'
ssh_files() { printf '%s\n' "$CONF"; }
remove_directive ListenAddress
managed_set ListenAddress 0.0.0.0
[[ $(grep -c '^ListenAddress ' "$CONF") == 1 ]]
grep -qx 'ListenAddress 0.0.0.0' "$CONF"
remove_directive Port
managed_set Port 2222
[[ $(grep -c '^Port ' "$CONF") == 1 ]]
grep -qx 'Port 2222' "$CONF"
say 'PASS: managed block precedence, idempotency, IPv4/IPv6 mode replacement, port replacement'
systemctl() { return 1; }
dns_menu() { echo conflict >> "$work/conflict"; }
dns_addresses() { printf '%s\n' 100.63.255.254 100.128.0.1 8.8.8.8; }
dns_check >/dev/null
[[ ! -e $work/conflict ]]
dns_addresses() { printf '%s\n' 100.64.0.1 100.127.255.254 100.100.2.136; }
dns_check >/dev/null
[[ $(wc -l < "$work/conflict") == 1 ]]
rm "$work/conflict"
systemctl() { return 0; }
dns_addresses() { echo 100.100.100.100; }
dns_check >/dev/null
[[ ! -e $work/conflict ]]
say 'PASS: CGNAT lower/upper boundaries and existing MagicDNS handling'

# Exercise real key generation against an isolated authorized_keys fixture.
# Only the OS preflight, root paths and ownership change are substituted.
TEMP_ROOT=$work/temporary-keys
TEMP_AUTH=$work/root-ssh/authorized_keys
temp_key_paths() { mkdir -p "$TEMP_ROOT" "${TEMP_AUTH%/*}"; }
temp_key_preflight() { :; }
temp_key_publish() { chmod 600 "$1"; mv -f -- "$1" "$TEMP_AUTH"; }
temp_key_paths
ssh-keygen -q -t ed25519 -N '' -C permanent -f "$work/permanent"
{
    printf '# Existing keys must survive\n\n'
    printf 'from="192.0.2.1",no-agent-forwarding '
    cat "$work/permanent.pub"
} > "$TEMP_AUTH"
cp "$TEMP_AUTH" "$work/original-authorized"
temp_key_create > "$work/create-1.log"
temp_key_create > "$work/create-2.log"
mapfile -t dirs < <(find "$TEMP_ROOT" -mindepth 1 -maxdepth 1 -type d | sort)
[[ ${#dirs[@]} == 2 ]]
first=${dirs[0]}; second=${dirs[1]}
first_key=$(temp_key_file "$first"); second_key=$(temp_key_file "$second")
[[ ${first_key##*/} != ${second_key##*/} ]]
[[ ${first##*/} =~ ^key-[a-zA-Z0-9]{8}$ ]]
[[ ${first_key##*/} =~ ^lts-[a-zA-Z0-9]{8}$ ]]
first_blob=$(awk '{print $2}' "$first_key.pub")
second_blob=$(awk '{print $2}' "$second_key.pub")
[[ $first_blob != "$second_blob" ]]
[[ $(ssh-keygen -y -f "$first_key" | awk '{print $2}') == "$first_blob" ]]
[[ $(ssh-keygen -y -f "$second_key" | awk '{print $2}') == "$second_blob" ]]
grep -qF "$first_blob" "$TEMP_AUTH"
grep -qF "$second_blob" "$TEMP_AUTH"
if grep -q 'BEGIN OPENSSH PRIVATE KEY' "$work/create-1.log" "$work/create-2.log"; then exit 1; fi
temp_key_list > "$work/numbered-list"
grep -qF "1) ${first##*/}" "$work/numbered-list"
cp "$TEMP_AUTH" "$work/before-selection"
for selection in 0 999999999 invalid '../escape'; do
    if (temp_key_revoke <<< "$selection") > /dev/null 2>&1; then exit 1; fi
    cmp "$TEMP_AUTH" "$work/before-selection"
done
temp_key_revoke <<< '' > /dev/null
cmp "$TEMP_AUTH" "$work/before-selection"
temp_key_revoke <<< 1 > /dev/null
[[ ! -e $first_key && ! -e $first_key.pub && -f $first/revoked-at ]]
! grep -qF "$first_blob" "$TEMP_AUTH"
grep -qF "$second_blob" "$TEMP_AUTH"
[[ -f $second_key ]]
# Repeat revocation safely, then revoke all and compare original bytes.
temp_key_revoke "${first##*/}" > /dev/null
temp_key_revoke_all > /dev/null
[[ ! -e $second_key && ! -e $second_key.pub && -f $second/revoked-at ]]
cmp "$TEMP_AUTH" "$work/original-authorized"
long_legacy=$TEMP_ROOT/key-20261002T120000Z-Ab12Cd34Ef56Gh78Ij90Kl12
mkdir -p "$long_legacy"
long_key=$(temp_key_file "$long_legacy")
[[ $long_key == "$long_legacy/lts-${long_legacy##*/}" ]]
ssh-keygen -q -t ed25519 -N '' -f "$long_key"
cat "$long_key.pub" >> "$TEMP_AUTH"
temp_key_revoke_all > /dev/null
[[ ! -e $long_key && ! -e $long_key.pub && -f $long_legacy/revoked-at ]]
cmp "$TEMP_AUTH" "$work/original-authorized"
if (temp_key_revoke '../escape') > /dev/null 2>&1; then exit 1; fi
say 'PASS: unique real keypairs, private/public match, individual and bulk revocation, permanent keys byte-for-byte preserved, invalid ID rejected'

# Old registry entries and filenames remain revocable after the naming change.
legacy=$TEMP_ROOT/key-20260930T120000Z-AbCd1234
mkdir -p "$legacy"
ssh-keygen -q -t ed25519 -N '' -f "$legacy/id_ed25519"
cat "$legacy/id_ed25519.pub" >> "$TEMP_AUTH"
temp_key_list > "$work/legacy-list"
grep -qF "$legacy/id_ed25519" "$work/legacy-list"
temp_key_revoke "${legacy##*/}" > /dev/null
[[ ! -e $legacy/id_ed25519 && ! -e $legacy/id_ed25519.pub ]]
cmp "$TEMP_AUTH" "$work/original-authorized"
(
    exec 9>"$work/download-lock"
    flock 9
    bash() {
        [[ $* == '--noprofile --norc -i' ]]
        [[ $PWD == "$second" ]]
        [[ $PROMPT_COMMAND == *'root@server:'* ]]
        flock -n "$work/download-lock" -c true
        echo shell-opened > "$work/download-shell"
    }
    temp_key_open_dir "$second" > "$work/download-output"
    [[ -f $work/download-shell ]]
)
say 'PASS: legacy revocation compatibility and download shell directory/title/lock release'

# Appending to a key file without a final newline must not join two keys.
printf '%s' "$(cat "$work/permanent.pub")" > "$TEMP_AUTH"
temp_key_create > /dev/null
[[ $(wc -l < "$TEMP_AUTH") == 2 ]]
[[ $(head -n 1 "$TEMP_AUTH") == "$(cat "$work/permanent.pub")" ]]
temp_key_revoke_all > /dev/null
[[ $(cat "$TEMP_AUTH") == "$(cat "$work/permanent.pub")" ]]
say 'PASS: existing key with no trailing newline is preserved'

(
    CONF=$work/disable-password-config
    cat > "$CONF" <<'EOF'
AuthorizedKeysFile .ssh/authorized_keys .ssh/other_keys
PermitRootLogin prohibit-password
PasswordAuthentication yes
EOF
    simple_config_check() { :; }
    install_keys() { echo 'Unexpected key import' >&2; exit 1; }
    begin_change() { echo begin >> "$work/password-transaction"; }
    finish_change() { echo finish >> "$work/password-transaction"; }
    cp "$TEMP_AUTH" "$work/before-password-change"
    disable_password_login > /dev/null
    grep -qx 'PasswordAuthentication no' "$CONF"
    grep -qx 'KbdInteractiveAuthentication no' "$CONF"
    grep -qx 'ChallengeResponseAuthentication no' "$CONF"
    grep -qx 'AuthenticationMethods publickey' "$CONF"
    grep -qx 'AuthorizedKeysFile .ssh/authorized_keys .ssh/other_keys' "$CONF"
    grep -qx 'PermitRootLogin prohibit-password' "$CONF"
    [[ $(grep -c '^AuthorizedKeysFile ' "$CONF") == 1 ]]
    [[ $(grep -c '^PermitRootLogin ' "$CONF") == 1 ]]
    [[ $(cat "$work/password-transaction") == $'begin\nfinish' ]]
    cmp "$TEMP_AUTH" "$work/before-password-change"
)
say 'PASS: disable-password action never imports keys, preserves key paths/root policy, retains rollback transaction'

(
    KEY_CONFIG=$work/config/root_authorized_keys
    SELF=$work/legacy-lts-tool
    {
        printf '%s\n' '#!/usr/bin/env bash' 'ROOT_PUBLIC_KEYS=$(cat <<'"'KEYS'"
        cat "$work/permanent.pub"
        printf '%s\n' 'KEYS' ')' 'exit 99'
    } > "$SELF"
    init_key_config > /dev/null
    grep -qxF "$(cat "$work/permanent.pub")" "$KEY_CONFIG"
    cp "$KEY_CONFIG" "$work/config-saved"
    # A newer installer with different embedded contents must not overwrite it.
    printf '%s\n' 'exit 88' > "$SELF"
    init_key_config > /dev/null
    cmp "$KEY_CONFIG" "$work/config-saved"
    KEY_CONFIG=$work/fresh-config/root_authorized_keys
    init_key_config > /dev/null
    [[ -f $KEY_CONFIG ]]
    ! grep -q '^ssh-' "$KEY_CONFIG"
)
say 'PASS: legacy public-key migration as data, existing configuration preserved, new configuration initialized'

(
    log=$work/tailscale-login.log
    tailscale() {
        printf '%s\n' "$*" >> "$log"
        # Simulate profile reset during authorization: only a post-login set sticks.
        if [[ $1 == up ]]; then echo default-vps > "$work/active-name"; fi
        if [[ $1 == set && ${2:-} == --hostname=* ]]; then
            printf '%s\n' "${2#--hostname=}" > "$work/active-name"
        fi
    }
    tailscale_install_login <<< 'my-vps-01' > "$work/login-output"
    [[ $(sed -n '1p' "$log") == 'up --accept-dns=false --ssh=false --hostname=my-vps-01' ]]
    [[ $(tail -n 1 "$log") == 'set --hostname=my-vps-01' ]]
    [[ $(cat "$work/active-name") == my-vps-01 ]]
    grep -q '授权已完成' "$work/login-output"
    : > "$log"
    tailscale_install_login <<< '' > /dev/null
    ! grep -q -- '--hostname' "$log"
    tailscale() { printf '%s\n' "$*" >> "$log"; return 23; }
    : > "$log"
    if tailscale_install_login <<< 'my-vps-01' > "$work/failed-login-output"; then exit 1; fi
    [[ $(wc -l < "$log") == 1 ]]
    ! grep -q '授权已完成' "$work/failed-login-output"
    : > "$log"
    if (tailscale_install_login <<< '-invalid') > /dev/null 2>&1; then exit 1; fi
    [[ ! -s $log ]]
)
say 'PASS: hostname survives login profile reset, blank keeps name, failed login never reports success, invalid name rejected'

(
    BASE=$work/update-state
    activate_updated_tool() { echo activated >> "$work/update-activated"; }
    SELF=$work/update-bin/lts-tool
    KEY_CONFIG=$work/update-config/root_authorized_keys
    mkdir -p "$BASE/temporary-keys/example" "${SELF%/*}" "${KEY_CONFIG%/*}" "$work/update-download"
    printf '#!/usr/bin/env bash\necho old\n' > "$SELF"
    cp "$SELF" "$work/update-old"
    cp "$work/permanent.pub" "$KEY_CONFIG"
    echo keep-temporary-key > "$BASE/temporary-keys/example/record"
    printf '#!/usr/bin/env bash\necho new\n' > "$work/update-download/linux-server-tool.sh"
    (cd "$work/update-download"; sha256sum --text linux-server-tool.sh > checksum)
    curl() {
        local url='' output=''
        [[ ${download_failure:-no} == no ]] || return 22
        while (($#)); do
            case $1 in
                https://*) url=$1; shift;;
                -o) output=$2; shift 2;;
                *) shift;;
            esac
        done
        echo request >> "$work/update-requests"
        if [[ $url == https://api.github.com/repos/gitttzr/lts-tool/commits/main ]]; then
            printf '%s\n' "${mock_revision:-1111111111111111111111111111111111111111}"
            return
        fi
        [[ $url == https://raw.githubusercontent.com/gitttzr/lts-tool/1111111111111111111111111111111111111111/* ]] || return 99
        if [[ $url == *.sha256 ]]; then cp "$work/update-download/checksum" "$output"
        else cp "$work/update-download/linux-server-tool.sh" "$output"; fi
    }
    update_tool > /dev/null
    cmp "$SELF" "$work/update-download/linux-server-tool.sh"
    cmp "$BASE/lts-tool.previous" "$work/update-old"
    cmp "$KEY_CONFIG" "$work/permanent.pub"
    grep -qx keep-temporary-key "$BASE/temporary-keys/example/record"
    update_tool > "$work/update-current-output"
    [[ $(wc -l < "$work/update-activated") == 2 ]]
    grep -q '已经是仓库最新版本' "$work/update-current-output"
    cmp "$BASE/lts-tool.previous" "$work/update-old"
    printf '%064d  linux-server-tool.sh\n' 0 > "$work/update-download/checksum"
    if (update_tool) > /dev/null 2>&1; then exit 1; fi
    cmp "$SELF" "$work/update-download/linux-server-tool.sh"
    download_failure=yes
    if (update_tool) > /dev/null 2>&1; then exit 1; fi
    cmp "$SELF" "$work/update-download/linux-server-tool.sh"
    download_failure=no
    mock_revision='invalid-revision'
    if (update_tool) > /dev/null 2>&1; then exit 1; fi
    cmp "$SELF" "$work/update-download/linux-server-tool.sh"
    unset mock_revision
    cp "$SELF" "$work/update-known-good"
    printf 'if broken syntax\n' > "$work/update-download/linux-server-tool.sh"
    (cd "$work/update-download"; sha256sum --text linux-server-tool.sh > checksum)
    if (update_tool) > /dev/null 2>&1; then exit 1; fi
    cmp "$SELF" "$work/update-known-good"
    echo pending > "$BASE/pending"
    : > "$work/update-requests"
    if (update_tool) > /dev/null 2>&1; then exit 1; fi
    [[ ! -s $work/update-requests ]]
    [[ -z $(find "$BASE" -maxdepth 1 -name 'update.*' -print) ]]
)
say 'PASS: update replacement and backup, config/key preservation, no-op update, checksum/download/syntax failure and pending SSH protection'

(
    ensure_sshd_runtime() { echo runtime >> "$work/sshd-validation-order"; }
    sshd() { echo "sshd $*" >> "$work/sshd-validation-order"; }
    validate_sshd
    [[ $(cat "$work/sshd-validation-order") == $'runtime\nsshd -t' ]]
    ssh_service_override > "$work/ssh-override"
    grep -qx 'RestartPreventExitStatus=' "$work/ssh-override"
    grep -qx 'RuntimeDirectory=sshd' "$work/ssh-override"
    grep -qx 'RuntimeDirectoryPreserve=restart' "$work/ssh-override"
    BASE=$work/recovery
    mkdir -p "$BASE"
    echo old-token > "$BASE/pending"
    simple_config_check() { :; }
    systemctl() { echo "$*" >> "$work/recovery-systemctl"; }
    connection_mode() { [[ ! -f $BASE/pending ]]; echo "$*" > "$work/recovery-mode"; }
    rollback() { echo 'Must not restore old private config' >&2; exit 1; }
    rescue_public_ssh
    [[ $(cat "$work/recovery-mode") == 'public rescue' ]]
    [[ $(cat "$BASE"/cancelled-pending-*) == old-token ]]
    grep -qx 'disable --now linux-server-tool-rollback.timer' "$work/recovery-systemctl"
)
say 'PASS: runtime directory before validation, exit-255 retry override, rescue cancels rollback without restoring private listener'

(
    BASE=$work/reauth
    mkdir -p "$BASE"
    SSH_CONNECTION=''
    scenario=success
    ask() { return 0; }
    systemctl() { :; }
    timeout() { shift 3; "$@"; }
    tailscale() {
        echo "$*" >> "$work/reauth-calls"
        [[ $1 == up ]] || return 0
        case $scenario in
            success) return 0;;
            timeout) return 124;;
            flags)
                if [[ $* == *--accept-dns=false* ]]; then return 0; fi
                printf '%s\n' 'Error: non-default flags required' 'tailscale up --force-reauth --accept-dns=false --hostname=my-vps'
                return 1;;
        esac
    }
    tailscale_auth connect > "$work/connect-result"
    grep -qx up "$work/reauth-calls"
    grep -q '成功完成' "$work/connect-result"
    : > "$work/reauth-calls"
    scenario=flags
    tailscale_auth reauth > /dev/null
    grep -qx 'up --force-reauth' "$work/reauth-calls"
    grep -qx 'up --force-reauth --accept-dns=false --hostname=my-vps' "$work/reauth-calls"
    scenario=timeout
    if tailscale_auth connect > "$work/auth-timeout"; then exit 1; fi
    grep -q '124' "$work/auth-timeout"
    ! grep -q '成功完成' "$work/auth-timeout"
    SSH_CONNECTION='100.64.1.2 12345 100.100.1.3 22'
    : > "$work/reauth-calls"
    if tailscale_auth reauth > /dev/null; then exit 1; fi
    [[ ! -s $work/reauth-calls ]]
    tailscale_session_address fd7a:115c:a1e0::1
    ! tailscale_session_address 100.63.1.1
    ! tailscale_session_address 100.128.1.1
    SSH_CONNECTION=''
    ask() { return 1; }
    tailscale_auth reauth > /dev/null
    [[ ! -s $work/reauth-calls ]]
    printf '%s\n' 'non-default flags' 'tailscale up --force-reauth --reset' > "$work/unsafe-flags"
    if tailscale_suggested_flags "$work/unsafe-flags" reauth; then exit 1; fi
    printf '%s\n' 'non-default flags' 'tailscale up --force-reauth --hostname=$(touch /tmp/unsafe)' > "$work/unsafe-flags"
    if tailscale_suggested_flags "$work/unsafe-flags" reauth; then exit 1; fi
)
say 'PASS: explicit reauth, preserving suggested preferences without eval/reset, success/timeout output, private-SSH refusal and cancellation'
