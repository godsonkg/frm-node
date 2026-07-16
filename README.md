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

更稳妥的做法是先下载并检查 `bootstrap.sh`，再以 root 执行。离线上传完整目录后可直接运行：

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
```

## 文件布局

```text
/opt/frm-node/                 管理器代码
/etc/frm-node/instances/       节点配置与凭据（600）
/var/lib/frm-node/bin/         协议核心
/var/lib/frm-node/instances/   JSON 实例注册表
/var/lib/frm-node/backups/     本机备份
/usr/local/bin/frm             快速入口
/usr/local/bin/frm-node        完整入口
```

旧版 FRM AnyTLS + Hysteria2 管理脚本会被只读识别并导入注册表，不修改已经运行的服务参数。

## 安全设计

- 密码、PSK、UUID 和私钥只保存在服务器，权限为 `600`。
- `frm show` 会输出敏感节点信息，禁止粘贴到公开 Issue、日志或截图。
- 每次核心更新前自动备份；新核心启动失败则回滚二进制。
- Reality 目标必须通过 TLS 1.3 和证书主机名检查，并限制未鉴权回落流量，降低被扫描滥用的风险。
- Snell v6 的 PSK 每个实例独立随机生成；v6 不提供 ShadowTLS 模式。
- 下载文件会记录 SHA-256 到本机日志。正式稳定版发布前还会加入经过实测的发布清单与校验值白名单。

## 开发检查

```bash
find . -type f \( -name '*.sh' -o -name 'frm-node' \) -print0 | xargs -0 -n1 bash -n
shellcheck -x frm-node install.sh bootstrap.sh lib/*.sh protocols/*.sh tests/*.sh
bash tests/smoke.sh
```
