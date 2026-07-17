# frm-node 中文节点管理器

`frm-node` 是面向 Debian/Ubuntu VPS 的中文多协议节点管理器。它只负责编排官方核心、配置、systemd 服务、诊断和客户端导出，不自行实现代理协议。

当前版本：`0.1.0-dev`。这是进入服务器实测前的开发版。

## 已实现协议

| 协议 | 服务端实现 | 部署模式 |
|---|---|---|
| VLESS Reality Vision | Xray-core | 原生 RAW + REALITY |
| AnyTLS | anytls-go | 原生 TCP |
| Hysteria2 | 官方 Hysteria | 原生 UDP，可选 Salamander |
| Snell v4 | Surge 官方服务端 | 原生；可选 ShadowTLS v3 |
| Snell v5 | Surge 官方服务端 | 原生；可选 ShadowTLS v3 |
| Snell v6 Beta | Surge 官方服务端 | 仅原生，不叠加 ShadowTLS |

TUIC v5、Shadowsocks 2022、NaiveProxy 和证书型 VLESS/Trojan 计划放入下一阶段，当前菜单不会显示尚未实现的选项。

## 系统要求

- Debian 11+ 或 Ubuntu 22.04+
- systemd
- `amd64` 或 `arm64`；Snell 额外支持官方提供的部分旧架构
- 公网 IPv4；云厂商安全组需要同步放行节点端口

## 一键安装

在线安装：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/godsonkg/frm-node/main/bootstrap.sh)
```

`FRM_REF` 支持分支、tag 或 commit，配合 `FRM_SHA256` 可以把安装内容固定到已知版本，降低仓库被篡改时的供应链风险：

```bash
FRM_REF=<commit或tag> FRM_SHA256=<安装包校验值> bash <(curl -fsSL .../bootstrap.sh)
```

安装器每次都会打印安装包的 SHA-256，首次可信安装后记下即可用于下次校验。更稳妥的做法是先下载并检查 `bootstrap.sh`，再以 root 执行。离线上传完整目录后可直接运行：

```bash
bash install.sh
```

安装完成会创建两个等价入口：

```bash
frm
frm-node
```

如果系统已有名为 `frm` 的程序，安装器不会覆盖它，此时使用 `frm-node`。

## 常用命令

```bash
frm                         # 中文菜单
frm status                  # 全部实例状态
frm install reality         # 安装 Reality
frm install anytls          # 安装 AnyTLS
frm install hysteria2       # 安装 Hysteria2
frm install snell4          # 安装原生 Snell v4
frm install snell4-shadowtls
frm install snell5
frm install snell5-shadowtls
frm install snell6          # Snell v6 Beta，仅原生
frm show all                # 导出客户端配置
frm doctor                  # 中文完整诊断
frm logs <实例> --follow
frm update                  # 备份后更新已安装核心
frm backup
frm restore <备份文件>
frm uninstall <实例>
frm adopt scan             # 只读识别旧脚本和独立 Snell
frm adopt report           # 生成可分享的脱敏清单
frm adopt register         # 原地登记，不重启、不改配置
frm adopt forget <实例>    # 只撤销登记，不影响原节点
frm adopt takeover         # 备份后完整接管旧控制面
frm adopt takeover-status  # 查看接管状态与备份校验
frm adopt rollback         # 回滚最近一次完整接管
frm watch setup            # 配置 Telegram 推送监控
frm watch status           # 查看监控状态（Token 打码显示）
frm watch test             # 发送测试推送
frm watch accept-ports     # 自装新服务后更新端口基线
frm watch accept-cron      # 自改 crontab 后更新基线
frm watch off / on         # 停用 / 启用定时巡检
frm sub fragment           # 生成 Surge/Loon/Mihomo 干净片段
frm sub check              # 自动生成并脱敏检查权限、结构、数量和协议跳过
frm sub status             # 查看片段文件状态
```

## 旧节点兼容接管

当前可识别 `mack-a/v2ray-agent`、`chil30-group/vless-all-in-one`，以及常见官方 Snell 独立安装。`adopt register` 会保留原 IP、端口、凭据、核心、systemd 单元、证书和定时任务，只把节点登记到 frm-node，属于零中断的兼容接管。

兼容接管实例可以统一查看、导出、诊断、启停和读取日志。为保护共用的 Xray/sing-box 核心，它们暂时不能由 `frm update` 覆盖，也不能通过普通 `uninstall` 删除。可使用 `frm adopt forget <实例>` 安全撤销登记。

独立 Snell 如果无法从配置或二进制确定大版本，脚本会拒绝猜测。确认是 v6 后可执行：

```bash
FRM_ADOPT_SNELL_VERSION=6 frm adopt register
```

`takeover` 采用原地控制面接管：接管前逐实例检查，完整备份旧配置、二进制、systemd unit、frm 注册表和 root crontab；随后冻结旧管理器的自动任务并停用 `vless-watchdog`，但不重写协议配置、不改变端口和密钥，也不重启数据服务。接管后检查失败会自动恢复控制面。

每次接管都会在 `/var/lib/frm-node/takeovers/<时间>/` 保存 `payload.tar.gz`、SHA-256、接管清单和接管前注册表。回滚命令恢复 cron、watchdog 与兼容登记状态，不重启协议服务：

```bash
frm adopt takeover-status
frm adopt rollback [接管编号]
```

原地接管的共享核心继续禁止普通 `frm uninstall` 和盲目 `frm update`，后续应使用专门的来源适配更新流程。
旧脚本会保留在备份和原路径中供回滚使用；接管后不要再手工运行旧脚本的安装、更新或卸载菜单，以免两个管理器同时改写配置。

## 推送监控（frm watch）

`frm watch` 是零暴露面的 Telegram 推送监控：无监听端口、无常驻进程、无 Web 面板，由 systemd timer 周期拉起一次巡检后立即退出（默认 5 分钟一轮）。

监控内容：

- 实例服务与端口健康，异常即时告警、恢复自动通知（同一问题 6 小时内不重复推送）
- 磁盘占用（85% 提醒 / 95% 严重）
- 月流量用量（需安装 vnstat 并在配置中填写配额，80%/95% 各提醒一次）
- 每次 SSH 登录成功即推送来源 IP（可配置已知 IP 白名单减噪）
- 基线外新增监听端口告警（疑似后门植入）。为避免误报：已知代理核心（xray、sing-box、anytls-server、snell-server、hysteria 等，可用 `WATCH_UDP_RELAY_PROCS` 覆盖）中转 UDP/QUIC 流量的临时端口不计入监听面；其余新端口需连续两轮巡检都出现才告警，真正驻留的后门最多晚一个巡检周期被发现
- root crontab 内容变化告警（疑似持久化后门）
- 每日固定时刻推送巡检日报

安全约束：Bot Token 只保存在 `/etc/frm-node/watch.env`（600）；推送消息永不包含密码、PSK、UUID、私钥或订阅地址，默认不包含端口号。配置走 `frm watch setup` 交互完成，请勿把 Token 粘贴到聊天或截图。

## 私有订阅 Phase 1（零新增暴露面）

每台 VPS 可生成 Surge、Loon、Mihomo 三种干净节点片段。片段不含 `frm show` 的分节标题、提示横幅和说明文字：

```bash
frm sub fragment --prefix US-EXAMPLE
frm sub check --prefix US-EXAMPLE
frm sub status
```

文件保存在 `/var/lib/frm-node/sub/`，目录权限 `700`、文件权限 `600`。经 SSH 拉取时必须指定一种格式：

```bash
frm sub fragment --format surge --prefix US-EXAMPLE --stdout
frm sub fragment --format loon --prefix US-EXAMPLE --stdout
frm sub fragment --format mihomo --prefix US-EXAMPLE --stdout
```

默认名称为 `<机器前缀>-<协议>`。为兼容现有精调配置的旧节点名，可只导出一个实例并指定精确名称：

```bash
frm sub fragment --format surge --stdout \
  --instance frm-anytls-443 --name 'US-EXAMPLE-AnyTLS'
```

客户端支持按现有导出器能力严格处理：AnyTLS、Trojan 可输出三种格式；Hysteria2 通常可输出三种格式，但启用 Salamander 时不生成不确定的 Loon 单行；Reality 输出 Loon/Mihomo；Snell 只输出 Surge；TUIC 当前只输出 Mihomo。不能确认兼容的组合会跳过并在 stderr 给出数量提示。

家里电脑可用 Git Bash 汇总多台 VPS。真实 SSH 地址和节点别名不要提交仓库，先从脱敏示例复制到仓库外：

```bash
cp examples/sub-hosts.example.tsv /安全位置/hosts.tsv
cp examples/sub-aliases.example.tsv /安全位置/aliases.tsv
bash tools/frm-sub-collect.sh \
  --inventory /安全位置/hosts.tsv \
  --aliases /安全位置/aliases.tsv \
  --output /安全位置/frm-sub-output
```

汇总器同时生成两套产物：`providers/` 是 Surge `policy-path`、Loon 待实机导入验证的纯节点列表和 Mihomo proxy-provider 使用的节点集合；`snippets/` 带 `[Proxy]` 或 `proxies:` 外壳，供嵌入手工精调配置。它会在写入前拒绝重复节点名，但不会修改现有配置、策略组或规则。

Phase 1 只复用现有 SSH，不增加监听端口。所有产物都含完整节点凭据，禁止上传公开 Git、网盘或聊天。HTTPS 自动订阅属于 Phase 2，必须在 Phase 1 实测稳定后另行部署。

## 文件布局

```text
/opt/frm-node/                 管理器代码
/etc/frm-node/instances/       节点配置与凭据（600）
/var/lib/frm-node/bin/         协议核心
/var/lib/frm-node/instances/   JSON 实例注册表
/var/lib/frm-node/backups/     本机备份
/var/lib/frm-node/sub/         本机订阅片段（700/600）
/usr/local/bin/frm             快速入口
/usr/local/bin/frm-node        完整入口
```

旧版 FRM AnyTLS + Hysteria2 管理脚本会被只读识别并导入注册表，不修改已经运行的服务参数。

## 安全设计

- 密码、PSK、UUID 和私钥只保存在服务器，权限为 `600`；ShadowTLS 密码经 `EnvironmentFile` 注入，不明文写入 systemd unit。
- `frm show` 会输出敏感节点信息，禁止粘贴到公开 Issue、日志或截图。
- 每次核心更新前自动备份；新核心启动失败则回滚二进制。日常备份只保留最近 7 份。
- Reality 目标必须通过 TLS 1.3 和证书主机名检查，并限制未鉴权回落流量，降低被扫描滥用的风险。
- Hysteria2 自签证书会记录 SHA-256 指纹，导出配置携带 `fingerprint` / `pinSHA256` 钉扎，即使客户端跳过 CA 验证也能抵御中间人。
- Snell v6 的 PSK 每个实例独立随机生成；v6 不提供 ShadowTLS 模式。
- 下载文件会记录 SHA-256 到本机日志；Snell 官方包可在 `versions.env` 中钉扎校验值，安装器支持 `FRM_REF`+`FRM_SHA256` 固定版本。

## 开发检查

```bash
find . -type f \( -name '*.sh' -o -name 'frm-node' \) -print0 | xargs -0 -n1 bash -n
shellcheck -x frm-node install.sh bootstrap.sh lib/*.sh protocols/*.sh tests/*.sh
bash tests/smoke.sh
bash tests/adopt-smoke.sh
bash tests/watch-smoke.sh
bash tests/sub-smoke.sh
bash tests/sub-collect-smoke.sh
```
