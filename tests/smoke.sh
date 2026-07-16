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

# Snell v6 必须显式拒绝 ShadowTLS 部署模式。
grep -q 'major == 6 &&.*mode == shadowtls' "$ROOT/protocols/snell.sh"
grep -q 'Snell v6 使用原生流量整形' "$ROOT/protocols/snell.sh"

echo "smoke tests passed"
