#!/usr/bin/env bash
# Linux VPS toolbox. Permanent public keys: /etc/lts-tool/root_authorized_keys.


set -Eeuo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
umask 077
VERSION=1.0.13
BASE=/var/lib/linux-server-tool
SELF=/usr/local/sbin/lts-tool
KEY_CONFIG=/etc/lts-tool/root_authorized_keys
CONF=/etc/ssh/sshd_config
BEGIN='# BEGIN LINUX-SERVER-TOOL'
END='# END LINUX-SERVER-TOOL'
HEALTH_STATE=/run/lts-tool-health
BBR_SYSCTL=/etc/sysctl.d/99-lts-tool-bbr.conf
BBR_MODULES=/etc/modules-load.d/lts-tool-bbr.conf
BBR_SERVICE=/etc/systemd/system/lts-tool-bbr.service

bbr_status() {
    say "当前 TCP 拥塞控制：$(sysctl -n net.ipv4.tcp_congestion_control)"
    say "默认队列：$(sysctl -n net.core.default_qdisc)"
    say "可用算法：$(sysctl -n net.ipv4.tcp_available_congestion_control)"
    if systemctl is-enabled --quiet lts-tool-bbr.service; then
        say 'BBR 开机应用服务：已启用'
    else say 'BBR 开机应用服务：未启用'; fi
    say "持久配置：$BBR_SYSCTL"
    say '默认算法作用于新 TCP 连接；现有连接及接口队列不会强制重建。'
}
bbr_enable() {
    need sysctl; need modprobe
    # Check support before writing persistent settings. Built-in BBR needs no load.
    if [[ " $(sysctl -n net.ipv4.tcp_available_congestion_control) " != *' bbr '* ]]; then
        modprobe tcp_bbr || die '当前 VPS 内核无法加载 tcp_bbr；请检查宿主机限制或内核模块。'
    fi
    [[ " $(sysctl -n net.ipv4.tcp_available_congestion_control) " == *' bbr '* ]] || die '当前内核不支持 BBR。'
    modprobe sch_fq || die '当前内核无法加载 fq 队列模块。'
    local file
    for file in "$BBR_SYSCTL" "$BBR_MODULES" "$BBR_SERVICE"; do
        [[ ! -L $file && ( ! -e $file || -f $file ) ]] || die "配置路径不是普通文件：$file"
    done
    # Validate write permission (including restricted VPS containers) before saving.
    sysctl -w net.core.default_qdisc=fq net.ipv4.tcp_congestion_control=bbr || die '无法应用 BBR，未写入持久配置。'
    install -d -m 755 "${BBR_SYSCTL%/*}" "${BBR_MODULES%/*}" "${BBR_SERVICE%/*}"
    printf 'net.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n' > "$BBR_SYSCTL"
    printf 'tcp_bbr\nsch_fq\n' > "$BBR_MODULES"
    # Apply after Ubuntu/procps and systemd sysctl loaders, including sysctl.conf.
    # This avoids older conflicting tuning settings winning during boot.
    cat > "$BBR_SERVICE" <<EOF
[Unit]
Description=Apply persistent lts-tool BBR settings
After=systemd-modules-load.service systemd-sysctl.service procps.service
Before=network-pre.target
Wants=network-pre.target
[Service]
Type=oneshot
ExecStart=/usr/sbin/sysctl -p $BBR_SYSCTL
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$BBR_SYSCTL" "$BBR_MODULES" "$BBR_SERVICE"
    systemctl daemon-reload
    systemctl enable lts-tool-bbr.service
    systemctl restart lts-tool-bbr.service
    systemctl is-enabled --quiet lts-tool-bbr.service || die 'BBR 开机服务未成功启用。'
    [[ $(sysctl -n net.ipv4.tcp_congestion_control) == bbr && $(sysctl -n net.core.default_qdisc) == fq ]] || die 'BBR 生效验证失败，请检查配置。'
    say '谷歌 BBR 已立即启用，并配置为每次开机自动应用（bbr + fq）。'
    bbr_status
}
bbr_menu() {
    local c
    while true; do
        say $'\n谷歌 BBR（Ubuntu 22.04）：\n1) 启用并永久启用 BBR\n2) 查看 BBR 状态\n0) 返回'
        read -r -p '请选择：' c
        case $c in
            1) bash "$SELF" --bbr-enable || say 'BBR 启用未完成，请查看上方错误。';;
            2) bash "$SELF" --bbr-status || say '无法读取 BBR 状态。';;
            0) return;; *) say '无效选择。';;
        esac
    done
}

# Local liveness probes only: no external host or control-plane reachability test.
health_probe_tailscale() {
    local output
    output=$(timeout --kill-after=2s 8s tailscale status --json 2>/dev/null) || return 1
    # NeedsLogin/Stopped are responsive states, not reasons to restart.
    [[ $output =~ \"BackendState\"[[:space:]]*:[[:space:]]*\"[^\"]+\" ]]
}
health_probe_ssh() {
    local config endpoint host port count=0
    config=$(timeout --kill-after=2s 8s /usr/sbin/sshd -T 2>/dev/null) || return 2
    while read -r endpoint; do
        [[ -n $endpoint ]] || continue
        ((count+=1))
        ((count <= 16)) || return 2
        port=${endpoint##*:}; host=${endpoint%:*}
        host=${host#\[}; host=${host%\]}
        case $host in 0.0.0.0) host=127.0.0.1;; ::) host=::1;; esac
        [[ -n $host && $port =~ ^[0-9]+$ ]] || return 2
        # A key exchange, not merely an open TCP port. No login/private key used.
        timeout --kill-after=2s 8s ssh-keyscan -T 5 -p "$port" "$host" >/dev/null 2>&1 || return 1
    done < <(printf '%s\n' "$config" | awk '$1 == "listenaddress" {print $2}')
    ((count > 0)) || return 2
}
health_check_unit() {
    local unit=$1 probe=$2 now=$3 count=0 last=0 rc state
    # Respect deliberate stops; service crash/start retries remain systemd's job.
    state=$(systemctl show "$unit" -p ActiveState --value) || return 0
    if [[ -f $HEALTH_STATE/$unit.state ]]; then
        read -r count last < "$HEALTH_STATE/$unit.state" || true
        [[ $count =~ ^[0-9]{1,3}$ && $last =~ ^[0-9]{1,12}$ ]] || { count=0; last=0; }
    fi
    if [[ $state != active ]]; then
        printf '0 %s\n' "$last" > "$HEALTH_STATE/$unit.state"
        return 0
    fi
    if "$probe"; then rc=0; else rc=$?; fi
    if ((rc == 0)); then
        count=0
    elif ((rc == 2)); then
        count=0
        say "Health: $unit probe unavailable (check configuration); no restart."
    else
        ((count+=1))
        ((count <= 3)) || count=3
        say "Health: $unit local probe failed ($count/3)."
        if ((count >= 3 && (last == 0 || now - last >= 600))); then
            # Record before dispatch, so even a failed restart has a cooldown.
            last=$now; count=0
            printf '%s %s\n' "$count" "$last" > "$HEALTH_STATE/$unit.state"
            say "Health: requesting restart of $unit; cooldown 600 seconds."
            systemctl --no-block restart "$unit" || say "Health: restart request failed for $unit."
        fi
    fi
    printf '%s %s\n' "$count" "$last" > "$HEALTH_STATE/$unit.state"
}
health_check() {
    local uptime unit
    # The caller holds the tool lock; skip any unconfirmed SSH transaction.
    [[ ! -f $BASE/pending ]] || return 0
    read -r uptime _ < /proc/uptime
    uptime=${uptime%%.*}
    ((uptime >= 180)) || return 0
    install -d -m 700 "$HEALTH_STATE"
    if command -v tailscale >/dev/null && unit_exists tailscaled.service; then
        health_check_unit tailscaled.service health_probe_tailscale "$uptime"
    fi
    unit=$(ssh_unit) || return 0
    health_check_unit "$unit" health_probe_ssh "$uptime"
}
health_enable() {
    no_pending
    need timeout; need ssh-keyscan
    local unit ssh
    ssh=$(ssh_unit)
    for unit in "$ssh" tailscaled.service; do
        unit_exists "$unit" || continue
        install -d "/etc/systemd/system/$unit.d"
        cat > "/etc/systemd/system/$unit.d/91-lts-health.conf" <<'EOF'
[Service]
TimeoutStopSec=20s
SendSIGKILL=yes
EOF
    done
    cat > /etc/systemd/system/lts-tool-health.service <<EOF
[Unit]
Description=Check local SSH and Tailscale responsiveness
[Service]
Type=oneshot
ExecStart=/bin/bash $SELF --health-check
TimeoutStartSec=180s
UMask=0077
EOF
    cat > /etc/systemd/system/lts-tool-health.timer <<'EOF'
[Unit]
Description=Check local SSH and Tailscale every minute
[Timer]
OnBootSec=180s
OnUnitInactiveSec=60s
AccuracySec=5s
[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload || return $?
    systemctl enable --now lts-tool-health.timer || return $?
    printf '%s\n' "$VERSION" > "$BASE/health-default-version"
    say '健康守护已启用：连续失败 3 次后重启，重启冷却时间 10 分钟。SSH 连接策略保持不变。'
}
health_default_enable() {
    if [[ ${1:-} != force && -f $BASE/health-default-version ]] &&
        [[ $(cat "$BASE/health-default-version") == "$VERSION" ]]; then
        return 0
    fi
    say '正在启用本版本默认健康守护……'
    health_enable
}
activate_updated_tool() {
    # Source the verified new version in a child while retaining our existing lock.
    # Running main again here would wait for the lock held by this process.
    bash -c 'set -Eeuo pipefail; source "$1"; health_default_enable force' _ "$SELF"
}
health_disable() {
    systemctl disable --now lts-tool-health.timer
    systemctl stop lts-tool-health.service || true
    local unit
    for unit in ssh.service sshd.service tailscaled.service; do
        rm -f -- "/etc/systemd/system/$unit.d/91-lts-health.conf"
    done
    systemctl daemon-reload
    printf '%s\n' "$VERSION" > "$BASE/health-default-version"
    say '健康守护已关闭。SSH 连接策略保持不变；下次安装或升级将默认重新启用。'
}
health_status() {
    systemctl status lts-tool-health.timer --no-pager || true
    journalctl -u lts-tool-health.service -n 20 --no-pager || true
}
health_menu() {
    local c
    while true; do
        say $'\n健康守护：\n1) 启用健康守护\n2) 关闭健康守护\n3) 查看状态和日志\n0) 返回'
        read -r -p '请选择：' c
        case $c in
            1) bash "$SELF" --health-enable || say '启用失败，请查看上方错误。';;
            2) bash "$SELF" --health-disable || say '关闭失败，请查看上方错误。';;
            3) health_status;; 0) return;;
        esac
    done
}

say() { printf '%s\n' "$*"; }
die() { say "错误：$*" >&2; exit 1; }
ask() { local answer; read -r -p "$* [y/N] " answer; [[ $answer == y || $answer == Y ]]; }
need() { command -v "$1" >/dev/null || die "缺少命令：$1"; }
root_check() {
    [[ $EUID == 0 ]] || die '请使用 sudo bash linux-server-tool.sh。'
    [[ -d /run/systemd/system ]] || die '本脚本需要以 systemd 管理服务的 Linux。'
    install -d -m 700 "$BASE"
}
unit_exists() { [[ $(systemctl show -p LoadState --value "$1") == loaded ]]; }
ssh_unit() {
    if unit_exists ssh.service; then echo ssh.service
    elif unit_exists sshd.service; then echo sshd.service
    else die '未找到 OpenSSH 服务，请先安装 openssh-server。'; fi
}
ensure_sshd_runtime() {
    # /run is volatile, and stopping ssh.service may remove RuntimeDirectory.
    [[ ! -L /run/sshd ]] || die '/run/sshd must not be a symbolic link.'
    install -d -m 0755 -o root -g root /run/sshd
}
validate_sshd() {
    ensure_sshd_runtime
    sshd -t
}
install_self() {
    local src
    src=$(readlink -f "${BASH_SOURCE[0]}")
    if [[ $src != "$SELF" ]]; then
        no_pending
        local staged
        staged=$(mktemp "${SELF}.XXXXXXXX")
        install -m 700 "$src" "$staged"
        mv -f -- "$staged" "$SELF"
    fi
}
update_tool() (
    no_pending
    need curl; need sha256sum
    local stage staged='' expected filename revision base
    say "当前版本：$VERSION；正在解析最新版本并下载校验……"
    revision=$(curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --connect-timeout 15 --max-time 60 \
        -H 'Accept: application/vnd.github.sha' https://api.github.com/repos/gitttzr/lts-tool/commits/main) || return $?
    [[ $revision =~ ^[0-9a-f]{40}$ ]] || die '无法获取有效版本编号，保留当前版本。'
    base=https://raw.githubusercontent.com/gitttzr/lts-tool/$revision
    stage=$(mktemp -d "$BASE/update.XXXXXXXX") || return $?
    trap 'rm -f -- "$stage/linux-server-tool.sh" "$stage/checksum" "$stage/previous"; rmdir -- "$stage"; [[ -z $staged ]] || rm -f -- "$staged"' EXIT
    curl --proto '=https' --tlsv1.2 -fSL --retry 3 --connect-timeout 15 --max-time 180 \
        "$base/linux-server-tool.sh" -o "$stage/linux-server-tool.sh" || return $?
    curl --proto '=https' --tlsv1.2 -fSL --retry 3 --connect-timeout 15 --max-time 60 \
        "$base/linux-server-tool.sh.sha256" -o "$stage/checksum" || return $?
    read -r expected filename < "$stage/checksum" || return $?
    [[ $expected =~ ^[0-9a-f]{64}$ && $filename == linux-server-tool.sh ]] || die '下载校验清单格式不正确，保留当前版本。'
    printf '%s  %s\n' "$expected" "$stage/linux-server-tool.sh" | sha256sum --check --status || die '下载校验失败，保留当前版本；请稍后重试。'
    bash -n "$stage/linux-server-tool.sh" || die '新版语法检查失败，保留当前版本。'
    if cmp -s "$SELF" "$stage/linux-server-tool.sh"; then
        activate_updated_tool || { say '程序已是最新版，但健康守护启用失败，请在菜单第 5 项重试。'; return 1; }
        say '已经是仓库最新版本，无需更新。'
        return 0
    fi
    # Replace only the executable; never invoke --install under our held lock.
    # Keep the previous executable for manual recovery, but no config snapshots.
    cp -p -- "$SELF" "$stage/previous" || return $?
    chmod 700 "$stage/previous" || return $?
    mv -f -- "$stage/previous" "$BASE/lts-tool.previous" || return $?
    staged=$(mktemp "${SELF}.XXXXXXXX") || return $?
    install -m 700 "$stage/linux-server-tool.sh" "$staged" || return $?
    mv -f -- "$staged" "$SELF" || return $?
    staged=''
    activate_updated_tool || { say '新版程序已安装，但健康守护启用失败，请在菜单第 5 项重试。'; return 1; }
    say '工具更新完成，长期公钥配置、SSH 授权和临时密钥记录均已保留。'
    say "上一版工具备份：$BASE/lts-tool.previous"
    say '执行 lts-tool 即可使用新版。'
)
update_menu() {
    local c
    while true; do
        say "当前工具版本：$VERSION"
        say $'\n更新工具：\n1) 一键更新到仓库最新版本\n2) 查看当前版本及更新来源\n0) 返回'
        read -r -p '请选择：' c
        case $c in
            1) if bash "$SELF" --update; then
                   exec bash "$SELF"
               else say '更新未完成，当前版本仍可继续使用。'; fi;;
            2) say "版本：$VERSION"; say '来源：https://github.com/gitttzr/lts-tool（main 分支）';;
            0) return;; *) say '无效选择。';;
        esac
    done
}
init_key_config() (
    local parent=${KEY_CONFIG%/*} staged line probe count=0
    [[ ! -L $parent && ! -L $KEY_CONFIG ]] || die '长期公钥配置不能是符号链接。'
    [[ ! -e $KEY_CONFIG || -f $KEY_CONFIG ]] || die '长期公钥配置不是普通文件。'
    [[ ! -f $KEY_CONFIG ]] || return 0
    mkdir -p "$parent"
    chmod 700 "$parent"
    staged=$(mktemp "$parent/.keys.XXXXXXXX")
    probe=$(mktemp "$parent/.validate.XXXXXXXX")
    trap 'rm -f -- "$staged" "$probe"' EXIT
    printf '# lts-tool permanent ROOT public keys. One complete public key per line.\n# Never put private keys here. Updates preserve this file.\n' > "$staged"
    # Read legacy heredoc as data, NEVER source/evaluate an installed old script.
    if [[ -f $SELF ]]; then
        while IFS= read -r line; do
            line=${line%$'\r'}
            [[ $line == ssh-* || $line == ecdsa-* || $line == sk-* ]] || continue
            need ssh-keygen
            printf '%s\n' "$line" > "$probe"
            if ssh-keygen -lf "$probe" >/dev/null 2>&1; then
                printf '%s\n' "$line" >> "$staged"
                ((count+=1))
            fi
        done < <(awk '/^ROOT_PUBLIC_KEYS=\$\(cat / && /KEYS/ {p=1;next} p && /^KEYS\r?$/ {exit} p {print}' "$SELF")
    fi
    chmod 600 "$staged"
    mv -n -- "$staged" "$KEY_CONFIG"
    say "长期公钥配置：$KEY_CONFIG（已迁移 $count 把旧版公钥）。"
)
edit_key_config() {
    init_key_config
    if command -v nano >/dev/null; then nano "$KEY_CONFIG"
    elif command -v vi >/dev/null; then vi "$KEY_CONFIG"
    else die "请用文本编辑器修改 $KEY_CONFIG，每行一把完整公钥。"; fi
    say '配置已编辑；选择 SSH 菜单第 1 项可验证并追加导入。'
}
no_pending() { [[ ! -f $BASE/pending ]] || die "存在待确认修改。请先新开 SSH 连接确认，或执行 $SELF --rollback。"; }
run_action() (
    exec 9>"$BASE/lock"
    flock -n 9 || die '另一个操作正在执行。'
    case $1 in rollback|status|rescue_public_ssh|temp_key_list|temp_key_revoke|temp_key_revoke_all) ;; *) no_pending;; esac
    "$@"
)

# One transaction at a time; timer and confirmation share the same flock.
begin_change() {
    no_pending
    SSH_UNIT=$(ssh_unit)
    need sshd; need systemd-run
    validate_sshd
    TX=$(date +%s)-$RANDOM
    BACKUP=$BASE/backup-$TX
    install -d "$BACKUP/files"
    local f
    while IFS= read -r -d '' f; do
        cp -a --parents "$f" "$BACKUP/files"
    done < <(find /etc/ssh -maxdepth 1 -type f -name sshd_config -print0;
             find /etc/ssh/sshd_config.d -maxdepth 1 -type f -name '*.conf' -print0 2>/dev/null || true)
    [[ ! -L $CONF ]] || die 'sshd_config 是符号链接，请先改为常规文件。'
    printf '%s\n' "$SSH_UNIT" > "$BACKUP/unit"
    if [[ -f /etc/systemd/system/$SSH_UNIT.d/90-linux-server-tool.conf ]]; then
        cp -a "/etc/systemd/system/$SSH_UNIT.d/90-linux-server-tool.conf" "$BACKUP/ssh-dropin"
    fi
    for f in ssh.socket sshd.socket; do
        systemctl is-enabled "$f" > "$BACKUP/$f.enabled" 2>/dev/null || true
        systemctl is-active "$f" > "$BACKUP/$f.active" 2>/dev/null || true
    done
    printf '%s\n' "${SSH_CONNECTION:-console}" > "$BACKUP/origin"
    if [[ ${1:-normal} == rescue ]]; then
        say "Recovery backup: $BACKUP (no automatic rollback)."
        return 0
    fi
    cat > "$BASE/rollback.service" <<EOF
[Unit]
Description=Rollback unconfirmed SSH toolbox change
[Service]
Type=oneshot
ExecStart=/bin/bash $SELF --rollback
EOF
    install -m 644 "$BASE/rollback.service" /etc/systemd/system/linux-server-tool-rollback.service
    cat > /etc/systemd/system/linux-server-tool-rollback.timer <<'EOF'
[Unit]
Description=Rollback SSH change after three minutes (also after reboot)
[Timer]
OnActiveSec=180
Unit=linux-server-tool-rollback.service
[Install]
WantedBy=timers.target
EOF
    printf '%s\n' "$TX" > "$BASE/pending"
    systemctl daemon-reload
    systemctl enable --now linux-server-tool-rollback.timer
    say "已备份到 $BACKUP；3 分钟内未确认将自动回退。"
}
rollback() {
    [[ -f $BASE/pending ]] || { say '没有待回退的修改。'; return; }
    local token dir unit socket
    token=$(cat "$BASE/pending"); dir=$BASE/backup-$token
    [[ -d $dir/files/etc/ssh ]] || die '备份不存在，停止回退。'
    unit=$(cat "$dir/unit")
    cp -a "$dir/files/etc/ssh/." /etc/ssh/
    if [[ -f $dir/ssh-dropin ]]; then
        cp -a "$dir/ssh-dropin" "/etc/systemd/system/$unit.d/90-linux-server-tool.conf"
    else
        rm -f "/etc/systemd/system/$unit.d/90-linux-server-tool.conf"
    fi
    validate_sshd
    systemctl daemon-reload
    for socket in ssh.socket sshd.socket; do
        if grep -qx enabled "$dir/$socket.enabled"; then systemctl enable "$socket"; fi
        if grep -qx active "$dir/$socket.active"; then systemctl start "$socket"; fi
    done
    ensure_sshd_runtime
    systemctl reset-failed "$unit" || true
    systemctl restart "$unit"
    rm -f "$BASE/pending"
    systemctl disable --now linux-server-tool-rollback.timer || true
    say '已恢复修改前的 SSH 配置。'
}
confirm_change() {
    [[ -f $BASE/pending ]] || die '没有待确认修改。'
    local token origin
    token=$(cat "$BASE/pending")
    [[ ${1:-} == "$token" ]] || die '确认码不正确。'
    origin=$(cat "$BASE/backup-$token/origin")
    if [[ -z ${SSH_CONNECTION:-} || ${SSH_CONNECTION:-} == "$origin" ]]; then
        die '请在新建立的 SSH 连接中执行确认命令；sudo 用户请用 sudo --preserve-env=SSH_CONNECTION。'
    fi
    systemctl stop linux-server-tool-rollback.timer
    rm -f "$BASE/pending"
    systemctl disable linux-server-tool-rollback.timer
    say '新连接已确认，修改已保留。'
}
finish_change() {
    validate_sshd
    # Disable socket activation so sshd_config controls listening addresses/ports.
    local socket
    for socket in ssh.socket sshd.socket; do
        if unit_exists "$socket"; then systemctl disable --now "$socket"; fi
    done
    keep_ssh_alive
    ensure_sshd_runtime
    systemctl reset-failed "$SSH_UNIT" || true
    systemctl enable "$SSH_UNIT"
    systemctl restart "$SSH_UNIT"
    systemctl is-active --quiet "$SSH_UNIT"
    if [[ ${1:-normal} == rescue ]]; then
        say 'Public SSH listening restored. No automatic rollback is scheduled.'
        say 'SSH port and authentication policy are unchanged. Check firewall/security-group access.'
        sshd -T | awk '$1 ~ /^(port|listenaddress)$/ {print}'
        return 0
    fi
    say '请保留当前会话，新开 SSH 连接测试，并在新连接中执行：'
    say "  $SELF --confirm $TX"
    say "立即回退：$SELF --rollback"
    sshd -T | awk '$1 ~ /^(port|listenaddress|permitrootlogin|passwordauthentication|pubkeyauthentication|authenticationmethods)$/ {print}'
}

# Put our single-value settings first; OpenSSH uses first obtained values.
managed_set() {
    local key=$1 value=$2 tmp block
    tmp=$(mktemp); block=$(mktemp)
    awk -v b="$BEGIN" -v e="$END" '$0==b {p=1;next} $0==e {p=0;next} p' "$CONF" |
        awk -v k="$key" 'tolower($1)!=tolower(k)' > "$block"
    printf '%s %s\n' "$key" "$value" >> "$block"
    { echo "$BEGIN"; cat "$block"; echo "$END"
      awk -v b="$BEGIN" -v e="$END" '$0==b {p=1;next} $0==e {p=0;next} !p' "$CONF"; } > "$tmp"
    cat "$tmp" > "$CONF"
    rm -f "$tmp" "$block"
}
ssh_files() {
    printf '%s\n' "$CONF"
    find /etc/ssh/sshd_config.d -maxdepth 1 -type f -name '*.conf' -print 2>/dev/null || true
}
simple_config_check() {
    local f line pattern
    [[ ! -L $CONF && ! -L /etc/ssh/sshd_config.d ]] || die '暂不支持 SSH 配置路径为符号链接。'
    if [[ -d /etc/ssh/sshd_config.d ]] && [[ -n $(find /etc/ssh/sshd_config.d -maxdepth 1 -type l -name '*.conf' -print -quit) ]]; then
        die '暂不支持符号链接形式的 SSH 配置片段。'
    fi
    while IFS= read -r f; do
        [[ ! -L $f ]] || die "暂不支持符号链接配置：$f"
        if grep -Eiq '^[[:space:]]*Match[[:space:]]' "$f"; then
            die "检测到 Match 条件配置：$f。为避免覆盖条件权限，请人工整合后再运行。"
        fi
        while IFS= read -r line; do
            pattern=$(echo "$line" | awk '{print $2}')
            [[ $pattern == '/etc/ssh/sshd_config.d/*.conf' ]] || die "存在非标准 Include：$line，请人工整合后运行。"
            [[ $(echo "$line" | awk '{print NF}') == 2 ]] || die '暂不支持多路径 Include。'
        done < <(grep -Ei '^[[:space:]]*Include[[:space:]]' "$f" || true)
    done < <(ssh_files)
    if systemctl show "$(ssh_unit)" -p ExecStart --value | grep -Eq -- ' -[fop]([ =]|/)'; then
        die 'SSH 服务带有自定义配置/端口启动参数，请先人工整合。'
    fi
}
remove_directive() {
    local key=$1 f
    while IFS= read -r f; do
        sed -i -E "/^[[:space:]]*${key}[[:space:]]/Id" "$f"
    done < <(ssh_files)
}
ssh_service_override() {
    cat <<'EOF'
[Unit]
StartLimitIntervalSec=0
Wants=tailscaled.service
After=tailscaled.service
[Service]
Restart=on-failure
RestartSec=5s
# Debian/Ubuntu can otherwise suppress retries for bind failure (exit 255).
RestartPreventExitStatus=
RuntimeDirectory=sshd
RuntimeDirectoryMode=0755
RuntimeDirectoryPreserve=restart
EOF
}
keep_ssh_alive() {
    local unit
    unit=$(ssh_unit)
    install -d "/etc/systemd/system/$unit.d"
    ssh_service_override > "/etc/systemd/system/$unit.d/90-linux-server-tool.conf"
    systemctl daemon-reload
}
connection_mode() {
    local mode=$1 ip4 ip6 addresses
    simple_config_check
    if [[ $mode == private ]]; then
        need tailscale
        systemctl is-active --quiet tailscaled || die 'Tailscale 服务未运行。'
        ip4=$(tailscale ip -4); ip6=$(tailscale ip -6)
        [[ $ip4 =~ ^100\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die '尚未获得 Tailscale IPv4 地址。'
        ip link show tailscale0 >/dev/null || die '没有 tailscale0 接口，不支持 userspace networking 模式。'
        addresses=$ip4
        [[ -z $ip6 ]] || addresses+=$'\n'"ListenAddress $ip6"
        say '仅在 Tailscale IP 上监听 SSH。Tailscale 离线时请用 VNC 执行 --public-ssh。'
    else
        addresses=0.0.0.0
        [[ ! -s /proc/net/if_inet6 ]] || addresses+=$'\nListenAddress ::'
        say 'SSH 将监听公网及私网地址；云安全组和已有防火墙仍需允许 SSH 端口。'
    fi
    begin_change "${2:-normal}"
    keep_ssh_alive
    remove_directive ListenAddress
    managed_set ListenAddress "$addresses"
    finish_change "${2:-normal}"
}
rescue_public_ssh() {
    # Explicit emergency action: never restore a broken private listener first.
    # Retain all previous snapshots, but cancel the pending timeout rollback.
    simple_config_check
    validate_sshd
    systemctl disable --now linux-server-tool-rollback.timer || true
    if [[ -f $BASE/pending ]]; then
        mv -- "$BASE/pending" "$BASE/cancelled-pending-$(date +%s)-$RANDOM"
    fi
    connection_mode public rescue
}
install_keys() {
    local line tmp count=0 root_home
    init_key_config
    root_home=$(getent passwd root | cut -d: -f6)
    [[ $root_home == /root ]] || die '本版本要求 root 主目录为 /root。'
    tmp=$(mktemp)
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
        [[ $line == ssh-* || $line == ecdsa-* || $line == sk-* ]] || die '公钥格式不正确（不支持带前置选项的公钥）。'
        printf '%s\n' "$line" > "$tmp"
        ssh-keygen -lf "$tmp" >/dev/null || die "公钥校验失败，请修改 $KEY_CONFIG。"
        ((count+=1))
    done < "$KEY_CONFIG"
    rm -f "$tmp"
    ((count > 0)) || die "请先在 SSH 菜单第 8 项编辑 $KEY_CONFIG，每行填写一把完整公钥。"
    install -d -m 700 -o root -g root /root/.ssh
    [[ ! -L /root/.ssh/authorized_keys ]] || die 'authorized_keys 为符号链接，停止修改。'
    [[ ! -f /root/.ssh/authorized_keys ]] || cp -a /root/.ssh/authorized_keys "$BASE/authorized_keys-$(date +%s).bak"
    touch /root/.ssh/authorized_keys
    # Separate an existing final line that has no newline.
    printf '\n' >> /root/.ssh/authorized_keys
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
        grep -qxF "$line" /root/.ssh/authorized_keys || printf '%s\n' "$line" >> /root/.ssh/authorized_keys
    done < "$KEY_CONFIG"
    chown root:root /root/.ssh /root/.ssh/authorized_keys
    chmod 700 /root/.ssh; chmod 600 /root/.ssh/authorized_keys
    command -v restorecon >/dev/null && restorecon -RF /root/.ssh || true
}
key_login() {
    simple_config_check
    install_keys
    begin_change
    managed_set PubkeyAuthentication yes
    managed_set AuthorizedKeysFile .ssh/authorized_keys
    managed_set PermitRootLogin yes
    managed_set PasswordAuthentication yes
    managed_set AuthenticationMethods any
    finish_change
    say '公钥为追加写入；回退 SSH 配置时不会删除已添加的公钥。'
}
disable_password_login() {
    simple_config_check
    say '请使用已经配置好的公钥新建连接，确认本次修改；未确认将在 3 分钟后回退。'
    begin_change
    managed_set PubkeyAuthentication yes
    managed_set PasswordAuthentication no
    managed_set KbdInteractiveAuthentication no
    managed_set ChallengeResponseAuthentication no
    managed_set AuthenticationMethods publickey
    finish_change
    say '已关闭所有用户密码/交互式登录；已有公钥和公钥文件路径保持不变。'
}
# Temporary keys have their own registry. Existing authorized keys are never
# restored from a snapshot: additions/removals operate on the current file.
temp_key_paths() {
    [[ $(getent passwd root | cut -d: -f6) == /root ]] || die '本版本要求 root 主目录为 /root。'
    TEMP_ROOT=$BASE/temporary-keys
    TEMP_AUTH=/root/.ssh/authorized_keys
    [[ ! -L /root/.ssh && ! -L $TEMP_AUTH && ! -L $TEMP_ROOT ]] || die '临时密钥路径不能是符号链接。'
    [[ ! -e $TEMP_AUTH || -f $TEMP_AUTH ]] || die 'authorized_keys 不是普通文件。'
    install -d -m 700 -o root -g root /root/.ssh "$TEMP_ROOT"
}
temp_key_preflight() {
    need ssh-keygen; need sshd
    simple_config_check
    validate_sshd
    local effective methods
    effective=$(sshd -T)
    grep -qx 'pubkeyauthentication yes' <<< "$effective" || die '请先在 SSH 菜单启用公钥登录。'
    grep -Eq '^permitrootlogin (yes|prohibit-password|without-password)$' <<< "$effective" || die '请先在 SSH 菜单启用 root 公钥登录。'
    awk '$1=="authorizedkeysfile" {for(i=2;i<=NF;i++) if($i==".ssh/authorized_keys" || $i=="/root/.ssh/authorized_keys" || $i=="%h/.ssh/authorized_keys") ok=1} END {exit !ok}' <<< "$effective" || die 'SSH 未读取 /root/.ssh/authorized_keys，请先在 SSH 菜单配置公钥登录。'
    methods=$(awk '$1=="authenticationmethods" {$1=""; print}' <<< "$effective")
    [[ " $methods " =~ [[:space:]](any|publickey)[[:space:]] ]] || die '当前 SSH 要求额外认证，不能仅凭临时私钥登录；请先调整 SSH 登录方式。'
}
temp_key_publish() {
    local staged=$1
    chmod 600 "$staged"
    chown root:root "$staged"
    if command -v restorecon >/dev/null; then restorecon -F "$staged"; fi
    mv -f -- "$staged" "$TEMP_AUTH"
}
temp_key_file() {
    local dir=$1 id=${1##*/}
    if [[ $id =~ ^key-[a-zA-Z0-9]{8}$ ]]; then
        printf '%s/lts-%s\n' "$dir" "${id#key-}"
    elif [[ $id =~ ^key-[0-9]{8}T[0-9]{6}Z-[a-zA-Z0-9]{24}$ ]]; then
        printf '%s/lts-%s\n' "$dir" "$id"
    else
        printf '%s/id_ed25519\n' "$dir"
    fi
}
temp_key_open_dir() (
    local dir=$1
    cd -- "$dir" || return $?
    # Do not hold the operation lock while the user downloads files.
    flock -u 9 2>/dev/null || true
    exec 9>&-
    say '已进入密钥目录。现在可从 Xshell 打开 Xftp/文件管理器下载私钥。'
    say '下载后输入 exit 返回工具菜单；关闭此临时 Shell 不会撤销密钥。'
    # Xshell/Xftp use the terminal title to discover the current directory.
    export PROMPT_COMMAND='printf "\033]0;root@server:%s\007" "$PWD"'
    export PS1='[lts-key-download] \w # '
    printf '\033]0;root@server:%s\007' "$PWD"
    bash --noprofile --norc -i || true
)
temp_key_create() (
    temp_key_paths
    temp_key_preflight
    local dir id keyfile staged=''
    dir=$(mktemp -d "$TEMP_ROOT/key-XXXXXXXX")
    id=${dir##*/}
    keyfile=$(temp_key_file "$dir")
    # Keep the registry on failures so any already-published key remains revocable.
    trap '[[ -z $staged ]] || rm -f -- "$staged"' EXIT
    ssh-keygen -q -t ed25519 -N '' -C "lts-tool-temp:$id" -f "$keyfile"
    chmod 600 "$keyfile" "$keyfile.pub"
    date -u +%Y-%m-%dT%H:%M:%SZ > "$dir/created-at"
    staged=$(mktemp "${TEMP_AUTH%/*}/.lts-key.XXXXXXXX")
    if [[ -f $TEMP_AUTH ]]; then
        cp --preserve=all -- "$TEMP_AUTH" "$staged"
        if [[ -s $staged && $(tail -c 1 "$staged" | wc -l) == 0 ]]; then printf '\n' >> "$staged"; fi
    fi
    cat "$keyfile.pub" >> "$staged"
    temp_key_publish "$staged"
    staged=''
    say "临时 root 密钥已生成并添加。编号：$id"
    say "私钥文件（在这台服务器上）：$keyfile"
    say "公钥指纹：$(ssh-keygen -lf "$keyfile.pub")"
    say '私钥无口令，文件权限为 600；请通过现有可信连接下载到执行维护的电脑。'
    say '客户端示例（替换私钥本地路径、服务器地址及端口）：'
    say "  ssh -o IdentitiesOnly=yes -i /本地路径/${keyfile##*/} -p SSH端口 root@服务器地址"
    say "维护结束后撤销：$SELF --temp-key-revoke $id"
    say '这是完整 root 权限。密钥不会自动过期；维护结束后请撤销。'
    if [[ -t 0 && -t 1 ]]; then
        temp_key_open_dir "$dir"
    else
        say "密钥目录：$dir（非交互运行，不打开 Shell）"
    fi
)
temp_key_list() {
    temp_key_paths
    local dir id keyfile found=0
    TEMP_KEY_IDS=()
    for dir in "$TEMP_ROOT"/key-*; do
        [[ -d $dir && ! -L $dir ]] || continue
        keyfile=$(temp_key_file "$dir")
        # Keep incomplete cleanup selectable, but hide completed revocations.
        if [[ -f $dir/revoked-at && ! -e $keyfile && ! -L $keyfile && ! -e $keyfile.pub && ! -L $keyfile.pub ]]; then
            continue
        fi
        found=1; id=${dir##*/}
        TEMP_KEY_IDS+=("$id")
        say "${#TEMP_KEY_IDS[@]}) $id"
        if [[ -f $dir/revoked-at ]]; then
            say "$id  已撤销，密钥文件清理未完成；可选择该编号继续清理。"
        elif [[ -f $keyfile.pub ]]; then
            say "$id  未撤销（授权是否可用以实际 SSH 登录为准）"
            say "  私钥：$keyfile"
            ssh-keygen -lf "$keyfile.pub"
        else
            say "$id  生成未完成；未添加公钥，可选择该编号清理。"
        fi
    done
    ((found)) || say '没有临时维护密钥。'
}
temp_key_revoke() (
    temp_key_paths
    local id=${1:-} dir keyfile type blob comment selection staged=''
    if [[ -z $id ]]; then
        temp_key_list
        ((${#TEMP_KEY_IDS[@]} > 0)) || return 0
        read -r -p '输入上方数字序号（留空返回）：' selection
        [[ -n $selection ]] || return 0
        [[ $selection =~ ^[0-9]{1,9}$ ]] || die '请输入列表中的数字序号。'
        selection=$((10#$selection))
        ((selection >= 1 && selection <= ${#TEMP_KEY_IDS[@]})) || die '序号不在列表范围内。'
        id=${TEMP_KEY_IDS[selection-1]}
    fi
    [[ $id =~ ^key-([a-zA-Z0-9]{8}|[0-9]{8}T[0-9]{6}Z-([a-zA-Z0-9]{8}|[a-zA-Z0-9]{24}))$ ]] || die '密钥编号格式不正确。'
    dir=$TEMP_ROOT/$id
    [[ -d $dir && ! -L $dir ]] || die '找不到该临时密钥。'
    keyfile=$(temp_key_file "$dir")
    [[ ! -L $keyfile.pub ]] || die '公钥记录不能是符号链接。'
    trap '[[ -z $staged ]] || rm -f -- "$staged"' EXIT
    if [[ -f $keyfile.pub ]]; then
        read -r type blob comment < "$keyfile.pub"
        [[ $type == ssh-ed25519 && -n $blob ]] || die '公钥记录损坏，停止撤销。'
        ssh-keygen -lf "$keyfile.pub" >/dev/null
        if [[ -f $TEMP_AUTH ]]; then
            staged=$(mktemp "${TEMP_AUTH%/*}/.lts-key.XXXXXXXX")
            cp --preserve=all -- "$TEMP_AUTH" "$staged"
            # Match key material, not comments; preserve every unrelated line.
            awk -v t="$type" -v b="$blob" '!($1==t && $2==b)' "$TEMP_AUTH" > "$staged"
            if grep -qF -- "$blob" "$staged"; then
                die '该公钥可能被手工添加了选项或复制到其他行；未修改授权，请先人工检查对应公钥。'
            fi
            temp_key_publish "$staged"
            staged=''
        fi
    elif [[ -f $dir/created-at && ! -f $dir/revoked-at ]]; then
        die '已生成密钥的公钥记录丢失，不能确认撤销；请人工检查 authorized_keys。'
    fi
    # Record completed authorization removal before deleting the public record,
    # so retries after an interrupted cleanup remain safe and idempotent.
    [[ -f $dir/revoked-at ]] || date -u +%Y-%m-%dT%H:%M:%SZ > "$dir/revoked-at"
    rm -f -- "$keyfile" "$keyfile.pub"
    say "已撤销 $id：对应公钥授权已移除，服务器上的公钥和私钥文件已删除。"
    say '已有 SSH 会话不会被断开；请结束维护会话并删除下载到其他电脑的私钥副本。'
)
temp_key_revoke_all() {
    temp_key_paths
    local dir
    for dir in "$TEMP_ROOT"/key-*; do
        [[ -d $dir && ! -L $dir ]] || continue
        temp_key_revoke "${dir##*/}"
    done
    say '本工具登记的临时密钥已全部撤销，对应公钥和私钥文件已删除，其他密钥保留。'
}
temp_key_menu() {
    local c
    while true; do
        say $'\n临时维护密钥（root）：\n1) 一键生成并添加临时密钥\n2) 查看密钥列表及私钥路径\n3) 按数字序号撤销临时密钥并删除公钥和私钥\n4) 撤销全部临时密钥并删除公钥和私钥\n0) 返回'
        read -r -p '请选择：' c
        case $c in
            1) run_action temp_key_create;; 2) run_action temp_key_list;;
            3) run_action temp_key_revoke;; 4) run_action temp_key_revoke_all;;
            0) return;; *) say '无效选择。';;
        esac
    done
}
change_port() {
    local port effective
    read -r -p '新 SSH 端口（1-65535）：' port
    [[ $port =~ ^[0-9]{1,5}$ ]] || die '端口必须是数字。'
    port=$((10#$port)); ((port >= 1 && port <= 65535)) || die '端口超出范围。'
    if ss -H -ltn | awk '{print $4}' | grep -Eq ":$port$"; then die '该端口已有监听服务，请换一个端口。'; fi
    simple_config_check
    local f
    while IFS= read -r f; do
        if grep -Eiq '^[[:space:]]*ListenAddress[[:space:]]+(\[[^]]+\]|[0-9.]+):[0-9]+' "$f"; then
            die 'ListenAddress 中指定了独立端口，请先通过连接模式菜单统一监听地址，再修改端口。'
        fi
    done < <(ssh_files)
    say "请先在云安全组和本机防火墙放行 TCP $port；脚本不修改已有防火墙。"
    ask '已完成放行，继续修改？' || return
    if command -v getenforce >/dev/null && [[ $(getenforce) == Enforcing ]]; then
        need semanage
        semanage port -a -t ssh_port_t -p tcp "$port" || die 'SELinux 端口添加失败，请检查端口标签。'
    fi
    begin_change
    remove_directive Port
    managed_set Port "$port"
    effective=$(sshd -T | awk '$1=="port" {print $2}')
    [[ $effective == "$port" ]] || die '实际 SSH 端口不符合预期，等待自动回退。'
    finish_change
}

dns_addresses() {
    { awk '$1=="nameserver" {print $2}' /etc/resolv.conf
      if command -v resolvectl >/dev/null; then resolvectl dns 2>/dev/null || true; fi
      if command -v nmcli >/dev/null; then nmcli -g IP4.DNS,IP6.DNS device show 2>/dev/null || true; fi
    } | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort -u || true
}
dns_check() {
    local addr second conflict=0
    say '检测到的 IPv4 DNS（含上游 DNS）：'
    dns_addresses
    while IFS= read -r addr; do
        [[ $addr == 100.* ]] || continue
        if [[ $addr == 100.100.100.100 ]] && systemctl is-active --quiet tailscaled; then
            say "$addr：可能是 Tailscale MagicDNS，本身不是云厂商 DNS 冲突。"
            continue
        fi
        second=${addr#100.}; second=${second%%.*}
        if ((10#$second >= 64 && 10#$second <= 127)); then
            say "$addr：位于 Tailscale 的 100.64.0.0/10，存在冲突风险。"; conflict=1
        else
            say "$addr：属于 100.*，但不在 Tailscale 的冲突网段。"
        fi
    done < <(dns_addresses)
    if ((conflict)); then dns_menu; fi
}
change_dns() (
    local servers=$1 backup uuid dev
    backup=$BASE/dns-$(date +%s)-$RANDOM
    install -d "$backup"
    cp -a /etc/resolv.conf "$backup/resolv.conf"
    printf '#!/usr/bin/env bash\nset -eu\n' > "$backup/restore.sh"
    say "DNS 备份：$backup；恢复命令：bash $backup/restore.sh"
    trap 'rc=$?; trap - ERR; say "DNS 修改失败，尝试恢复原配置。"; bash "$backup/restore.sh" || true; exit "$rc"' ERR
    if systemctl is-active --quiet NetworkManager; then
        need nmcli
        while IFS=: read -r uuid dev; do
            [[ -n $dev && $dev != lo && $dev != tailscale0 ]] || continue
            local prop old
            for prop in ipv4.dns ipv6.dns ipv4.ignore-auto-dns ipv6.ignore-auto-dns; do
                old=$(nmcli -g "$prop" connection show "$uuid")
                printf 'nmcli connection modify %q %q %q\n' "$uuid" "$prop" "$old" >> "$backup/restore.sh"
            done
            printf 'nmcli device reapply %q\n' "$dev" >> "$backup/restore.sh"
            nmcli connection modify "$uuid" ipv4.dns "$servers" ipv4.ignore-auto-dns yes ipv6.dns '' ipv6.ignore-auto-dns yes
            nmcli device reapply "$dev"
        done < <(nmcli -t -f UUID,DEVICE connection show --active)
    elif systemctl is-active --quiet systemd-resolved; then
        local cfg=/etc/systemd/resolved.conf.d/90-linux-server-tool.conf
        install -d /etc/systemd/resolved.conf.d
        if [[ -f $cfg ]]; then
            cp -a "$cfg" "$backup/resolved.conf"
            printf 'cp -a %q %q\n' "$backup/resolved.conf" "$cfg" >> "$backup/restore.sh"
        else printf 'rm -f %q\n' "$cfg" >> "$backup/restore.sh"; fi
        printf 'rm -f /etc/resolv.conf\ncp -a %q /etc/resolv.conf\nsystemctl restart systemd-resolved\n' "$backup/resolv.conf" >> "$backup/restore.sh"
        printf '[Resolve]\nDNS=%s\nFallbackDNS=\nDomains=~.\n' "$servers" > "$cfg"
        ln -sfn /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
        systemctl restart systemd-resolved
    else
        say '未使用 NetworkManager/systemd-resolved，不能可靠持久化 DNS；未修改。'
        say '请先在当前网络管理器中修改 DNS，再重新安装。'
        return 1
    fi
    chmod 700 "$backup/restore.sh"
    if ! timeout 20 getent ahosts tailscale.com >/dev/null; then
        say 'DNS 验证失败，恢复原配置。'
        bash "$backup/restore.sh"
        return 1
    fi
    say "DNS 已修改。恢复命令：bash $backup/restore.sh"
    say '公共 DNS 无法解析云厂商专用内部域名；如依赖这些域名，请恢复原配置并另配分流。'
)
dns_menu() {
    local choice
    say 'DNS：1) 谷歌  2) 阿里云  3) 腾讯云  0) 不修改'
    read -r -p '请选择：' choice
    case $choice in
        1) change_dns '8.8.8.8 8.8.4.4';;
        2) change_dns '223.5.5.5 223.6.6.6';;
        3) change_dns '119.29.29.29';;
        0) say '保留当前 DNS。';;
        *) die '无效选择。';;
    esac
}
tailscale_persist() {
    install -d /etc/systemd/system/tailscaled.service.d
    cat > /etc/systemd/system/tailscaled.service.d/90-linux-server-tool.conf <<'EOF'
[Unit]
StartLimitIntervalSec=0
[Service]
Restart=always
RestartSec=5s
EOF
    systemctl daemon-reload
    systemctl enable --now tailscaled.service
    systemctl restart tailscaled.service
    systemctl is-active --quiet tailscaled.service
}
read_tailscale_hostname() {
    local name
    read -r -p 'Tailscale 主机名（留空保留）：' name
    [[ -n $name ]] || return 0
    [[ ${#name} -le 63 && $name =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || die '主机名须为 1-63 位字母、数字、短横线，首尾不能是短横线。'
    printf '%s' "$name"
}
rename_host() {
    local name
    name=$(read_tailscale_hostname)
    [[ -n $name ]] || return 0
    tailscale set --hostname="$name"
    say "Tailscale 名称已设为 $name（Linux 系统 hostname 保持原值）。"
}
tailscale_install_login() {
    local name
    local -a flags=(--accept-dns=false --ssh=false)
    name=$(read_tailscale_hostname) || return $?
    [[ -z $name ]] || flags+=("--hostname=$name")
    say '请打开接下来显示的链接完成授权；授权完成后会应用主机名。'
    say '默认不接管服务器 DNS、不启用 Tailscale SSH；通过普通 OpenSSH 公钥登录。'
    # Carry the chosen name into initial registration. A pre-login `set` can
    # belong to a different/empty profile and be lost when authorization finishes.
    tailscale up "${flags[@]}" || return $?
    # Reapply to the now-authorized profile. Never announce success before this.
    tailscale set --accept-dns=false --ssh=false || return $?
    if [[ -n $name ]]; then
        tailscale set --hostname="$name" || return $?
        say "授权已完成，Tailscale 名称已设为 $name（Linux 系统 hostname 保持原值）。"
    fi
}
tailscale_install() {
    dns_check
    if ! command -v curl >/dev/null; then
        if command -v apt-get >/dev/null; then
            apt-get update
            apt-get install -y curl ca-certificates
        elif command -v dnf >/dev/null; then dnf install -y curl ca-certificates
        elif command -v yum >/dev/null; then yum install -y curl ca-certificates
        else die '请先通过系统包管理器安装 curl 和 ca-certificates。'; fi
    fi
    local installer
    installer=$(mktemp)
    curl --proto '=https' --tlsv1.2 --fail --show-error --location https://tailscale.com/install.sh -o "$installer"
    # Official installer selects the stable repository for the detected distro.
    env -u TAILSCALE_VERSION sh "$installer"
    rm -f "$installer"
    tailscale_persist
    say '安装成功；填写 Tailscale 主机名后完成登录授权。'
    tailscale_install_login
    tailscale status
    say '可在子菜单 4/5 中切换 SSH 私网/公网监听方式。'
}
status() {
    say '=== SSH ==='
    ensure_sshd_runtime
    sshd -T 2>/dev/null | awk '$1 ~ /^(port|listenaddress|permitrootlogin|passwordauthentication|authenticationmethods)$/ {print}' || true
    ss -ltnp || true
    say '=== Tailscale ==='
    if command -v tailscale >/dev/null; then tailscale status || true; fi
    systemctl show tailscaled -p ActiveState -p Restart -p RestartUSec -p UnitFileState || true
    [[ ! -f $BASE/pending ]] || say "待确认：$(cat "$BASE/pending")"
}
tailscale_session_address() {
    local addr=$1 second
    case $addr in
        fd7a:115c:a1e0:*) return 0;;
        100.*) second=${addr#100.}; second=${second%%.*}
            [[ $second =~ ^[0-9]{1,3}$ ]] && ((10#$second >= 64 && 10#$second <= 127));;
        *) return 1;;
    esac
}
tailscale_suggested_flags() {
    local log=$1 mode=$2 line arg force=no
    local -a parts
    grep -q 'non-default flags' "$log" || return 1
    line=$(sed -n -E '/^[[:space:]]*tailscale up --/ {p;q;}' "$log")
    read -r -a parts <<< "$line"
    [[ ${parts[0]:-} == tailscale && ${parts[1]:-} == up && ${#parts[@]} -gt 2 ]] || return 1
    for arg in "${parts[@]:2}"; do
        # Data-only argv parsing: no eval, shell expansion, quotes or commands.
        [[ $arg =~ ^--[a-z0-9-]+(=[a-zA-Z0-9_.,:/%+@=-]+)?$ ]] || return 1
        case $arg in --reset*|--auth-key*|--authkey*|--accept-risk*|--client-secret*) return 1;; esac
        [[ $arg != --force-reauth ]] || force=yes
    done
    [[ $mode == reauth && $force == yes || $mode == connect && $force == no ]] || return 1
    printf '%s\n' "${parts[@]:2}"
}
tailscale_auth() (
    local mode=$1 log rc=0 retry client client_port server server_port flags
    local -a args=()
    need tailscale; need timeout
    if [[ $mode == reauth ]]; then
        if [[ -n ${SSH_CONNECTION:-} ]]; then
            read -r client client_port server server_port <<< "$SSH_CONNECTION"
            if tailscale_session_address "$client" || tailscale_session_address "$server"; then
                say 'Re-authentication blocked: this SSH session may use Tailscale. Use VNC or public SSH.'
                return 1
            fi
        fi
        say '强制重新授权会中断 Tailscale 网络。请在 VNC 或已确认可用的公网 SSH 中操作。'
        ask '现在发起强制重新授权？' || { say '已取消，未修改登录状态。'; return 0; }
        args+=(--force-reauth)
    fi
    systemctl start tailscaled.service || return $?
    log=$(mktemp "$BASE/tailscale-auth.XXXXXXXX") || return $?
    trap 'rm -f -- "$log"' EXIT
    say 'Starting Tailscale authentication/connection (timeout: 180 seconds).'
    say '如需授权，下方会显示登录链接，请在浏览器中完成。'
    for retry in 0 1; do
        if timeout --foreground --kill-after=5s 180s tailscale up "${args[@]}" 2>&1 | tee "$log"; then
            say 'Tailscale 连接/授权命令已成功完成；已登录时普通连接不会生成新链接。'
            timeout --foreground --kill-after=5s 15s tailscale status || true
            say '若仅私网 SSH 且重新授权后节点 IP 改变，请在 VNC 中重新选择 SSH 仅私网。'
            return 0
        else
            rc=${PIPESTATUS[0]}
        fi
        if [[ $retry == 0 ]] && flags=$(tailscale_suggested_flags "$log" "$mode"); then
            mapfile -t args <<< "$flags"
            say '正在按 Tailscale 提示保留已有非默认配置并重试（不会使用 --reset）。'
            continue
        fi
        break
    done
    say "Tailscale 操作未完成，退出码：$rc。"
    [[ $rc != 124 && $rc != 137 ]] || say '等待授权/连接超时；请检查登录是否完成及服务器网络，稍后重试。'
    say '上方保留了原始错误；排查命令：tailscale status；journalctl -u tailscaled -n 50 --no-pager'
    return 1
)
tailscale_auth_menu() {
    local c
    while true; do
        say $'\nTailscale 登录：\n1) 正常登录/恢复连接（已登录则保留）\n2) 强制重新授权（请使用 VNC 或公网 SSH）\n0) 返回'
        read -r -p '请选择：' c
        case $c in
            1) if bash "$SELF" --tailscale-connect; then :; else say '连接未完成，请查看上方错误。'; fi;;
            2) if bash "$SELF" --tailscale-reauth; then :; else say '重新授权未完成，请查看上方错误。'; fi;;
            0) return;; *) say '无效选择。';;
        esac
    done
}
tailscale_menu() {
    local c
    while true; do
        say $'\nTailscale：\n1) 官方安装/更新最新稳定版\n2) 检测 DNS\n3) 修改公共 DNS\n4) SSH 仅私网\n5) SSH 私网+公网（VNC 恢复）\n6) 修改 Tailscale 主机名\n7) 修复服务自启/自动重启\n8) 状态\n9) 登录/重新授权\n0) 返回'
        read -r -p '请选择：' c
        case $c in
            1) run_action tailscale_install;; 2) run_action dns_check;; 3) run_action dns_menu;;
            4) run_action connection_mode private;; 5) run_action connection_mode public;;
            6) run_action rename_host;; 7) run_action tailscale_persist;; 8) run_action status;;
            9) tailscale_auth_menu;; 0) return;; *) say '无效选择。';;
        esac
    done
}
ssh_menu() {
    local c
    while true; do
        say $'\nSSH：\n1) 安装 root 公钥并启用公钥登录，允许密码登录\n2) 关闭所有用户密码/交互式登录\n3) 修改 SSH 端口\n4) SSH 仅私网\n5) SSH 私网+公网\n6) 查看状态\n7) 回退待确认修改\n8) 编辑长期公钥配置\n0) 返回'
        read -r -p '请选择：' c
        case $c in
            1) run_action key_login;; 2) run_action disable_password_login;; 3) run_action change_port;;
            4) run_action connection_mode private;; 5) run_action connection_mode public;;
            6) run_action status;; 7) run_action rollback;; 8) run_action edit_key_config;; 0) return;; *) say '无效选择。';;
        esac
    done
}
main() {
    if [[ ${1:-} == --version ]]; then say "lts-tool $VERSION"; return; fi
    if [[ ${1:-} == tailscale ]]; then
        (($# == 1)) || die '用法：lts-tool tailscale'
        need tailscale
        tailscale status
        return
    fi
    root_check
    need flock
    exec 9>"$BASE/lock"
    if [[ ${1:-} == --health-check ]]; then
        flock -n 9 || return 0
        health_check
        return
    fi
    flock 9
    # Recovery must work even when an older pending change blocks installation.
    if [[ ${1:-} == --rescue-ssh ]]; then rescue_public_ssh; return; fi
    # Do not hold the lock while an interactive menu waits for input.
    init_key_config
    install_self
    case ${1:-} in
        --install) health_default_enable force; say "lts-tool 安装/更新完成，健康守护已默认启用。长期公钥配置保留在 $KEY_CONFIG。执行 sudo lts-tool 打开菜单。"; return;;
        --update) update_tool; return;;
        --health-enable) health_enable; return;;
        --health-disable) health_disable; return;;
        --health-status) health_status; return;;
        --bbr-enable) no_pending; bbr_enable; return;;
        --bbr-status) bbr_status; return;;
        --tailscale-connect) no_pending; tailscale_auth connect; return;;
        --tailscale-reauth) no_pending; tailscale_auth reauth; return;;
        --confirm) confirm_change "${2:-}"; return;;
        --rollback) rollback; return;;
        --public-ssh) [[ ! -f $BASE/pending ]] || rollback; connection_mode public; return;;
        --status) status; return;;
        --temp-key-create) no_pending; temp_key_create; return;;
        --temp-key-list) temp_key_list; return;;
        --temp-key-revoke) [[ -n ${2:-} ]] || die '请提供临时密钥编号。'; temp_key_revoke "$2"; return;;
        --temp-key-revoke-all) temp_key_revoke_all; return;;
        '') health_default_enable;;
        *) die '参数：--version | --update | --bbr-enable | --bbr-status | --health-enable | --health-disable | --health-status | --status | --tailscale-connect | --tailscale-reauth | --rescue-ssh | --public-ssh | --rollback | --confirm 确认码 | --temp-key-create | --temp-key-list | --temp-key-revoke 编号 | --temp-key-revoke-all';;
    esac
    flock -u 9
    local c
    while true; do
        say $'\nLinux 服务器工具\n1) Tailscale 管理\n2) SSH 管理\n3) 临时维护密钥（root）\n4) 更新工具\n5) 健康守护\n6) 谷歌 BBR（永久启用）\n0) 退出'
        read -r -p '请选择：' c
        # Submenus run in a child, so errors return to the main menu.
        case $c in
            1) bash "$SELF" --internal-tailscale || say '操作中止。若已启动回退计时，计时仍会继续。';;
            2) bash "$SELF" --internal-ssh || say '操作中止。若已启动回退计时，计时仍会继续。';;
            3) bash "$SELF" --internal-temp-keys || say '临时密钥操作中止，请查看提示。';;
            4) update_menu;;
            5) health_menu;;
            6) bbr_menu;;
            0) return;; *) say '无效选择。';;
        esac
    done
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    # Each selected operation gets its own process. No lock is held at a prompt.
    if [[ ${1:-} == --internal-tailscale || ${1:-} == --internal-ssh || ${1:-} == --internal-temp-keys ]]; then
        root_check
        case $1 in
            --internal-tailscale) tailscale_menu;;
            --internal-ssh) ssh_menu;;
            --internal-temp-keys) temp_key_menu;;
        esac
    else
        main "$@"
    fi
fi
