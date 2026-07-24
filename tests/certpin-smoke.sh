#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d "${FRM_TEST_TMP_ROOT:-/tmp}/.certpin.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

export FRM_ETC="$TMP/etc"
export FRM_STATE="$TMP/state"
export FRM_BIN_DIR="$FRM_STATE/bin"
export FRM_INSTANCE_DIR="$FRM_ETC/instances"
export FRM_REGISTRY_DIR="$FRM_STATE/instances"
export FRM_BACKUP_DIR="$FRM_STATE/backups"
export FRM_SYSTEMD_DIR="$TMP/systemd"
export FRM_LOG="$TMP/frm-node.log"
export NO_COLOR=1

source "$ROOT/versions.env"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/registry.sh"
source "$ROOT/lib/service.sh"
source "$ROOT/protocols/base.sh"
source "$ROOT/lib/exporter.sh"
source "$ROOT/lib/certpin.sh"

init_layout

# ---------- 造两张证书：一张长期固定，一张模拟 AnyTLS 的临时证书 ----------
# 只豁免 /CN= 开头的参数，阻止 Git Bash 把 -subj 的值当路径转换；
# 不能用 '*'，那会连 -keyout/-out 的 /tmp 路径一起停止转换，导致 openssl 写不进去。
# Linux 下该变量本身无副作用。
export MSYS2_ARG_CONV_EXCL='/CN='

LONG_KEY="$TMP/long.key"; LONG_CRT="$TMP/long.crt"
openssl req -x509 -nodes -newkey rsa:2048 -sha256 -days 3650 \
  -keyout "$LONG_KEY" -out "$LONG_CRT" -subj "/CN=long.example.com" >/dev/null 2>&1

SHORT_KEY="$TMP/short.key"; SHORT_CRT="$TMP/short.crt"
openssl req -x509 -nodes -newkey rsa:2048 -sha256 -days 1 \
  -keyout "$SHORT_KEY" -out "$SHORT_CRT" -subj "/CN=short.example.com" >/dev/null 2>&1

LONG_FP=$(openssl x509 -in "$LONG_CRT" -noout -fingerprint -sha256 | cut -d= -f2)

# ---------- 指纹格式换算 ----------
[[ $(fingerprint_hex "AA:BB:CC") == aabbcc ]]

# ---------- 长期证书：应当成功钉扎 ----------
write_credentials hy2-long SERVER_IPV4 192.0.2.10 PORT 8443 PASSWORD pw SNI e.com OBFS_PASSWORD ""
registry_write hy2-long hysteria2 Hysteria2 8443 udp test "$(credential_path hy2-long)" "" frm-a.service
cp "$LONG_CRT" "$FRM_INSTANCE_DIR/hy2-long.crt"

out=$(certpin_pin_instance hy2-long)
grep -q '已钉扎' <<<"$out"
[[ $(certpin_current_pin hy2-long) == "$LONG_FP" ]]
# 凭据里其他字段不能被覆盖掉。
grep -q '^PASSWORD=' "$(credential_path hy2-long)"
grep -q '^SNI=' "$(credential_path hy2-long)"
# Git Bash 没有可靠的 Unix 权限语义，仅在真实 POSIX 环境下断言权限。
if [[ -z ${MSYSTEM:-} ]]; then
  [[ $(stat -c '%a' "$(credential_path hy2-long)") == 600 ]]
fi

# 重复钉扎必须幂等，且不产生第二行 FINGERPRINT。
out=$(certpin_pin_instance hy2-long)
grep -q '已是最新' <<<"$out"
[[ $(grep -c '^FINGERPRINT=' "$(credential_path hy2-long)") -eq 1 ]]

# ---------- 短效证书：安全阀必须拒绝（这正是 AnyTLS 的情形）----------
write_credentials hy2-short SERVER_IPV4 192.0.2.11 PORT 8444 PASSWORD pw SNI e.com OBFS_PASSWORD ""
registry_write hy2-short hysteria2 Hysteria2 8444 udp test "$(credential_path hy2-short)" "" frm-b.service
cp "$SHORT_CRT" "$FRM_INSTANCE_DIR/hy2-short.crt"

if certpin_pin_instance hy2-short >"$TMP/short.out" 2>&1; then exit 1; fi
grep -q '拒绝' "$TMP/short.out"
grep -q '临时证书' "$TMP/short.out"
# 被拒绝时绝不能写入指纹。
[[ -z $(certpin_current_pin hy2-short) ]]

# ---------- AnyTLS 必须被判为不适用，并说明理由 ----------
write_credentials any-1 SERVER_IPV4 192.0.2.12 PORT 443 PASSWORD pw SNI e.com
registry_write any-1 anytls AnyTLS 443 tcp test "$(credential_path any-1)" "" frm-c.service
out=$(certpin_pin_instance any-1)
grep -q '跳过' <<<"$out"
grep -q '重启' <<<"$out"
[[ -z $(certpin_current_pin any-1) ]]

# Reality 同样不适用，但理由不同（不是临时证书，而是协议自带验证）。
write_credentials r-1 SERVER_IPV4 192.0.2.13 PORT 443 UUID u SNI e.com PUBLIC_KEY pk SHORT_ID sid
registry_write r-1 reality Reality 8443 tcp test "$(credential_path r-1)" "" frm-d.service
grep -q 'public-key' < <(certpin_unsupported_reason reality)

# ---------- 导出：钉扎后 Mihomo 必须带 fingerprint，且为无冒号小写 ----------
expected_hex=$(fingerprint_hex "$LONG_FP")
out=$(render_hysteria2_mihomo hy2-long TEST-HY2)
grep -q "fingerprint: \"$expected_hex\"" <<<"$out"
# 只校验引号内的值：Mihomo 要求无冒号小写十六进制（键名本身带冒号，不能整行判断）。
rendered_value=$(sed -nE 's/.*fingerprint: "([^"]+)".*/\1/p' <<<"$out")
[[ $rendered_value == "$expected_hex" ]]
[[ $rendered_value != *:* ]]
[[ $rendered_value =~ ^[0-9a-f]{64}$ ]]

# Surge：已钉扎的 Hy2 必须改用 64 位小写指纹，不再同时跳过证书校验。
out=$(render_hysteria2_surge hy2-long TEST-HY2)
grep -q "server-cert-fingerprint-sha256=$expected_hex" <<<"$out"
if grep -q 'skip-cert-verify=true' <<<"$out"; then exit 1; fi
surge_pin=$(sed -nE 's/.*server-cert-fingerprint-sha256=([0-9a-f]+).*/\1/p' <<<"$out")
[[ $surge_pin =~ ^[0-9a-f]{64}$ ]]

# 未钉扎的实例导出中不得出现 fingerprint 字段，也不得串用上一实例的值。
out=$(render_hysteria2_mihomo hy2-short TEST-HY2B)
if grep -q 'fingerprint' <<<"$out"; then exit 1; fi

# Surge：未钉扎 Hy2 保留原有跳过校验，且不能串用前一个实例的指纹。
out=$(render_hysteria2_surge hy2-short TEST-HY2B)
grep -q 'skip-cert-verify=true' <<<"$out"
if grep -q 'server-cert-fingerprint-sha256' <<<"$out"; then exit 1; fi

# Trojan 钉扎后同样带 fingerprint。
write_credentials tj-1 SERVER_IPV4 192.0.2.14 PORT 2096 PASSWORD tjpw SNI t.example.com
registry_write tj-1 trojan Trojan 2096 tcp test "$(credential_path tj-1)" "" frm-e.service
certpin_store tj-1 "$LONG_FP"
out=$(render_trojan_mihomo tj-1 TEST-TROJAN)
grep -q "fingerprint: \"$expected_hex\"" <<<"$out"

# Surge：已钉扎 Trojan 使用同一规范化指纹，不再同时跳过证书校验。
out=$(render_trojan_surge tj-1 TEST-TROJAN)
grep -q "server-cert-fingerprint-sha256=$expected_hex" <<<"$out"
if grep -q 'skip-cert-verify=true' <<<"$out"; then exit 1; fi

# 未钉扎的 Trojan 不带该字段。
write_credentials tj-2 SERVER_IPV4 192.0.2.15 PORT 2097 PASSWORD tjpw2 SNI t2.example.com
registry_write tj-2 trojan Trojan 2097 tcp test "$(credential_path tj-2)" "" frm-f.service
out=$(render_trojan_mihomo tj-2 TEST-TROJAN2)
if grep -q 'fingerprint' <<<"$out"; then exit 1; fi

# Surge：未钉扎 Trojan 保留跳过校验，且不得泄漏其他实例的指纹。
out=$(render_trojan_surge tj-2 TEST-TROJAN2)
grep -q 'skip-cert-verify=true' <<<"$out"
if grep -q 'server-cert-fingerprint-sha256' <<<"$out"; then exit 1; fi

# AnyTLS 永远保持临时证书兼容路径，不得输出固定指纹。
certpin_store any-1 "$LONG_FP"
out=$(render_anytls_surge any-1 TEST-ANYTLS)
grep -q 'skip-cert-verify=true' <<<"$out"
if grep -q 'server-cert-fingerprint-sha256' <<<"$out"; then exit 1; fi
certpin_store any-1 ''

# 损坏的固定指纹必须安全失败，不能降级成跳过证书校验。
write_credentials hy2-invalid SERVER_IPV4 192.0.2.16 PORT 8445 PASSWORD pw SNI e.com OBFS_PASSWORD "" FINGERPRINT invalid
registry_write hy2-invalid hysteria2 Hysteria2 8445 udp test "$(credential_path hy2-invalid)" "" frm-g.service
if render_hysteria2_surge hy2-invalid TEST-INVALID >"$TMP/invalid.out"; then exit 1; fi
[[ ! -s $TMP/invalid.out ]]

# ---------- unpin ----------
certpin_store tj-1 ''
[[ -z $(certpin_current_pin tj-1) ]]
out=$(render_trojan_mihomo tj-1 TEST-TROJAN)
if grep -q 'fingerprint' <<<"$out"; then exit 1; fi

# ---------- 多核共存目录：必须按核心区分，绝不能取错证书 ----------
# 复现真实场景：/etc/vless-reality 同时承载 xray(certificateFile) 与
# sing-box(certificate_path)，两者证书不同；取错会导致客户端指纹不匹配连不上。
MIXED="$TMP/mixed"
mkdir -p "$MIXED"
XRAY_CRT="$MIXED/xray.crt"; SBOX_CRT="$MIXED/singbox.crt"
openssl req -x509 -nodes -newkey rsa:2048 -sha256 -days 3650 \
  -keyout "$TMP/x.key" -out "$XRAY_CRT" -subj "/CN=xray.example.com" >/dev/null 2>&1
openssl req -x509 -nodes -newkey rsa:2048 -sha256 -days 3650 \
  -keyout "$TMP/s.key" -out "$SBOX_CRT" -subj "/CN=singbox.example.com" >/dev/null 2>&1
XRAY_FP=$(openssl x509 -in "$XRAY_CRT" -noout -fingerprint -sha256 | cut -d= -f2)
SBOX_FP=$(openssl x509 -in "$SBOX_CRT" -noout -fingerprint -sha256 | cut -d= -f2)
[[ $XRAY_FP != "$SBOX_FP" ]]

# config.json 按字母序排在 singbox.json 之前，天真实现会取错。
printf '{"certificateFile":"%s"}\n' "$XRAY_CRT" >"$MIXED/config.json"
printf '{"certificate_path":"%s"}\n' "$SBOX_CRT" >"$MIXED/singbox.json"
printf '{"note":"aggregate"}\n' >"$MIXED/db.json"

# sing-box 承载的 Hy2：必须拿到 sing-box 那张，而不是排在前面的 xray 那张。
write_credentials mix-hy2 SERVER_IPV4 192.0.2.20 PORT 58800 PASSWORD pw SNI e.com OBFS_PASSWORD ""
registry_write mix-hy2 hysteria2 Hysteria2 58800 udp test "$(credential_path mix-hy2)" "$MIXED/db.json" sing-box.service
certpin_pin_instance mix-hy2 >/dev/null
[[ $(certpin_current_pin mix-hy2) == "$SBOX_FP" ]]
[[ $(certpin_current_pin mix-hy2) != "$XRAY_FP" ]]

# 无法判断核心时（服务名不含 xray/sing-box），存在多张候选就必须拒绝而非乱猜。
write_credentials mix-unknown SERVER_IPV4 192.0.2.21 PORT 58801 PASSWORD pw SNI e.com OBFS_PASSWORD ""
registry_write mix-unknown hysteria2 Hysteria2 58801 udp test "$(credential_path mix-unknown)" "$MIXED/db.json" other.service
if certpin_pin_instance mix-unknown >"$TMP/mixed.out" 2>&1; then exit 1; fi
[[ -z $(certpin_current_pin mix-unknown) ]]
grep -q '多张候选证书' "$TMP/mixed.out"

# 拒绝之后，用 --cert 显式指定必须能成功。
certpin_pin_instance mix-unknown "$SBOX_CRT" >/dev/null
[[ $(certpin_current_pin mix-unknown) == "$SBOX_FP" ]]

# ---------- scan 只读，不得写入任何指纹 ----------
before=$(cat "$(credential_path hy2-short)")
certpin_scan_command >/dev/null
[[ $before == "$(cat "$(credential_path hy2-short)")" ]]

echo "certpin smoke tests passed"
