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
source "$ROOT/lib/takeover.sh"

init_layout
mkdir -p "$FRM_ADOPT_ROOT/etc/vless-reality" \
  "$FRM_ADOPT_ROOT/etc/v2ray-agent/xray/conf" \
  "$FRM_ADOPT_ROOT/etc/v2ray-agent/sing-box/conf/config" \
  "$FRM_ADOPT_ROOT/etc/systemd/system"

cat >"$FRM_ADOPT_ROOT/etc/vless-reality/db.json" <<'EOF'
{
  "xray": {
    "vless":{"uuid":"11111111-1111-4111-8111-111111111111","port":443,"public_key":"pub","short_id":"a1b2","sni":"www.example.com"},
    "trojan":{"password":"trojan-pass","port":2096,"sni":"trojan.example.com"}
  },
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
cat >"$FRM_ADOPT_ROOT/etc/systemd/system/shadow-tls.service" <<'EOF'
[Service]
ExecStart=/usr/local/bin/shadow-tls --v3 server --listen 0.0.0.0:21443 --server 127.0.0.1:11443 --tls www.microsoft.com:443 --password shadow-password
EOF

scan=$(adopt_scan_raw)
grep -q $'vless-all-in-one\treality\t443' <<<"$scan"
grep -q $'vless-all-in-one\thysteria2\t8443' <<<"$scan"
grep -q $'vless-all-in-one\ttrojan\t2096' <<<"$scan"
grep -q $'v2ray-agent\tanytls\t10443' <<<"$scan"
grep -q $'manual-snell\tsnell6+ShadowTLS(旧拓扑)\t21443' <<<"$scan"

adopt_register
[[ $(registry_ids | wc -l) -eq 6 ]]
jq -e '.ownership=="adopted" and .read_only==true' "$FRM_REGISTRY_DIR/adopt-vless-all-in-one-reality-443.json" >/dev/null
grep -q '^UUID=' "$FRM_INSTANCE_DIR/adopt-vless-all-in-one-reality-443.env"
grep -q 'type: anytls' < <(export_instance adopt-v2ray-agent-anytls-10443)
grep -q 'type: trojan' < <(export_instance adopt-vless-all-in-one-trojan-2096)
grep -q 'password: "trojan-pass"' < <(export_instance adopt-vless-all-in-one-trojan-2096)
grep -q 'version=6' < <(export_instance adopt-manual-snell-snell6-21443)
grep -q 'shadow-tls-password=shadow-password' < <(export_instance adopt-manual-snell-snell6-21443)

# Re-running registration must be idempotent.
adopt_register >/dev/null
[[ $(registry_ids | wc -l) -eq 6 ]]

# Full control-plane takeover must preserve the data plane and be reversible.
MOCK_CRON="$TMP/root.cron"
cat >"$MOCK_CRON" <<'EOF'
30 1 * * * /bin/bash /etc/v2ray-agent/install.sh RenewTLS
15 4 * * * echo keep-this-job
EOF
doctor_instance() { return 0; }
confirm() { return 0; }
systemctl() {
  case ${1:-} in
    show) return 0 ;;
    cat) return 1 ;;
    is-active) printf 'inactive\n'; return 3 ;;
    is-enabled) printf 'disabled\n'; return 1 ;;
    *) return 0 ;;
  esac
}
crontab() {
  case ${1:-} in
    -l) cat "$MOCK_CRON" ;;
    -r) : >"$MOCK_CRON" ;;
    *) cp "$1" "$MOCK_CRON" ;;
  esac
}

adopt_takeover >/dev/null
[[ $(registry_get adopt-vless-all-in-one-reality-443 '.ownership') == taken-over ]]
grep -q 'keep-this-job' "$MOCK_CRON"
if grep -q 'v2ray-agent/install.sh' "$MOCK_CRON"; then exit 1; fi
takeover_dir=$(takeover_latest_dir)
(cd "$takeover_dir" && sha256sum -c payload.sha256 >/dev/null)
takeover_status=$(adopt_takeover_status)
grep -q '状态：active' <<<"$takeover_status"

adopt_takeover_rollback >/dev/null
[[ $(registry_get adopt-vless-all-in-one-reality-443 '.ownership') == adopted ]]
grep -q 'v2ray-agent/install.sh' "$MOCK_CRON"

# A failed post-takeover health check must restore registry and cron state.
doctor_instance() {
  [[ $(registry_ownership "$1") != taken-over ]]
}
if (adopt_takeover >/dev/null 2>&1); then exit 1; fi
[[ $(registry_get adopt-vless-all-in-one-reality-443 '.ownership') == adopted ]]
grep -q 'v2ray-agent/install.sh' "$MOCK_CRON"

echo "adoption smoke tests passed"
