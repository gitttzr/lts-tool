# Linux 服务器工具

提供 Tailscale、SSH、临时维护密钥和更新工具四个主菜单，各有子菜单。脚本文件：`linux-server-tool.sh`。

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

**SSH：**追加 root 公钥并允许密码登录、关闭所有用户密码及交互式登录、修改端口、私网/公网切换、状态、回退。

第 1 项负责从 `/etc/lts-tool/root_authorized_keys` 导入 root 公钥。第 2 项仅调整登录认证方式，不再导入公钥，也不修改已有公钥文件、AuthorizedKeysFile 路径或 PermitRootLogin 设置；请先确认已有公钥能够登录，再使用第 2 项。第 2 项仍保留三分钟未确认自动回退机制。

**临时维护密钥（root）：**一键生成并添加临时密钥、查看列表和私钥路径、撤销指定密钥、一键撤销全部临时密钥。

**更新工具：**一键更新到仓库 main 分支最新版本、查看当前版本和更新来源。更新成功会自动重新打开新版主菜单。

也可直接运行 `sudo lts-tool --update`，或用 `lts-tool --version` 查看版本。更新先下载文件，验证 SHA-256 及 Bash 语法，再原子替换工具；下载或校验失败保留当前版本。相同内容不重复安装。更新保留 `/etc/lts-tool/root_authorized_keys`、已有 SSH 授权和临时密钥记录，不修改 SSH/Tailscale 设置。存在待确认的 SSH 修改时，请先确认或回退后再更新。

菜单更新会在 `/var/lib/linux-server-tool/lts-tool.previous` 保留上一版程序，可在控制台用 `sudo install -m 700 /var/lib/linux-server-tool/lts-tool.previous /usr/local/sbin/lts-tool` 恢复。直接重新运行安装器也能更新，但不会额外生成这份上一版备份。

启用密码登录不会设置或重置 root 密码，也不会解锁账户。账户锁定、PAM、AllowUsers/AllowGroups 等原有约束仍可能阻止登录，必须实际验证新连接。

## 临时授权 AI 维护

运行 `sudo lts-tool`，选择主菜单 **3**，再选择 **1**。也可以直接执行：

```bash
sudo lts-tool --temp-key-create
```

每次使用系统随机源生成新的 Ed25519 密钥对，不复用以前的私钥；每次生成有独立编号和目录。公钥追加到 `/root/.ssh/authorized_keys`，不替换已有公钥。生成后显示编号、指纹及私钥绝对路径，例如：

```text
临时 root 密钥已生成并添加。编号：key-20260930T120000Z-Ab12Cd34
私钥文件（在这台服务器上）：/var/lib/linux-server-tool/temporary-keys/key-20260930T120000Z-Ab12Cd34/id_ed25519
```

此路径位于 **Linux 服务器**，不是本地电脑路径，也不是下载网址。通过你现有的可信 SSH/SFTP 连接下载该文件到执行维护的电脑，再让 AI 使用本地私钥文件路径连接。私钥无口令，服务器上权限为 `600`，所在目录为 `700`；脚本不会在终端打印私钥正文。

客户端连接示例（替换地址、端口和私钥路径）：

```bash
chmod 600 /本地路径/id_ed25519
ssh -o IdentitiesOnly=yes -i /本地路径/id_ed25519 -p SSH端口 root@服务器地址
```

维护完成后，在主菜单 3 的子菜单选择 **3** 撤销指定编号，或选择 **4** 一键撤销全部临时密钥。也可执行：

```bash
sudo lts-tool --temp-key-list
sudo lts-tool --temp-key-revoke 实际密钥编号
sudo lts-tool --temp-key-revoke-all
```

撤销先从当前 authorized_keys 中移除对应公钥，再删除服务器上的对应私钥文件。因此，已下载的私钥副本也无法再通过这条授权建立新连接。其他公钥和其他尚未撤销的临时密钥保留；撤销全部只处理本工具登记的临时密钥。保留公钥与撤销时间记录，不保留被撤销私钥的备份。

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
/usr/local/sbin/lts-tool --public-ssh
```

此命令不依赖 Tailscale 在线。它保留现有 SSH 端口和认证方式，将 SSH 恢复为监听公网及私网地址。之后仍须在三分钟内新建 SSH 连接并执行确认命令；不确认会恢复此前模式。

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
- 私网模式让 OpenSSH 仅监听当前 Tailscale IPv4/IPv6 地址，适用于所有 SSH 用户，不影响其他服务。SSH 服务异常退出后重试启动，覆盖开机时 Tailscale 地址尚未就绪的情况。重新注册节点导致 Tailscale IP 改变时，需从控制台重新选择私网模式。
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

## 官方参考

- [Tailscale Linux 安装](https://tailscale.com/docs/install/linux)
- [Tailscale 保留地址](https://tailscale.com/docs/reference/reserved-ip-addresses)
- [Tailscale 节点名称](https://tailscale.com/kb/1098/machine-names)
- [OpenSSH sshd_config](https://man.openbsd.org/sshd_config)
- [OpenSSH 密钥生成](https://man.openbsd.org/ssh-keygen)
- [Google Public DNS](https://developers.google.com/speed/public-dns/docs/using)
- [腾讯 DNSPod Public DNS](https://docs.dnspod.com/public-dns/public-dns-guide/)
