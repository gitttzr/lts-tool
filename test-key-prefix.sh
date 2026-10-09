#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/linux-server-tool.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
TEMP_PREFIX_CONFIG=$work/config/prefix
TEMP_ROOT=$work/keys; TEMP_AUTH=$work/authorized_keys
temp_key_paths() { mkdir -p "$TEMP_ROOT"; }
temp_key_preflight() { :; }
temp_key_publish() { mv "$1" "$TEMP_AUTH"; }
{ echo '../invalid'; echo hk01; } | temp_key_create > "$work/create"
[[ $(cat "$TEMP_PREFIX_CONFIG") == hk01 ]]
first=$(find "$TEMP_ROOT" -mindepth 1 -maxdepth 1 -type d | head -n1)
firstfile=$(temp_key_file "$first")
[[ ${firstfile##*/} == hk01-* && -f $firstfile && -f $firstfile.pub ]]
temp_key_edit_prefix <<< tw02 >/dev/null
[[ $(temp_key_file "$first") == "$firstfile" ]]
temp_key_create </dev/null >/dev/null
second=$(find "$TEMP_ROOT" -mindepth 1 -maxdepth 1 -type d ! -path "$first" | head -n1)
secondfile=$(temp_key_file "$second")
[[ ${secondfile##*/} == tw02-* ]]
temp_key_revoke "${first##*/}" >/dev/null
[[ ! -e $firstfile && ! -e $firstfile.pub && -f $secondfile ]]
echo 2026-01-01T00:00:00Z > "$second/created-at"
temp_key_expire "$(date -u -d 2026-01-02T00:00:00Z +%s)" >/dev/null
[[ ! -e $secondfile && ! -e $secondfile.pub ]]
temp_key_edit_prefix <<< '' >/dev/null && exit 1
[[ $(cat "$TEMP_PREFIX_CONFIG") == tw02 ]]
printf '../escape\n' > "$second/key-name"
if (temp_key_file "$second") >/dev/null 2>&1; then exit 1; fi
echo 'PASS: first-use prefix, invalid retry, edit persistence, old filename retention, revoke/expiry, cancellation and metadata path rejection'
