#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/linux-server-tool.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
TEMP_ROOT=$work/keys; TEMP_AUTH=$work/authorized_keys
temp_key_paths() { mkdir -p "$TEMP_ROOT"; }
temp_key_publish() { mv "$1" "$TEMP_AUTH"; }
ssh-keygen -q -t ed25519 -N '' -f "$work/permanent"
cat "$work/permanent.pub" > "$TEMP_AUTH"
cp "$TEMP_AUTH" "$work/expected"
for id in key-Old12345 key-New12345 key-20261001T000000Z-AbCd1234; do
    mkdir -p "$TEMP_ROOT/$id"
    file=$(temp_key_file "$TEMP_ROOT/$id")
    ssh-keygen -q -t ed25519 -N '' -f "$file"
    cat "$file.pub" >> "$TEMP_AUTH"
done
echo 2026-10-01T00:00:00Z > "$TEMP_ROOT/key-Old12345/created-at"
echo 2026-10-01T00:00:01Z > "$TEMP_ROOT/key-New12345/created-at"
echo 2026-10-01T00:00:00Z > "$TEMP_ROOT/key-20261001T000000Z-AbCd1234/created-at"
now=$(date -u -d 2026-10-02T00:00:00Z +%s)
temp_key_expire "$now" >/dev/null
[[ ! -e $TEMP_ROOT/key-Old12345/lts-Old12345 ]]
[[ ! -e $TEMP_ROOT/key-20261001T000000Z-AbCd1234/id_ed25519 ]]
[[ -f $TEMP_ROOT/key-New12345/lts-New12345 ]]
temp_key_expire "$((now+1))" >/dev/null
cmp "$TEMP_AUTH" "$work/expected"
temp_key_expire "$((now+1))" >/dev/null
echo 'PASS: 24h boundary, legacy keys, permanent authorization preserved, repeated cleanup'
