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
first_blob=$(awk '{print $2}' "$first/id_ed25519.pub")
second_blob=$(awk '{print $2}' "$second/id_ed25519.pub")
[[ $first_blob != "$second_blob" ]]
[[ $(ssh-keygen -y -f "$first/id_ed25519" | awk '{print $2}') == "$first_blob" ]]
[[ $(ssh-keygen -y -f "$second/id_ed25519" | awk '{print $2}') == "$second_blob" ]]
grep -qF "$first_blob" "$TEMP_AUTH"
grep -qF "$second_blob" "$TEMP_AUTH"
if grep -q 'BEGIN OPENSSH PRIVATE KEY' "$work/create-1.log" "$work/create-2.log"; then exit 1; fi
temp_key_revoke "${first##*/}" > /dev/null
[[ ! -e $first/id_ed25519 && -f $first/revoked-at ]]
! grep -qF "$first_blob" "$TEMP_AUTH"
grep -qF "$second_blob" "$TEMP_AUTH"
[[ -f $second/id_ed25519 ]]
# Repeat revocation safely, then revoke all and compare original bytes.
temp_key_revoke "${first##*/}" > /dev/null
temp_key_revoke_all > /dev/null
[[ ! -e $second/id_ed25519 && -f $second/revoked-at ]]
cmp "$TEMP_AUTH" "$work/original-authorized"
if (temp_key_revoke '../escape') > /dev/null 2>&1; then exit 1; fi
say 'PASS: unique real keypairs, private/public match, individual and bulk revocation, permanent keys byte-for-byte preserved, invalid ID rejected'

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
