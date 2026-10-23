# 参与贡献 / Contributing

**简体中文** | [English](#english)

感谢你愿意改进 frm-node。这是一个个人维护的业余项目，没有 SLA，但每个 Issue 和 PR 都会被认真阅读。

## 开始之前

- **安全漏洞**请走 [私密报告](https://github.com/godsonkg/frm-node/security/advisories/new)，不要开公开 Issue 或 PR。详见 [SECURITY.md](SECURITY.md)。
- **较大的改动**（新协议、新命令、改变现有行为）请先开 Issue 讨论，避免白写代码。
- **永远不要提交真实凭据**：密码、PSK、UUID、私钥、订阅地址、服务器 IP 和 `frm show` / `frm sub fragment` 的输出都不行。测试和示例只用占位值，IP 用 `192.0.2.x`、`198.51.100.x`、`203.0.113.x`（RFC 5737 文档地址），域名用 `example.com`。

## 项目原则

改动需要符合这些原则，否则很可能不会被合并：

1. **只编排官方核心**：frm-node 不自行实现代理协议。新协议必须有官方或上游维护的服务端实现，并通过 HTTPS 从官方来源下载。
2. **不增加攻击面**：frm-node 本身不监听端口、不常驻、没有 Web 面板或 API。`frm watch` 只做主动外发推送。
3. **凭据不外泄**：凭据文件保持 `600`，实例目录 `700`；凭据不写入 systemd unit、日志、推送消息或诊断输出。
4. **对现有节点保守**：接管、诊断、检查类命令默认只读；会修改系统的操作必须先备份，失败要能回滚。
5. **不猜测**：无法确认的版本、格式或客户端兼容性，宁可拒绝并说明原因，也不要输出可能错误的配置。

## 开发环境

需要 Bash、[jq](https://jqlang.github.io/jq/) 和 [ShellCheck](https://www.shellcheck.net/)。测试使用临时目录和模拟的服务与网络，**不需要 root，也不会操作 VPS**。请在仓库根目录运行，不要用安装脚本代替测试。

```bash
find . -type f \( -name '*.sh' -o -name 'frm-node' \) -print0 | xargs -0 -n1 bash -n
find . -type f \( -name '*.sh' -o -name 'frm-node' \) -print0 | xargs -0 shellcheck -x
bash tests/smoke.sh
bash tests/adopt-smoke.sh
bash tests/watch-smoke.sh
bash tests/sub-smoke.sh
bash tests/certpin-smoke.sh
bash tests/sub-collect-smoke.sh
bash tests/update-smoke.sh
```

这与 CI（`.github/workflows/test.yml`）的检查范围一致，提交 PR 前请确保全部通过。

## 代码结构

| 路径 | 内容 |
|---|---|
| `frm-node` | 命令入口、参数分发与中文菜单 |
| `lib/` | 通用模块：注册表、下载、服务、防火墙、导出、诊断、维护、接管、监控、订阅、证书钉扎 |
| `protocols/` | 每种协议的安装逻辑（`protocol_install_<名称>`） |
| `tests/` | 各功能的 smoke test |
| `tools/` | 在本地电脑运行的辅助脚本（如订阅汇总） |
| `versions.env` | frm-node 版本号，以及 Snell 版本与 SHA-256 钉扎值 |

## 代码风格

- Bash 脚本以 `#!/usr/bin/env bash` 开头，入口和测试使用 `set -Eeuo pipefail`。
- 两个空格缩进，换行符统一为 LF（`.gitattributes` 已配置）。
- 变量一律加引号；函数内变量用 `local` 声明。
- 必须通过 `shellcheck -x`。确需忽略某条规则时，在该行上方用 `# shellcheck disable=SCxxxx` 并写明原因，不要扩大 `.shellcheckrc` 的全局忽略范围。
- 面向用户的提示保持中文，使用 `ok`、`warn`、`die` 等现有输出函数；代码注释中英文均可，跟随所在文件的习惯。
- 复用 `lib/` 中已有的函数（如 `write_credentials`、`registry_write`、`write_service_unit`、`enable_service_checked`、`firewall_open`），不要重复实现。

## 测试要求

- 新功能和 bug 修复都需要对应的测试，放在现有的 `tests/*-smoke.sh` 中，或新建一个并加入 CI。
- 测试通过 `FRM_ETC`、`FRM_STATE`、`FRM_BIN_DIR` 等环境变量指向临时目录，参考 `tests/smoke.sh`。不要依赖真实的 systemd、网络或 root 权限。
- 涉及导出格式的改动，请同时断言输出中**不会**出现不该出现的字段或凭据。

## 添加新协议

1. 先开 Issue，附上官方服务端仓库链接，说明下载来源和校验方式。
2. 新建 `protocols/<名称>.sh`，实现 `protocol_install_<名称>`，参照 `protocols/anytls.sh`：随机端口和凭据、`trap` 回滚、写入凭据和注册表、启动并检查服务、开放防火墙。
3. 在 `frm-node` 中 `source` 该文件，并在 `install_protocol` 与安装菜单中加入入口。
4. 在 `lib/exporter.sh` 中补充客户端导出；无法确认某个客户端兼容的格式就不要输出。
5. 更新 `frm update`、`frm sub`、`frm cert` 的支持矩阵（如适用）和测试。
6. 同步更新 `README.md` 与 `README.en.md`。

## 提交与 PR

- 从 `main` 新建分支，每个 PR 只做一件事。
- 提交信息使用 [Conventional Commits](https://www.conventionalcommits.org/) 前缀：`feat:`、`fix:`、`docs:`、`test:`、`chore:`、`release:`，后面用英文简述改动。
- PR 描述写清楚改了什么、为什么改、如何测试的。如果在真实 VPS 上验证过，请注明系统、架构和协议。
- 改变用户可见行为时，同步更新中英文 README；涉及安全边界时，同步更新 `SECURITY.md`。
- PR 合并方式为 squash merge。

## 许可证

提交贡献即表示你同意以 [MIT 许可证](LICENSE) 发布你的代码。

---

<a id="english"></a>

## English

Thanks for helping improve frm-node. It is a personal side project with no SLA, but every issue and PR gets read.

### Before you start

- **Security vulnerabilities** go through [private reporting](https://github.com/godsonkg/frm-node/security/advisories/new), never a public issue or PR. See [SECURITY.md](SECURITY.md).
- **Open an issue first for larger changes** (a new protocol, a new command, a change in existing behaviour) so no work is wasted.
- **Never commit real credentials**: passwords, PSKs, UUIDs, private keys, subscription URLs, server IPs, or output of `frm show` / `frm sub fragment`. Tests and examples use placeholders only: `192.0.2.x`, `198.51.100.x` or `203.0.113.x` for IPs (RFC 5737), and `example.com` for domains.

### Project principles

Changes that break these are unlikely to be merged:

1. **Official cores only.** frm-node never implements a proxy protocol itself. A new protocol needs an official or upstream-maintained server, downloaded over HTTPS from its official source.
2. **No new attack surface.** frm-node opens no ports, runs no daemon and has no web panel or API. `frm watch` only sends outbound messages.
3. **Credentials stay put.** Credential files are `600` and instance directories `700`. Credentials never go into systemd units, logs, notifications or diagnostics.
4. **Be conservative with existing nodes.** Adoption, diagnostics and check commands are read-only by default. Anything that changes the system backs up first and can roll back on failure.
5. **Don't guess.** When a version, format or client compatibility cannot be confirmed, refuse with a reason rather than emit a config that may be wrong.

### Development

You need Bash, [jq](https://jqlang.github.io/jq/) and [ShellCheck](https://www.shellcheck.net/). Tests use temporary directories and mocked services and network, so they **need no root and never touch a VPS**. Run the commands in the Chinese section above from the repository root; they match CI (`.github/workflows/test.yml`), and all must pass before you open a PR.

### Code style

- Bash scripts start with `#!/usr/bin/env bash`; entry points and tests use `set -Eeuo pipefail`.
- Two-space indentation and LF line endings (enforced by `.gitattributes`).
- Quote every variable and declare function variables with `local`.
- Code must pass `shellcheck -x`. If a rule really must be ignored, add `# shellcheck disable=SCxxxx` above that line with a reason, rather than widening `.shellcheckrc`.
- User-facing messages stay in Chinese and use the existing `ok`, `warn` and `die` helpers. Code comments may be in Chinese or English; follow the surrounding file.
- Reuse helpers in `lib/` (`write_credentials`, `registry_write`, `write_service_unit`, `enable_service_checked`, `firewall_open`, …) instead of reimplementing them.

### Tests

- Every feature and bug fix needs a test, either in an existing `tests/*-smoke.sh` or in a new one added to CI.
- Point `FRM_ETC`, `FRM_STATE`, `FRM_BIN_DIR` and related variables at a temporary directory, as `tests/smoke.sh` does. Do not depend on real systemd, network access or root.
- For export format changes, also assert that fields or credentials that must not appear are absent.

### Adding a protocol

1. Open an issue first with a link to the official server implementation and how it is downloaded and verified.
2. Add `protocols/<name>.sh` with `protocol_install_<name>`, following `protocols/anytls.sh`: random port and credentials, `trap` rollback, credentials and registry entry, a checked service start, and the firewall rule.
3. `source` it from `frm-node` and add it to `install_protocol` and the install menu.
4. Add client exports in `lib/exporter.sh`. Skip any client format whose compatibility you cannot confirm.
5. Update the `frm update`, `frm sub` and `frm cert` support matrices where relevant, plus tests.
6. Update both `README.md` and `README.en.md`.

### Commits and pull requests

- Branch from `main` and keep each PR to one change.
- Use [Conventional Commits](https://www.conventionalcommits.org/) prefixes (`feat:`, `fix:`, `docs:`, `test:`, `chore:`, `release:`) followed by a short English summary.
- In the PR description, say what changed, why, and how you tested it. If you verified on a real VPS, note the OS, architecture and protocol.
- Update both READMEs when user-visible behaviour changes, and `SECURITY.md` when the security boundary changes.
- PRs are squash-merged.

### License

By contributing, you agree that your contributions are released under the [MIT License](LICENSE).
