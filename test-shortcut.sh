#!/usr/bin/env bash
set -Eeuo pipefail
source "$(dirname "$0")/linux-server-tool.sh"
need() { :; }
root_check() { exit 99; }
tailscale() { [[ $* == status ]] || exit 98; echo shortcut-ok; }
[[ $(main tailscale) == shortcut-ok ]]
tailscale() { return 7; }
if (main tailscale); then exit 97; else [[ $? == 7 ]]; fi
echo 'PASS: tailscale shortcut output, arguments, exit code and no system mutation'
