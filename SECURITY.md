# 安全说明

`frm-node` 是面向个人自用的 VPS 节点管理器，以 root 运行。本文说明它的安全边界、已知取舍和漏洞报告方式。

## 报告漏洞

请通过 GitHub 私密安全公告（Security → Report a vulnerability）提交，不要开公开 Issue。

**报告中请勿附带真实的 UUID、密码、PSK、私钥、订阅地址或完整节点链接。** 用占位值复现即可。

这是个人业余项目，没有 SLA；会尽力在合理时间内处理。

## 安全设计

### 攻击面

frm-node **本身不监听任何端口，也没有常驻进程**：它是一次性执行的命令行工具，跑完即退。`frm watch` 由 systemd timer 周期拉起，同样跑完即退，只做主动外发推送（Telegram），不接受入站连接、没有 Web 面板、没有 API。

因此外部攻击者没有直接攻击 frm-node 的入口；能调用它的前提是已经取得 root。真正暴露在公网的是各协议核心（Xray、sing-box、Snell、Hysteria 等官方二进制）本身，这是节点的固有职责。

### 权限与凭据

- 凭据文件 `600`，实例与接管备份目录 `700`。
- ShadowTLS 密码经 `EnvironmentFile` 注入，不写入全局可读的 systemd unit。
- frm-node 原生创建的服务带 `NoNewPrivileges`、`ProtectSystem=strict`、`ProtectHome`、`PrivateTmp`。
- `frm watch` 的 Telegram 推送**永不包含**密码、PSK、UUID、私钥或订阅地址，默认也不包含端口号。
- Bot Token 只存 `/etc/frm-node/watch.env`（`600`）。

### 供应链

- 协议核心只从官方仓库/官方 CDN 经 HTTPS 下载。
- Snell 官方包在 `versions.env` 中钉扎 SHA-256，不匹配即中止安装（当前已钉扎 amd64）。
- 安装器支持 `FRM_REF`（tag/commit）+ `FRM_SHA256` 固定并校验安装包，见 README。
- 下载文件的 SHA-256 会记入本机日志。

### 已知取舍

以下是**有意识的选择**，不是疏漏：

1. **Reality 的 `skip-cert-verify`**：REALITY 协议本就借用真实站点证书做伪装，客户端靠 `public-key` + `short-id` 验证，不走 CA 链。这里的参数是协议要求，不构成弱点。

2. **AnyTLS / Trojan / TUIC 的 `skip-cert-verify`**：这些节点以纯 IP 提供服务、没有域名，无法签发受信证书。当前依赖协议自身的密码/UUID 认证。在能提供证书指纹的场景（如 frm-node 原生创建的 Hysteria2）已加入 SHA-256 指纹钉扎；其余协议的钉扎支持取决于客户端能力，仍在评估。**若你在敌意网络中使用，请优先选择 Reality 或已钉扎指纹的节点。**

3. **Xray / AnyTLS / Hysteria / ShadowTLS 跟随上游 latest**：未锁定版本与校验值，以换取安全更新的及时性和可维护性。核心更新前自动备份，启动失败自动回滚二进制。

4. **以 root 运行**：写 systemd unit、安装二进制、绑定端口所必需，无法避免。

5. **接管实例受保护**：来自旧脚本的 `adopted` / `taken-over` 实例禁止普通 `update` 与 `uninstall`，避免误伤共享核心。

## 使用者须知

- `frm show`、`frm sub fragment` 的输出**包含完整凭据**，等同密码，勿贴到 Issue、日志、截图或云笔记。
- 仓库内不得提交真实凭据；测试夹具一律使用占位值。
- 管理该项目的 GitHub 账号等同于所有部署机器的 root，请启用双因素认证。

## 支持范围

仅支持 `main` 分支的最新提交。当前版本标记为开发版，尚未做多发行版与多架构的完整验证。
