#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d "${FRM_TEST_TMP_ROOT:-/tmp}/.adopt.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

export FRM_ADOPT_ROOT="$TMP/source"
export FRM_ETC="$TMP/frm/etc"
export FRM_STATE="$TMP/frm/state"
export FRM_BIN_DIR="$FRM_STATE/bin"
export FRM_INSTANCE_DIR="$FRM_ETC/instances"
export FRM_REGISTRY_DIR="$FRM_STATE/instances"
export FRM_BACKUP_DIR="$FRM_STATE/backups"
export FRM_SYSTEMD_DIR="$TMP/frm/systemd"
export FRM_LOG="$TMP/frm/frm-node.log"
export FRM_SERVER_IPV4=192.0.2.55
export FRM_ADOPT_SNELL_VERSION=6
export NO_COLOR=1

source "$ROOT/versions.env"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/registry.sh"
source "$ROOT/lib/service.sh"
source "$ROOT/protocols/base.sh"
source "$ROOT/lib/exporter.sh"
source "$ROOT/lib/adopt.sh"

init_layout
mkdir -p "$FRM_ADOPT_ROOT/etc/vless-reality" \
  "$FRM_ADOPT_ROOT/etc/v2ray-agent/xray/conf" \
  "$FRM_ADOPT_ROOT/etc/v2ray-agent/sing-box/conf/config" \
  "$FRM_ADOPT_ROOT/etc/systemd/system"

cat >"$FRM_ADOPT_ROOT/etc/vless-reality/db.json" <<'EOF'
{
  "xray": {"vless":{"uuid":"11111111-1111-4111-8111-111111111111","port":443,"public_key":"pub","short_id":"a1b2","sni":"www.example.com"}},
  "singbox": {
    "hy2":{"password":"hy-pass","port":8443,"sni":"hy.example.com"},
    "snell-v5":{"psk":"snell-five-password","port":9443,"version":"5"}
  }
}
EOF

cat >"$FRM_ADOPT_ROOT/etc/v2ray-agent/sing-box/conf/config/13_anytls_inbounds.json" <<'EOF'
{"inbounds":[{"type":"anytls","listen_port":10443,"users":[{"password":"any-pass"}],"tls":{"server_name":"any.example.com"}}]}
EOF

cat >"$FRM_ADOPT_ROOT/etc/snell-server.conf" <<'EOF'
[snell-server]
listen = 0.0.0.0:11443
psk = this-is-a-valid-snell-six-password
EOF
cat >"$FRM_ADOPT_ROOT/etc/systemd/system/snell.service" <<'EOF'
[Service]
ExecStart=/usr/local/bin/snell-server -c /etc/snell-server.conf
EOF

scan=$(adopt_scan_raw)
grep -q $'vless-all-in-one\treality\t443' <<<"$scan"
grep -q $'vless-all-in-one\thysteria2\t8443' <<<"$scan"
grep -q $'v2ray-agent\tanytls\t10443' <<<"$scan"
grep -q $'manual-snell\tsnell6\t11443' <<<"$scan"

adopt_register
[[ $(registry_ids | wc -l) -eq 5 ]]
jq -e '.ownership=="adopted" and .read_only==true' "$FRM_REGISTRY_DIR/adopt-vless-all-in-one-reality-443.json" >/dev/null
grep -q '^UUID=' "$FRM_INSTANCE_DIR/adopt-vless-all-in-one-reality-443.env"
grep -q 'type: anytls' < <(export_instance adopt-v2ray-agent-anytls-10443)
grep -q 'version=6' < <(export_instance adopt-manual-snell-snell6-11443)

# Re-running registration must be idempotent.
adopt_register >/dev/null
[[ $(registry_ids | wc -l) -eq 5 ]]

echo "adoption smoke tests passed"
