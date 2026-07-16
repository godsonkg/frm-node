#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [[ -n ${FRM_TEST_TMP_ROOT:-} ]]; then
  TMP=$(mktemp -d "$FRM_TEST_TMP_ROOT/.smoke.XXXXXX")
else
  TMP=$(mktemp -d)
fi
trap 'rm -rf "$TMP"' EXIT

export FRM_ETC="$TMP/etc"
export FRM_STATE="$TMP/state"
export FRM_BIN_DIR="$TMP/state/bin"
export FRM_INSTANCE_DIR="$TMP/etc/instances"
export FRM_REGISTRY_DIR="$TMP/state/instances"
export FRM_BACKUP_DIR="$TMP/state/backups"
export FRM_SYSTEMD_DIR="$TMP/systemd"
export FRM_LOG="$TMP/frm-node.log"
export NO_COLOR=1

source "$ROOT/versions.env"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/registry.sh"
source "$ROOT/lib/service.sh"
source "$ROOT/protocols/base.sh"
source "$ROOT/lib/exporter.sh"

init_layout
write_credentials test-anytls SERVER_IPV4 192.0.2.10 PORT 443 PASSWORD test-password SNI example.com
registry_write test-anytls anytls AnyTLS 443 tcp test "$(credential_path test-anytls)" "" frm-test.service

[[ $(registry_get test-anytls '.protocol') == anytls ]]
if [[ -z ${MSYSTEM:-} ]]; then
  [[ $(stat -c '%a' "$(credential_path test-anytls)") == 600 ]]
fi
output=$(export_instance test-anytls)
grep -q 'type: anytls' <<<"$output"
grep -q '192.0.2.10' <<<"$output"

# Hysteria2 导出必须带证书指纹钉扎（凭据缺失时静默降级）。
write_credentials test-hy2 SERVER_IPV4 192.0.2.10 PORT 8443 PASSWORD hy-pass SNI example.com \
  OBFS_PASSWORD "" FINGERPRINT "AA:BB:CC:DD"
registry_write test-hy2 hysteria2 Hysteria2 8443 udp test "$(credential_path test-hy2)" "" frm-test-hy2.service
output=$(export_instance test-hy2)
grep -q 'fingerprint: "AA:BB:CC:DD"' <<<"$output"
grep -q 'pinSHA256=AA:BB:CC:DD' <<<"$output"

# 无 FINGERPRINT 的旧实例导出不得携带钉扎字段，也不得沿用上一实例的残留值。
write_credentials test-hy2-old SERVER_IPV4 192.0.2.11 PORT 8444 PASSWORD hy-old SNI example.org OBFS_PASSWORD ""
registry_write test-hy2-old hysteria2 Hysteria2 8444 udp test "$(credential_path test-hy2-old)" "" frm-test-hy2b.service
output=$(export_instance test-hy2-old)
if grep -q 'pinSHA256' <<<"$output"; then exit 1; fi
if grep -q 'AA:BB:CC:DD' <<<"$output"; then exit 1; fi

# Snell v6 必须显式拒绝 ShadowTLS 部署模式。
grep -q 'major == 6 &&.*mode == shadowtls' "$ROOT/protocols/snell.sh"
grep -q 'Snell v6 使用原生流量整形' "$ROOT/protocols/snell.sh"

# ShadowTLS 密码只能经 EnvironmentFile 注入，不得明文写入 unit。
# shellcheck disable=SC2016  # 故意匹配源码中的字面量 $ 变量名
if grep -qF -- '--password $stls_password' "$ROOT/protocols/snell.sh"; then exit 1; fi
# shellcheck disable=SC2016  # 故意匹配源码中的字面量 ${} 引用
grep -qF -- '--password \${SHADOWTLS_PASSWORD}' "$ROOT/protocols/snell.sh"

# Reality 的传输层键名必须是 network（method 会被 Xray 静默忽略）。
grep -q 'network:"raw"' "$ROOT/protocols/reality.sh"
if grep -q 'method:"raw"' "$ROOT/protocols/reality.sh"; then exit 1; fi

# 菜单选实例时表格必须走 stderr，否则会被 $(...) 捕获导致菜单失效。
grep -q 'registry_table >&2' "$ROOT/frm-node"

# Snell 下载校验钉扎机制必须保留。
grep -q 'verify_pinned_sha256' "$ROOT/protocols/base.sh"

echo "smoke tests passed"
