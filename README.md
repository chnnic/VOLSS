# VOLSS - Shadowsocks-Rust 一键管理脚本

> 版本: V1.4.0 · 快捷命令: `volss`

一个适用于 NAT 机/VPS 的 Shadowsocks-Rust 交互式安装与管理脚本，支持多用户管理、流量统计、ACL 黑名单规则集、时间同步等功能。

---

## 功能概览

- 一键安装/卸载/更新最新版 Shadowsocks-Rust
- 交互式选择加密方式、端口分配策略、用户数量
- 顺序端口或随机端口分配，自动跳过已占用端口
- 多用户管理：暂停、恢复、删除（支持多选）、重新生成
- 基于 iptables 的每用户流量统计（GB），持久化保存，重启不丢失
- ACL 黑名单：手动添加域名 + 规则集一键安装（广告/色情/赌博/BT/恶意软件/金融等）
- 手动域名与规则集完全分离管理，互不干扰
- 手动删除支持逗号分隔多选批量操作
- systemd / OpenRC 双服务管理：启动、停止、重启、日志
- 快捷命令 `volss` 随时呼出管理菜单
- 时间同步：HTTP/NTP 标准时间校准
- 自动修复：快捷命令丢失自动重建，ACL 格式异常自动修复
- GitHub 下载镜像自动切换，提高国内下载成功率

---

## 系统要求

| 项目 | 要求 |
|------|------|
| 系统 | Debian / Ubuntu / Alpine |
| 权限 | root |
| 架构 | x86_64 / aarch64（Alpine 额外支持 armv7l） |
| 依赖 | wget、openssl、python3、iproute2、xz-utils、iptables-persistent（自动安装） |

> **OpenWrt / ImmortalWrt 用户**：请直接使用 `opkg install shadowsocks-rust-ssserver` 安装，配合 procd 管理服务，不要使用本脚本。

---

## 快速开始

**1. 下载并运行脚本**

```bash
wget -O volss.sh https://raw.githubusercontent.com/chnnic/VOLSS/refs/heads/main/volss.sh && chmod +x volss.sh && bash volss.sh
```

或者分步执行：

```bash
wget -O volss.sh https://raw.githubusercontent.com/chnnic/VOLSS/refs/heads/main/volss.sh
chmod +x volss.sh
bash volss.sh
```

首次运行进入主菜单，选择 `1) 安装 Shadowsocks-Rust` 开始安装。

**2. 安装完成后使用快捷命令**

```bash
volss
```

---

## 安装流程说明

选择安装后，脚本会依次引导完成以下配置：

### 第一步：选择加密方式

```
1) 2022-blake3-aes-128-gcm        (推荐，密钥16字节)
2) 2022-blake3-aes-256-gcm        (强加密，密钥32字节)
3) 2022-blake3-chacha20-poly1305   (ARM推荐，密钥32字节)
4) aes-256-gcm                    (传统，兼容性好)
5) chacha20-ietf-poly1305         (传统，兼容性好)
```

> 推荐使用 `2022-blake3-aes-128-gcm`，性能与安全性均衡。

### 第二步：填写服务器信息

输入服务器域名或 IP，留空则自动检测。支持 DDNS 域名（如 `your-domain.example.com`）。

### 第三步：端口分配

```
1) 顺序端口 —— 从指定起始端口开始，自动跳过已占用端口
2) 随机端口 —— 在指定范围内随机挑选可用端口
```

**顺序模式示例：**
```
起始端口: 50001
生成数量: 5

端口 50001 可用 ✓
端口 50002 已占用，跳过
端口 50003 可用 ✓
端口 50004 可用 ✓
端口 50005 可用 ✓
端口 50006 可用 ✓
```

**随机模式示例：**
```
端口范围: 20000 ~ 60000
生成数量: 5

端口 43521 已分配 ✓
端口 28974 已分配 ✓
...
```

### 第四步：配置 ACL 黑名单（可选）

输入需要屏蔽的域名，每行一个，空行结束。安装完成后也可随时通过菜单增删，或安装规则集。

---

## 菜单功能

```
  =================================================
    Shadowsocks-Rust 管理脚本    V1.4.0    快捷命令: volss
  =================================================
    安装: ● 已安装        服务: ● 运行中
    时间: 已同步 (±1s)
  -------------------------------------------------
    -- 安装管理 --
      1)  安装 Shadowsocks-Rust
      2)  卸载 Shadowsocks-Rust
      3)  更新脚本
    -- 用户管理 --
      4)  查看用户列表
      5)  查看所有 SS 链接
      6)  暂停某个用户
      7)  恢复某个用户
      8)  删除某个用户
      9)  重新生成所有用户
    -- 流量统计 --
     10)  查看流量统计
     11)  重置流量统计
    -- ACL 黑名单 --
     12)  手动添加屏蔽域名
     13)  手动删除屏蔽域名
     14)  查看黑名单列表
     15)  规则集管理（广告/色情/赌博/BT等）
    -- 服务管理 --
     16)  查看服务状态
     17)  启动服务
     18)  停止服务
     19)  重启服务
     20)  查看实时日志
     21)  时间同步
  -------------------------------------------------
     0)  退出
  =================================================
```

---

## 功能详解

### 用户管理

| 功能 | 说明 |
|------|------|
| 查看用户列表 | 显示所有用户的端口、加密方式、状态（正常/暂停） |
| 查看 SS 链接 | 输出所有 `ss://` 格式链接，可直接导入客户端 |
| 暂停用户 | 将指定用户从运行配置中移除，不删除数据 |
| 恢复用户 | 重新将暂停的用户加入运行配置 |
| 删除用户 | 永久删除用户配置、链接及对应 iptables 规则 |
| 重新生成所有用户 | 保留端口数量和加密方式，重新生成所有密码 |

### 更新脚本

选择菜单选项 `3) 更新脚本`：

- 从 GitHub 拉取最新版本
- 自动对比本地与远程版本号
- 版本相同则提示无需更新
- 发现新版本询问确认后更新
- 更新前自动备份当前脚本为 `.bak`
- 更新时自动执行配置迁移修复，兼容旧版配置
- 修复内容包括：ACL 格式迁移（domain-suffix → ||）、服务文件 Restart 策略升级、ExecStop 钩子补全
- 完成后自动重启进入新版菜单

### 流量统计

基于 iptables 对每个端口单独计数，统计维度：

- **上行（GB）**：服务端发送给客户端的流量（用户下载）
- **下行（GB）**：客户端发送给服务端的流量（用户上传）
- **最后重置时间**：显示该用户流量上次被手动清零的时间

流量数据持久化保存至 `/etc/shadowsocks-rust/traffic.json`，服务停止前自动触发保存（通过 systemd ExecStop 或 OpenRC stop_pre 钩子），重启后累计显示，**不受重启影响**，直到手动重置才清零。

> **注意：统计数值为单向流量。** 由于代理服务器每个字节都要经过一进一出，VPS 实际消耗的带宽约为统计数值的 **2 倍**。例如显示上行 21GB，实际带宽消耗约为 42GB。

### ACL 黑名单

通过 Shadowsocks-Rust 的 ACL 功能屏蔽指定域名，被屏蔽的域名请求将被直接拒绝。手动域名与规则集**完全分离**，互不干扰。

**手动添加（选项 12）**：逐条输入域名，自动去重检查。

**手动删除（选项 13）**：列出手动添加的域名，支持**逗号分隔多选批量删除**（如 `1,3,5`），不会误删规则集内容。

**查看列表（选项 14）**：分区显示手动域名和已安装规则集及条数。

### 规则集管理（选项 15）

可按需选择安装以下规则集，每个规则集独立存储和管理：

| 规则集 | 说明 |
|--------|------|
| ads | 广告拦截 |
| adult | 色情网站 |
| gambling | 赌博网站 |
| malware | 恶意软件/钓鱼 |
| scam | 诈骗欺诈 |
| tracking | 追踪统计 |
| crypto | 挖矿劫持 |
| dating | 交友网站 |
| bt | BT/种子下载 |
| finance | 金融理财 |

规则集子菜单功能：单个安装、一键全装、卸载、更新、添加自定义 URL、查看规则数量统计。

> 下载失败时自动切换 GitHub 镜像（gitmirror / fastgit / 99988866），提高国内可用性。

> 规则集更新时会自动保留所有手动添加的域名，不会被覆盖。

> ACL 匹配只在新连接建立时执行，不影响已建立连接的传输速度。规则集较大时每次新连接会增加数毫秒匹配延迟，对普通使用影响可忽略。

### 时间同步（选项 21）

通过 HTTP HEAD 请求获取标准时间（优先 Cloudflare → Google → Baidu），显示本地时间偏差：

- ±2 秒内：绿色 "已同步"
- ±10 秒内：黄色 "本地快/慢 Ns"
- 超过 10 秒：红色警告

确认后自动安装 chrony/ntpdate 进行系统时间校准。主菜单顶部实时显示时间状态（60 秒缓存避免频繁网络请求）。

### 快捷命令自检修复

每次执行 `volss` 时自动检测：
- 快捷命令是否存在且指向正确 → 不存在则自动重建
- ACL 文件格式是否正常（domain-suffix / invalid headers）→ 异常则自动修复并重启服务

---

## SS 链接格式

生成的链接符合标准 `ss://` 格式，兼容主流客户端：

```
ss://base64(method:password)@host:port#用户N
```

**兼容客户端：**

| 平台 | 推荐客户端 |
|------|-----------|
| Windows | v2rayN、Clash Verge |
| macOS | Clash Verge、Hiddify |
| Linux | NekoRay、Clash Meta |
| Android | v2rayNG、Hiddify、Sing-box |
| iOS | Shadowrocket、Sing-box |

---

## 文件说明

| 路径 | 说明 |
|------|------|
| `/usr/local/bin/ssserver` | Shadowsocks-Rust 主程序（Alpine: `/usr/bin/ssserver`） |
| `/usr/local/bin/volss` | 快捷命令入口 |
| `/usr/local/bin/volss.sh` | 脚本主体（固定安装路径） |
| `/etc/shadowsocks-rust/config.json` | 完整配置（含 disabled 标记） |
| `/etc/shadowsocks-rust/runtime.json` | 运行时配置（仅含启用用户，过滤 disabled） |
| `/etc/shadowsocks-rust/ss_links.txt` | 所有用户 SS 链接 |
| `/etc/shadowsocks-rust/traffic.json` | 流量历史持久化数据 |
| `/etc/shadowsocks-rust/blocklist.acl` | ACL 黑名单主文件 |
| `/etc/shadowsocks-rust/manual.list` | 手动添加的域名列表（纯净格式） |
| `/etc/shadowsocks-rust/rulesets/` | 规则集存储目录（.acl 文件） |
| `/etc/systemd/system/shadowsocks-rust.service` | systemd 服务文件（Debian/Ubuntu） |
| `/etc/init.d/shadowsocks-rust` | OpenRC 服务文件（Alpine） |

---

## 常见问题

**Q: 支持 OpenWrt / ImmortalWrt 吗？**

不支持。本脚本依赖 systemd/OpenRC、iptables-persistent、apt/apk 等组件，OpenWrt 使用 procd 管理服务、fw4/nftables 管理防火墙、opkg 管理包，两者差异过大。OpenWrt 用户请直接执行：

```bash
opkg update
opkg install shadowsocks-rust-ssserver
```

然后手动创建 `/etc/init.d/shadowsocks-rust` procd 启动脚本进行管理。

**Q: 支持 Alpine Linux 吗？**

支持。脚本自动识别 Alpine 系统，使用 OpenRC 管理服务、apk 安装依赖、musl 版本二进制，部署路径和包名均自动适配。

**Q: 菜单显示"未运行"但连接正常？**

部分 LXC 容器宿主机会定期向容器内进程发送 SIGTERM 信号，导致 ssserver 被杀后立即重启。脚本改用 `pgrep` 检测进程是否实际存在，不再依赖 systemctl 状态，显示更准确。如果频繁断连影响使用，建议联系服务商关闭该限制。

**Q: 如何更新脚本？**

进入菜单选择 `3) 更新脚本`，脚本会自动从 GitHub 拉取最新版本，对比版本号后询问确认，更新前自动备份当前版本为 `.bak` 文件，更新时自动迁移修复旧版配置，完成后自动重启进入新版菜单。

**Q: GitHub 下载失败怎么办？**

规则集下载内置 4 个镜像源自动切换（raw.githubusercontent.com → gitmirror → fastgit → 99988866），脚本更新和 Shadowsocks-Rust 二进制下载仍走 GitHub 直连。如持续失败，请检查 VPS 网络环境。

**Q: 安装规则集会影响代理速度吗？**

ACL 匹配只在新连接建立时执行，不影响已建立连接的传输速度。少量手动规则几乎无感；大规则集每次新连接会增加数毫秒匹配延迟，对普通浏览和流媒体影响不大。如对延迟敏感，建议只安装最必要的规则集。

**Q: NAT 机如何使用？**

NAT 机通常只开放有限端口，填写起始端口时请使用服务商分配的可用端口段。服务器地址填写服务商提供的公网 IP 或 DDNS 域名。

**Q: 重启服务器后流量数据会丢失吗？**

不会。流量数据持久化保存，服务停止前自动触发保存（systemd ExecStop / OpenRC stop_pre 钩子），重启后从文件读取累计显示，只有手动重置才会清零。

**Q: 暂停和删除有什么区别？**

暂停仅将用户从运行配置中移除，数据保留，可随时恢复。删除会永久移除用户的所有配置和链接，不可恢复。

**Q: 手动添加的域名会被规则集更新覆盖吗？**

不会。手动添加的域名存储在独立的 `manual.list` 文件中，规则集更新时自动保留，两者完全分离管理。

**Q: 可以同时安装 Alpine 和 Debian 吗？**

不需要。脚本自动检测当前系统类型，在 Alpine 上使用 musl 版本二进制 + OpenRC 服务 + apk 包管理，在 Debian/Ubuntu 上使用 gnu 版本 + systemd + apt，无需手动切换或配置。

---

## 版本历史

| 版本 | 说明 |
|------|------|
| V1.4.0 | 新增 Alpine Linux 支持（OpenRC + musl + apk）；新增时间同步功能（菜单选项 21）；新增 GitHub 镜像自动切换；删除支持逗号分隔多选批量操作；新增金融理财规则集；新增快捷命令自检修复；新增 ACL 格式自检修复；主菜单显示实时时间状态 |
| V1.3.0 | 内测版本整合 |
| V1.2.3 | 规则集菜单对齐修复；新增金融理财规则集；README 明确不支持 OpenWrt |
| V1.2.2 | 重新整理菜单编号，1-20 完全连续；更新脚本移至选项 3 |
| V1.2.1 | 手动域名与规则集完全分离，删除操作不会误删规则集内容 |
| V1.2.0 | 新增规则集管理，支持广告/色情/赌博/BT等分类一键安装 |
| V1.1.6 | 依赖新增 xz-utils，修复解压失败问题 |
| V1.1.5 | 修复 ACL 域名格式（domain-suffix → \|\|），修复 ACL 不生效问题 |
| V1.1.4 | 更新脚本时自动迁移修复旧版配置 |
| V1.1.3 | ACL 配置移至顶层，修复 ss-rust 1.24 不读取 server 块 acl 字段的问题 |
| V1.1.2 | 修复新机器首次安装无快捷命令问题，启动时自动自检修复 |
| V1.1.1 | 流量统计显示最后重置时间 |
| V1.1.0 | 流量统计持久化，重启不丢失，手动重置才清零 |
| V1.0.9 | 流量统计标注单向流量，提示实际带宽消耗约为 x2 |
| V1.0.8 | 修复快捷命令路径问题，脚本固定安装至 /usr/local/bin/volss.sh |
| V1.0.7 | 注册快捷命令前检查是否被其他脚本占用，避免覆盖 |
| V1.0.6 | 服务状态检测改用 pgrep，修复 LXC 容器环境误判问题 |
| V1.0.5 | 服务文件 Restart 改为 always，确保异常退出后自动重启 |
| V1.0.4 | 流量统计单位从 MB 改为 GB |
| V1.0.3 | 修复 ACL 配置错误（bypass_all → bypass_list） |
| V1.0.2 | 修复下载格式错误（.tar.gz → .tar.xz），改用 wget，加入更新功能 |
| V1.0.1 | 优化菜单样式，移除竖线边框 |
| V1.0.0 | 初始版本 |

---

## License

MIT
