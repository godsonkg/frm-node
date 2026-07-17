#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [[ -n ${FRM_TEST_TMP_ROOT:-} ]]; then
  TMP=$(mktemp -d "$FRM_TEST_TMP_ROOT/.sub.XXXXXX")
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
export FRM_TAKEOVER_DIR="$TMP/state/takeovers"
export FRM_SUB_DIR="$TMP/state/sub"
export FRM_SYSTEMD_DIR="$TMP/systemd"
export FRM_LOG="$TMP/frm-node.log"
export NO_COLOR=1

source "$ROOT/versions.env"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/registry.sh"
source "$ROOT/protocols/base.sh"
source "$ROOT/lib/exporter.sh"
source "$ROOT/lib/subscription.sh"

init_layout
write_credentials test-anytls SERVER_IPV4 192.0.2.10 PORT 443 PASSWORD test-password SNI example.com
registry_write test-anytls anytls AnyTLS 443 tcp test "$(credential_path test-anytls)" "" frm-anytls.service
write_credentials test-reality SERVER_IPV4 192.0.2.11 PORT 2443 UUID 11111111-1111-4111-8111-111111111111 \
  SNI www.example.com PUBLIC_KEY test-public-key SHORT_ID a1b2c3d4
registry_write test-reality reality Reality 2443 tcp test "$(credential_path test-reality)" "" frm-reality.service

surge=$(sub_fragment_render surge TestBox 2>"$TMP/surge.err")
grep -q '^TestBox-AnyTLS = anytls,' <<<"$surge"
if grep -q 'Reality\|敏感信息\|---' <<<"$surge"; then exit 1; fi

loon=$(sub_fragment_render loon TestBox 2>"$TMP/loon.err")
grep -q '^TestBox-AnyTLS = AnyTLS,' <<<"$loon"
grep -q '^TestBox-Reality = VLESS,' <<<"$loon"
if grep -q '敏感信息\|---' <<<"$loon"; then exit 1; fi

mihomo=$(sub_fragment_render mihomo TestBox 2>"$TMP/mihomo.err")
grep -q '^proxies:$' <<<"$mihomo"
grep -q '^  - name: "TestBox-AnyTLS"$' <<<"$mihomo"
grep -q '^  - name: "TestBox-Reality"$' <<<"$mihomo"

single=$(sub_fragment_render surge ignored test-anytls 'Exact Legacy Name' 2>"$TMP/single.err")
grep -q '^Exact Legacy Name = anytls,' <<<"$single"
[[ $(wc -l <<<"$single") -eq 1 ]]

sub_fragment_write_all TestBox >/dev/null 2>"$TMP/write.err"
[[ -s $FRM_SUB_DIR/surge.list && -s $FRM_SUB_DIR/loon.list && -s $FRM_SUB_DIR/mihomo.yaml ]]
if [[ -z ${MSYSTEM:-} ]]; then
  [[ $(stat -c '%a' "$FRM_SUB_DIR") == 700 ]]
  [[ $(stat -c '%a' "$FRM_SUB_DIR/surge.list") == 600 ]]
fi

echo "subscription smoke tests passed"
