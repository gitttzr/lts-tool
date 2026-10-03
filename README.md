# Linux 服务器工具

提供 Tailscale、SSH、临时维护密钥、更新工具、健康守护和谷歌 BBR 六个主菜单，各有子菜单。脚本文件：`linux-server-tool.sh`。

## 谷歌 BBR（1.0.11）

面向 Ubuntu 22.04 的 systemd VPS。主菜单 **6）谷歌 BBR → 1）启用并永久启用 BBR**，或 root 执行 `lts-tool --bbr-enable`；查看状态使用 `lts-tool --bbr-status`。

使用当前内核提供的原生 BBR，不更换内核。检测并加载 `tcp_bbr` 和 `sch_fq`，立即应用 `net.ipv4.tcp_congestion_control=bbr` 和 `net.core.default_qdisc=fq`，验证成功后提示完成。内核不支持或容器禁止修改时明确报错。

持久参数保存到 `/etc/sysctl.d/99-lts-tool-bbr.conf`，模块保存到 `/etc/modules-load.d/lts-tool-bbr.conf`。启用 `lts-tool-bbr.service`，每次启动在系统 sysctl 加载完成后重新应用这两个参数，避免原有 `/etc/sysctl.conf` 等设置覆盖；不修改其他调优文件。重复启用不会追加重复配置。升级脚本会保留这些设置。

无需重启即可对新 TCP 连接生效；不强制重建当前接口队列，也不打断已有连接。VPS 重启后可用 `lts-tool --bbr-status` 验证算法为 `bbr`、默认队列为 `fq`、开机服务已启用。之后其他工具改写参数、宿主机限制或更换为不支持 BBR 的内核仍可能影响生效；开机失败可查看 `journalctl -u lts-tool-bbr.service`。

## 使用

服务器上执行以下命令，下载安装器后安装或更新：

```bash
(set -e; f=$(mktemp); trap 'rm -f "$f"' EXIT; curl -fsSL https://raw.githubusercontent.com/gitttzr/lts-tool/main/install.sh -o "$f"; sudo bash "$f")
```

已用 root 登录且没有 sudo 的服务器，把最后的 `sudo bash "$f"` 改为 `bash "$f"`。初次下载需要 curl，安装器会检查并补齐其余基础依赖。服务器需要运行 systemd；SSH 管理需要已有 openssh-server。

安装器通过 HTTPS 下载脚本与 SHA-256 清单，校验并检查 Bash 语法后安装。校验用于检测损坏或版本不匹配，不是独立的签名验证。成功后执行 `sudo lts-tool` 打开菜单。**以后更新使用同一条命令**。

也可以手动下载脚本后执行：

```bash
sudo bash linux-server-tool.sh
```

脚本安装到 `/usr/local/sbin/lts-tool`。长期公钥独立保存在 `/etc/lts-tool/root_authorized_keys`，每行一把完整公钥，支持空行和 `#` 注释，不填写私钥。

首次安装后，在 **SSH 菜单 → 8）编辑长期公钥配置** 中填写公钥，再选择 **1）安装 root 公钥**。也可以使用文本编辑器修改：

```bash
sudo nano /etc/lts-tool/root_authorized_keys
```

配置文件权限为 `600`，目录权限为 `700`。更新不会覆盖已存在的配置；旧版 `/usr/local/sbin/lts-tool` 内嵌的公钥会在第一次升级时作为纯文本读取、验证并迁移，不会执行旧脚本。已存在的 `/root/.ssh/authorized_keys` 始终保留。若公钥只填在尚未安装的旧脚本里，请将其手动复制到独立配置。仓库仅包含 `root_authorized_keys.example` 示例，不包含用户真实公钥。

删除配置文件中的公钥不会自动撤销已导入的长期授权；本文件是导入来源，不是 SSH 实时读取的授权文件。

建议依次完成：安装 Tailscale → 授权登录 → 配置 root 公钥 → 用新连接验证 → 切换为仅私网 SSH。

## 菜单

**Tailscale：**官方安装/更新最新稳定版、DNS 检测与修改、SSH 私网/公网切换、修改 Tailscale 主机名、服务自启与自动重启、状态、登录授权。

快捷查询：`lts-tool tailscale`，直接显示 `tailscale status` 的原始输出并保留退出码，不进入菜单，不修改配置。

Tailscale 菜单第 9 项分为「正常登录/恢复连接」和「强制重新授权」。普通连接在已登录时不会产生新链接，但会明确显示完成状态；强制重新授权会重新请求浏览器授权，需要在 VNC 或已验证可用的公网 SSH 中执行，脚本会阻止检测到的 Tailscale SSH 会话发起此操作。

也可执行 `sudo lts-tool --tailscale-connect` 或 `sudo lts-tool --tailscale-reauth`。每次尝试最多等待 180 秒，原始输出直接显示；如 Tailscale 要求补齐非默认参数，脚本会安全读取不含引号/空格的建议参数并重试一次，不使用 `--reset`。复杂参数格式不自动执行，失败时保留错误用于排查。SSH_CONNECTION 被清除或经代理转接时，连接类型检测不一定可靠，因此强制重新授权仍应优先使用 VNC。如果重新授权后 Tailscale IP 改变，需在 VNC 重新选择 SSH 仅私网模式。

**SSH：**追加 root 公钥并允许密码登录、关闭所有用户密码及交互式登录、修改端口、私网/公网切换、状态、回退。

第 1 项负责从 `/etc/lts-tool/root_authorized_keys` 导入 root 公钥。第 2 项仅调整登录认证方式，不再导入公钥，也不修改已有公钥文件、AuthorizedKeysFile 路径或 PermitRootLogin 设置；请先确认已有公钥能够登录，再使用第 2 项。第 2 项仍保留三分钟未确认自动回退机制。

**临时维护密钥（root）：**一键生成并添加临时密钥、查看列表和私钥路径、撤销指定密钥、一键撤销全部临时密钥。

从 1.0.12 起，已撤销且公私钥文件已删除的密钥不再显示在列表中，也不占用选择序号；此前留下的撤销记录同样自动隐藏。清理中断仍有残留文件的记录会显示“密钥文件清理未完成”，可再次选择清理。

**更新工具：**一键更新到仓库 main 分支最新版本、查看当前版本和更新来源。更新成功会自动重新打开新版主菜单。

也可直接运行 `sudo lts-tool --update`，或用 `lts-tool --version` 查看版本。安装器和更新器先通过 GitHub API 获取 main 的提交编号，再从同一固定提交下载脚本与校验文件，避免分支缓存版本不一致；API 不可达或受限时停止并保留旧版本。更新验证 SHA-256 及 Bash 语法，再原子替换工具；下载或校验失败保留当前版本。相同内容不重复安装。更新保留 `/etc/lts-tool/root_authorized_keys`、已有 SSH 授权和临时密钥记录，不修改 SSH/Tailscale 连接或认证策略；1.0.7 起会默认启用健康守护。存在待确认的 SSH 修改时，请先确认或回退后再更新。

菜单更新会在 `/var/lib/linux-server-tool/lts-tool.previous` 保留上一版程序，可在控制台用 `sudo install -m 700 /var/lib/linux-server-tool/lts-tool.previous /usr/local/sbin/lts-tool` 恢复。直接重新运行安装器也能更新，但不会额外生成这份上一版备份。

启用密码登录不会设置或重置 root 密码，也不会解锁账户。账户锁定、PAM、AllowUsers/AllowGroups 等原有约束仍可能阻止登录，必须实际验证新连接。

## 健康守护（1.0.6）

从 1.0.7 起，首次安装、重新安装和升级默认启用健康守护，包括检查更新发现已经是最新版的情况。主菜单 **5）健康守护** 提供中文的启用、关闭、查看状态和日志选项。

从 1.0.6 或更早版本升级时，旧更新器不能执行新版启用步骤，因此首次进入新版主菜单会自动补齐；通过菜单更新会自动进入新版菜单。如果使用旧版命令行更新，完成后运行一次 `lts-tool` 即可。手动关闭后，普通重开菜单不会重新启用；下次安装或升级会重新启用。启用失败会报错，不会标记为成功。

也可以 root 执行：

```bash
lts-tool --health-enable
lts-tool --health-status
```

健康守护菜单和操作提示使用中文，后台诊断日志保留英文。启用会创建开机启动的 `lts-tool-health.timer`；每轮检查结束约 60 秒后再次检查，启动前 180 秒跳过。Tailscale 通过有超时的本地 `status --json` 检查响应，`Stopped`、`NeedsLogin` 等有响应状态不会触发重启。SSH 根据生效监听地址和端口执行本地 `ssh-keyscan` 密钥交换，单项最长约 10 秒（含强制结束等待），无需任何登录私钥。

每个服务连续三次探测失败才请求重启，每个服务两次重启请求至少间隔 600 秒。健康检查与工具操作共用非阻塞锁，忙碌或存在待确认的 SSH 修改时跳过。服务非 active 时不主动启动，尊重手动停止；崩溃和启动失败由原有 systemd 重启策略处理。SSH 配置无法读取时只记录错误，不盲目重启。

启用时仅增加服务停止超时（20 秒）及允许超时强制结束的独立配置，不立即重启 SSH/Tailscale，不改变监听地址、端口、公私网策略、公钥或登录状态。异常恢复会短暂影响对应连接。可执行 `lts-tool --health-disable` 停止守护并移除其独立服务配置，原有崩溃自动重启策略保留。日志：`journalctl -u lts-tool-health.service -n 50 --no-pager`。

本地探测不能保证端到端网络可达，也不能修复系统整体卡死、密钥过期、认证问题或重新注册后的 IP 变更。健康守护绝不自动开放公网、不自动重新授权。无法恢复时仍需 VNC 救援。恢复旧于 1.0.6 的脚本前先关闭健康守护，避免旧脚本不识别检查参数。

## 临时授权 AI 维护

从 1.0.9 起，每次生成 8 位随机字符：编号如 `key-A7k2m9Qx`，私钥文件名为 `lts-A7k2m9Qx`，公钥为 `lts-A7k2m9Qx.pub`。本机目录由 mktemp 排除已有名称；跨服务器随机重名概率很低，但不保证绝不重名。旧版密钥无需改名，查看和撤销继续兼容。

通过 SSH 交互式生成后，工具自动打开位于密钥目录的临时 Bash Shell；这时从 Xshell 打开 Xftp 或远程文件管理器即可按终端提供的当前目录定位。下载无 `.pub` 后缀的私钥文件，完成后输入 `exit` 返回菜单。工具会释放操作锁，避免下载期间阻塞健康守护。非交互运行只输出路径，不打开 Shell。

脚本不能改变调用它的父 Shell 的目录，因此使用临时子 Shell，不修改 `.bashrc` 或登录目录。目录同步采用 [NetSarang 官方说明的终端标题方式](https://netsarang.atlassian.net/wiki/spaces/ENSUP/pages/1076133906)，需要客户端支持；独立新建的 SFTP 会话不保证跟随。客户端若忽略终端标题，仍可使用输出的目录路径。

运行 `sudo lts-tool`，选择主菜单 **3**，再选择 **1**。也可以直接执行：

```bash
sudo lts-tool --temp-key-create
```

每次使用系统随机源生成新的 Ed25519 密钥对，不复用以前的私钥；每次生成有独立编号和目录。公钥追加到 `/root/.ssh/authorized_keys`，不替换已有公钥。生成后显示编号、指纹及私钥绝对路径，例如：

```text
临时 root 密钥已生成并添加。编号：key-A7k2m9Qx
私钥文件（在这台服务器上）：/var/lib/linux-server-tool/temporary-keys/key-A7k2m9Qx/lts-A7k2m9Qx
```

此路径位于 **Linux 服务器**，不是本地电脑路径，也不是下载网址。通过你现有的可信 SSH/SFTP 连接下载该文件到执行维护的电脑，再让 AI 使用本地私钥文件路径连接。私钥无口令，服务器上权限为 `600`，所在目录为 `700`；脚本不会在终端打印私钥正文。

客户端连接示例（替换地址、端口和私钥路径）：

```bash
chmod 600 /本地路径/lts-A7k2m9Qx
ssh -o IdentitiesOnly=yes -i /本地路径/lts-A7k2m9Qx -p SSH端口 root@服务器地址
```

维护完成后，在主菜单 3 的子菜单选择 **3**，按当次列表显示的数字序号撤销指定密钥；或选择 **4** 撤销全部临时密钥，两者都会删除对应公钥和私钥文件。序号随列表变化，命令行仍使用稳定的随机编号。也可执行：

```bash
sudo lts-tool --temp-key-list
sudo lts-tool --temp-key-revoke 实际密钥编号
sudo lts-tool --temp-key-revoke-all
```

撤销先从当前 authorized_keys 中移除对应公钥，再删除服务器上的对应公钥（.pub）和私钥文件。因此，已下载的私钥副本也无法再通过这条授权建立新连接。其他公钥和其他尚未撤销的临时密钥保留；撤销全部只处理本工具登记的临时密钥。仅保留创建/撤销时间等登记记录，不保留被撤销的公钥和私钥文件。旧版已撤销但遗留的公钥文件也可通过再次撤销清理。

临时密钥提供完整 root 权限，**不会自动过期**。撤销不会终止已经建立的 SSH 会话，也不会清理维护过程中另行创建的账户或授权。请在维护结束后退出会话，并删除下载到其他电脑的私钥副本。不要把临时公钥复制到其他授权文件，脚本只撤销其管理的 `/root/.ssh/authorized_keys` 中的对应记录。

此功能需要已经启用 root 公钥登录；否则会提示先在 SSH 菜单完成配置。它不修改密码登录方式、SSH 端口、私网/公网模式，不需要重启 SSH，也不需要三分钟确认。存在待确认 SSH 配置时不能新建临时密钥，但仍可列出和撤销密钥。复杂的 Match/自定义 Include 等配置会按现有兼容性规则停止操作。

## 防止修改后失联

SSH 修改前自动备份，启用 180 秒回退计时器。请保留当前连接，并在**新建的 SSH 连接**中执行脚本显示的命令：

```bash
/usr/local/sbin/lts-tool --confirm 实际确认码
```

非 root 用户使用 `sudo --preserve-env=SSH_CONNECTION` 执行确认命令。原会话和 VNC 会话不能确认，必须实际建立新的 SSH 连接。未确认则自动恢复先前配置。计时器也会在未确认就重启后重新计时；它依赖 systemd 和服务器正常运行，不能防止整机故障。

一次只能有一项待确认修改。公钥以追加方式写入，回退不会删除新公钥；原公钥文件另有备份。SSH 备份位于 `/var/lib/linux-server-tool/backup-*`，DNS 有独立备份和恢复脚本。不要在待确认的三分钟内手工修改 SSH 配置，以免被回退覆盖。

## VNC 紧急恢复

进入云厂商 VNC/串口控制台，以 root 执行：

```bash
/usr/local/sbin/lts-tool --rescue-ssh
```

此命令从 1.0.3 起可用，不依赖 Tailscale 在线。它先修复 `/run/sshd`，取消待确认修改的回退计时并保留其备份，直接将 SSH 恢复为监听公网及私网地址，不先恢复旧私网配置。端口、密钥和认证方式保留。**紧急恢复不会在三分钟后自动切回私网，也不需要确认码。** 之后可以用正常菜单重新选择仅私网，并完成新连接确认。

旧版工具如果无法更新、或有待确认配置阻止安装，可以在 VNC 中下载新版直接救援，然后安装新版：

```bash
curl -fL https://raw.githubusercontent.com/gitttzr/lts-tool/main/linux-server-tool.sh -o /root/lts-rescue.sh
bash /root/lts-rescue.sh --rescue-ssh
bash /root/lts-rescue.sh --install
```

请在上一条命令成功后再执行下一条。如果只能使用已安装旧版，可先执行 `install -d -m 0755 -o root -g root /run/sshd` 再恢复公网。旧版 `--public-ssh` 和普通菜单的公网切换仍有三分钟确认要求，勿与新版 `--rescue-ssh` 混淆。

公网连接还要求云安全组、本机防火墙放行当前 SSH 端口。切换为“私网+公网”不会启用密码登录，也不会修改防火墙。

其他命令：

```bash
sudo lts-tool --status
sudo lts-tool --rollback
```

## 实现范围与兼容性

- 面向运行 systemd、OpenSSH 的常见 VPS Linux，优先考虑 Debian/Ubuntu；其他发行版需要相应依赖。缺少 curl 时支持 apt/dnf/yum 安装。要求 Bash、coreutils、iproute2、util-linux/flock 等基础工具。不支持 Alpine/OpenRC、非 systemd 容器。
- Tailscale 使用官方 HTTPS 安装器，选择稳定源；不锁定版本。服务开机自启，退出后 5 秒重启，不设置重启次数上限。主动执行 `systemctl stop` 不会触发重启；网络断开、登录授权失效、进程假死也不等同于进程退出。
- 安装后提示设置的是 **Tailscale 节点名称**，不会修改 Linux 系统 hostname。首次使用必须完成 Tailscale 登录授权。填写的名称会随注册命令传入，并在授权完成后再次应用，成功后才显示修改完成；留空不会主动覆盖名称。已有节点若配置了出口节点、路由等额外非默认选项，`tailscale up` 可能要求补齐这些选项；脚本不会使用 `--reset` 清除它们。
- 默认关闭 Tailscale DNS 接管和 Tailscale SSH，使用系统 OpenSSH。DNS 接管关闭意味着此服务器不能仅依靠 Tailscale 自动配置来解析 MagicDNS 名称，可使用 Tailscale IP。
- 私网模式让 OpenSSH 仅监听当前 Tailscale IPv4/IPv6 地址，适用于所有 SSH 用户，不影响其他服务。从 1.0.3 起，SSH 服务策略清除默认退出码 255 禁止重试设置，并管理 `/run/sshd`；切换模式或执行紧急恢复会应用修复后的策略。只更新工具本身不会自动重启 SSH。重新注册节点导致 Tailscale IP 改变时，需从控制台重新选择私网模式。
- 会把 SSH 的 systemd socket 激活切换为普通服务启动，确保端口及监听地址以 sshd_config 为准。回退会恢复原 socket 的启用/运行状态。脚本添加的 SSH 自启状态不会撤销。
- 检测全部 `100.*` IPv4 DNS，真正的 Tailscale 地址冲突范围为 `100.64.0.0/10`。Tailscale 已运行时，`100.100.100.100` 会作为可能的 MagicDNS 提示，不自动判为云厂商 DNS 冲突。
- DNS 持久化支持 NetworkManager 和 systemd-resolved。其他网络管理方案会停止自动修改，避免仅修改 resolv.conf 后被 DHCP 覆盖。systemd-resolved 使用全局 `~.` 路由域；更具体的已有分流域仍可能走原 DNS。依赖云内部域名时需要专门配置分流。
- 谷歌 DNS：8.8.8.8 / 8.8.4.4；阿里云：223.5.5.5 / 223.6.6.6；腾讯 DNSPod：119.29.29.29。DNS 修改后验证 tailscale.com 解析，失败尝试恢复。
- 自动 SSH 配置仅支持主文件和标准 `/etc/ssh/sshd_config.d/*.conf`。发现活动 Match、自定义 Include 或符号链接配置会拒绝修改。自定义服务环境变量中的 SSH 参数、第三方配置管理、非标准 SSH 服务等需要人工核对。
- 修改端口不会代改云安全组或已有防火墙。SELinux Enforcing 环境需要 semanage 添加 ssh_port_t 标签；回退后添加的标签保留。

## 验证情况

已通过 Bash 语法检查，以及不需要 root 的配置改写测试：管理区块幂等性、配置优先顺序、IPv4/IPv6 监听切换、端口替换、DNS 冲突网段边界与 MagicDNS 识别。

临时密钥测试使用真实 ssh-keygen 和隔离的授权文件，验证连续生成不同密钥、公私钥匹配、单独/全部/重复撤销、无末尾换行的已有公钥、拒绝非法编号，以及撤销后已有授权文件逐字节不变。Linux 权限、sshd 接受密钥和 SELinux 行为仍需真实 VPS 集成验证。

另有配置迁移测试，验证旧版内嵌公钥只作为数据迁移、再次更新不覆盖已有配置、新安装创建空配置模板。

```bash
bash -n linux-server-tool.sh
bash test-linux-server-tool.sh
```

当前编写环境为 Windows，未在真实 Linux VPS 上完成安装、重启、SSH 登录和计时回退的集成测试。首次使用请保留 VNC 通道。

CI 另外在 Ubuntu 22.04/24.04 隔离容器中重现 `/run/sshd` 缺失，并用真实 OpenSSH 验证修复后的配置检查、受限地址登录及恢复所有地址后的登录。容器测试不覆盖真实 VPS 重启、systemd 调度和实际 Tailscale 网络，无法代替这些环境中的验证。

## 官方参考

- [Tailscale Linux 安装](https://tailscale.com/docs/install/linux)
- [Tailscale 保留地址](https://tailscale.com/docs/reference/reserved-ip-addresses)
- [Tailscale 节点名称](https://tailscale.com/kb/1098/machine-names)
- [OpenSSH sshd_config](https://man.openbsd.org/sshd_config)
- [OpenSSH 密钥生成](https://man.openbsd.org/ssh-keygen)
- [Google Public DNS](https://developers.google.com/speed/public-dns/docs/using)
- [腾讯 DNSPod Public DNS](https://docs.dnspod.com/public-dns/public-dns-guide/)
