#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/linux-server-tool.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
KEY_CONFIG=$work/keys
SELF=$work/not-installed
ssh-keygen -q -t ed25519 -N '' -f "$work/sample"
printf '# comments only\n \n' > "$KEY_CONFIG"
cp "$KEY_CONFIG" "$work/original"
if ensure_key_config <<< '' >/dev/null; then exit 1; fi
cmp "$KEY_CONFIG" "$work/original"
{ echo invalid; cat "$work/sample.pub"; } | ensure_key_config >/dev/null
grep -qxF "$(cat "$work/sample.pub")" "$KEY_CONFIG"
cp "$KEY_CONFIG" "$work/saved"
ensure_key_config </dev/null
cmp "$KEY_CONFIG" "$work/saved"
# Verify the menu action continues to installation in the same invocation.
simple_config_check() { :; }
install_keys() { echo import >> "$work/steps"; }
begin_change() { echo begin >> "$work/steps"; }
managed_set() { :; }
finish_change() { echo finish >> "$work/steps"; }
key_login >/dev/null
[[ $(wc -l < "$work/steps") == 3 ]]
rm "$work/steps"
cp "$work/original" "$KEY_CONFIG"
key_login <<< '' >/dev/null
[[ ! -e $work/steps ]]
echo 'PASS: empty/comment config prompt, invalid retry, save, existing config, same-action install and cancellation'
