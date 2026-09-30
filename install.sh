#!/usr/bin/env bash
# Install/update lts-tool without replacing host-local configuration or keys.
set -Eeuo pipefail
umask 077
[[ $EUID == 0 ]] || { echo '请使用 sudo bash 执行安装器。' >&2; exit 1; }
[[ -d /run/systemd/system ]] || { echo '需要运行 systemd 的 Linux。' >&2; exit 1; }
for cmd in curl sha256sum ssh-keygen flock; do
    if ! command -v "$cmd" >/dev/null; then
        if command -v apt-get >/dev/null; then
            apt-get update
            apt-get install -y curl ca-certificates openssh-client util-linux coreutils
        elif command -v dnf >/dev/null; then
            dnf install -y curl ca-certificates openssh-clients util-linux coreutils
        elif command -v yum >/dev/null; then
            yum install -y curl ca-certificates openssh-clients util-linux coreutils
        else
            echo "缺少 $cmd，请用系统包管理器安装后重试。" >&2
            exit 1
        fi
    fi
done
stage=$(mktemp -d)
trap 'rm -f -- "$stage/linux-server-tool.sh" "$stage/checksum"; rmdir -- "$stage"' EXIT
revision=$(curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --connect-timeout 15 --max-time 60 \
    -H 'Accept: application/vnd.github.sha' https://api.github.com/repos/gitttzr/lts-tool/commits/main)
[[ $revision =~ ^[0-9a-f]{40}$ ]] || { echo '无法获取有效版本编号，停止安装。' >&2; exit 1; }
base=https://raw.githubusercontent.com/gitttzr/lts-tool/$revision
curl --proto '=https' --tlsv1.2 -fSL --retry 3 --connect-timeout 15 --max-time 180 \
    "$base/linux-server-tool.sh" -o "$stage/linux-server-tool.sh"
curl --proto '=https' --tlsv1.2 -fSL --retry 3 --connect-timeout 15 --max-time 60 \
    "$base/linux-server-tool.sh.sha256" -o "$stage/checksum"
read -r expected filename < "$stage/checksum"
[[ $expected =~ ^[0-9a-f]{64}$ && $filename == linux-server-tool.sh ]] || { echo '校验清单格式不正确。' >&2; exit 1; }
printf '%s  %s\n' "$expected" "$stage/linux-server-tool.sh" | sha256sum --check --status
bash -n "$stage/linux-server-tool.sh"
bash "$stage/linux-server-tool.sh" --install
