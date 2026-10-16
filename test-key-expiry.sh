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
[[ $(temp_key_read_days <<< '') == 3 ]]
[[ $(temp_key_read_days <<< 7) == 7 ]]
[[ $(printf '0\n-1\nabc\n1.5\n36501\n2\n' | temp_key_read_days 2>/dev/null) == 2 ]]
mkdir -p "$TEMP_ROOT/key-Ttl12345"
ttlfile=$(temp_key_file "$TEMP_ROOT/key-Ttl12345")
ssh-keygen -q -t ed25519 -N '' -f "$ttlfile"
cat "$ttlfile.pub" >> "$TEMP_AUTH"
echo 2026-10-01T00:00:00Z > "$TEMP_ROOT/key-Ttl12345/created-at"
echo 3 > "$TEMP_ROOT/key-Ttl12345/valid-days"
temp_key_expire "$((now+86400))" >/dev/null
[[ -f $ttlfile ]]
temp_key_expire "$((now+172800))" >/dev/null
[[ ! -e $ttlfile ]]
cmp "$TEMP_AUTH" "$work/expected"
echo 'PASS: default/custom days, invalid input retries, 3-day expiry and legacy policy coexist'
