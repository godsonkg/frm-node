#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d "${FRM_TEST_TMP_ROOT:-/tmp}/.watch.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

export FRM_ETC="$TMP/etc"
export FRM_STATE="$TMP/state"
export FRM_BIN_DIR="$FRM_STATE/bin"
export FRM_INSTANCE_DIR="$FRM_ETC/instances"
export FRM_REGISTRY_DIR="$FRM_STATE/instances"
export FRM_BACKUP_DIR="$FRM_STATE/backups"
export FRM_SYSTEMD_DIR="$TMP/systemd"
export FRM_LOG="$TMP/frm-node.log"
export FRM_WATCH_ENV="$TMP/etc/watch.env"
export FRM_WATCH_STATE="$TMP/state/watch"
export NO_COLOR=1

source "$ROOT/versions.env"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/registry.sh"
source "$ROOT/lib/service.sh"
source "$ROOT/protocols/base.sh"
source "$ROOT/lib/watch.sh"

init_layout

# ---------- mock 外部命令 ----------
CURL_LOG="$TMP/curl.log"
: >"$CURL_LOG"
curl() {
  printf '%s\n' "$*" >>"$CURL_LOG"
  if [[ $* == *getMe* ]]; then
    printf '{"ok":true,"result":{"username":"testbot"}}\n'
  else
    printf '{"ok":true}\n'
  fi
}
SYSTEMCTL_ACTIVE=1
systemctl() {
  case ${1:-} in
    is-active) [[ $SYSTEMCTL_ACTIVE == 1 ]] ;;
    *) return 0 ;;
  esac
}
ss() {
  if [[ "$*" == *sport* ]]; then
    cat "$TMP/ss.port.out" 2>/dev/null || true
  else
    cat "$TMP/ss.all.out" 2>/dev/null || true
  fi
}
journalctl() { cat "$TMP/journal.out" 2>/dev/null || true; }
crontab() { cat "$TMP/cron.out" 2>/dev/null || true; }
vnstat() { cat "$TMP/vnstat.out" 2>/dev/null || true; }

sent_count() { grep -c -- "$1" "$CURL_LOG" || true; }

# ---------- 配置与加载 ----------
cat >"$FRM_WATCH_ENV" <<'EOF'
WATCH_TG_TOKEN=dummy-token
WATCH_TG_CHAT_ID=42
WATCH_NODE_NAME=TESTBOX
WATCH_DAILY_HOUR=0
WATCH_TRAFFIC_QUOTA_GB=1
EOF
chmod 0600 "$FRM_WATCH_ENV"
watch_load_config
watch_state_init
[[ $WATCH_DISK_WARN == 85 && $WATCH_INTERVAL_MIN == 5 ]]

# 发送：消息必须带机器名前缀。
watch_send "你好"
grep -q 'TESTBOX】你好' "$CURL_LOG"

# 告警去重：同一 key 在抑制窗口内只发一次；恢复只发一次。
watch_alert k1 "boom-alert"
watch_alert k1 "boom-alert"
[[ $(sent_count boom-alert) -eq 1 ]]
watch_resolve k1 "boom-fixed"
watch_resolve k1 "boom-fixed"
[[ $(sent_count boom-fixed) -eq 1 ]]

# ---------- 实例健康 ----------
write_credentials test-a SERVER_IPV4 192.0.2.10 PORT 443 PASSWORD secret-cred-value SNI example.com
registry_write test-a anytls AnyTLS 443 tcp test "$(credential_path test-a)" "" frm-test-a.service

SYSTEMCTL_ACTIVE=0
watch_check_instances
[[ $(sent_count '实例异常') -eq 1 ]]
SYSTEMCTL_ACTIVE=1
printf 'LISTEN 0 128 0.0.0.0:443 0.0.0.0:*\n' >"$TMP/ss.port.out"
watch_check_instances
[[ $(sent_count '实例已恢复') -eq 1 ]]

# ---------- 磁盘 ----------
watch_disk_used_pct() { printf '90\n'; }
watch_check_disk
[[ $(sent_count '磁盘偏高') -eq 1 ]]
watch_disk_used_pct() { printf '40\n'; }
watch_check_disk
[[ $(sent_count '磁盘占用已回落') -eq 1 ]]

# ---------- 流量（配额 1G，已用 0.9G = 90%）----------
printf '1;eth0;a;b;c;d;e;f;g;h;966400000;j;k;l;m\n' >"$TMP/vnstat.out"
watch_check_traffic
watch_check_traffic
[[ $(sent_count '本月流量已用') -eq 1 ]]
grep -q '^90$' "$FRM_WATCH_STATE/traffic.pct"

# ---------- SSH 登录 ----------
watch_check_ssh   # 首轮只落游标
[[ $(sent_count 'SSH 登录成功') -eq 0 ]]
printf '2026-07-16T10:00:01+0800 host sshd[123]: Accepted publickey for root from 198.51.100.7 port 50000 ssh2: ED25519\n' >"$TMP/journal.out"
watch_check_ssh
[[ $(sent_count 'SSH 登录成功') -eq 1 ]]
grep -q '198.51.100.7' "$CURL_LOG"
# 已知 IP 白名单：不再推送，但仍计入日志。
WATCH_SSH_KNOWN_IPS=198.51.100.7
watch_check_ssh
[[ $(sent_count 'SSH 登录成功') -eq 1 ]]
WATCH_SSH_KNOWN_IPS=''

# ---------- 端口基线 ----------
printf 'tcp LISTEN 0 128 0.0.0.0:22 0.0.0.0:*\ntcp LISTEN 0 128 0.0.0.0:443 0.0.0.0:*\n' >"$TMP/ss.all.out"
watch_check_ports   # 首轮建基线
[[ $(sent_count '新监听端口') -eq 0 ]]
printf 'tcp LISTEN 0 128 0.0.0.0:22 0.0.0.0:*\ntcp LISTEN 0 128 0.0.0.0:443 0.0.0.0:*\ntcp LISTEN 0 128 127.0.0.1:9999 0.0.0.0:*\n' >"$TMP/ss.all.out"
watch_check_ports
[[ $(sent_count '新监听端口') -eq 1 ]]
grep -q 'tcp/9999' "$CURL_LOG"
watch_accept_ports
watch_check_ports
[[ $(sent_count '新监听端口') -eq 1 ]]
# 注册表内实例端口不算异常：新增 443/udp 之外的注册端口。
write_credentials test-b SERVER_IPV4 192.0.2.10 PORT 8443 PASSWORD p SNI e.com OBFS_PASSWORD "" FINGERPRINT ""
registry_write test-b hysteria2 Hysteria2 8443 udp test "$(credential_path test-b)" "" frm-test-b.service
printf 'tcp LISTEN 0 128 0.0.0.0:22 0.0.0.0:*\ntcp LISTEN 0 128 0.0.0.0:443 0.0.0.0:*\ntcp LISTEN 0 128 127.0.0.1:9999 0.0.0.0:*\nudp UNCONN 0 0 0.0.0.0:8443 0.0.0.0:*\n' >"$TMP/ss.all.out"
watch_check_ports
[[ $(sent_count '新监听端口') -eq 1 ]]

# ---------- crontab 基线 ----------
printf '15 4 * * * echo ok\n' >"$TMP/cron.out"
watch_check_cron   # 首轮建基线
[[ $(sent_count 'crontab 发生变化') -eq 0 ]]
printf '15 4 * * * echo ok\n* * * * * /tmp/backdoor\n' >"$TMP/cron.out"
watch_check_cron
[[ $(sent_count 'crontab 发生变化') -eq 1 ]]
watch_accept_cron
watch_check_cron
[[ $(sent_count 'crontab 发生变化') -eq 1 ]]

# ---------- 每日日报 ----------
watch_daily_summary
watch_daily_summary
[[ $(sent_count '每日巡检') -eq 1 ]]
grep -q '实例：2 个' "$CURL_LOG"

# ---------- 消息红线：凭据值全程不得进入任何推送 ----------
if grep -q 'secret-cred-value' "$CURL_LOG"; then exit 1; fi

echo "watch smoke tests passed"
