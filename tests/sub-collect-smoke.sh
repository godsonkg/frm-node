#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/fixtures/host-a" "$TMP/fixtures/host-b"

cat >"$TMP/bin/mock-ssh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
target=$1 command=$2 format=''
[[ $command =~ --format[[:space:]]+(surge|loon|mihomo) ]] && format=${BASH_REMATCH[1]}
if [[ $command =~ --name[[:space:]]+\'([^\']+)\' ]]; then
  name=${BASH_REMATCH[1]}
  case $format in
    surge) printf '%s = anytls, 192.0.2.3, 443, password=fake-c\n' "$name" ;;
    loon) printf '%s = AnyTLS, 192.0.2.3, 443, "fake-c"\n' "$name" ;;
    mihomo) printf 'proxies:\n  - name: "%s"\n    type: anytls\n' "$name" ;;
  esac
  exit 0
fi
cat "$FIXTURE_ROOT/$target/$format.txt"
EOF
chmod +x "$TMP/bin/mock-ssh"

cat >"$TMP/fixtures/host-a/surge.txt" <<'EOF'
A-AnyTLS = anytls, 192.0.2.1, 443, password=fake-a
EOF
cat >"$TMP/fixtures/host-a/loon.txt" <<'EOF'
A-AnyTLS = AnyTLS, 192.0.2.1, 443, "fake-a"
EOF
cat >"$TMP/fixtures/host-a/mihomo.txt" <<'EOF'
proxies:
  - name: "A-AnyTLS"
    type: anytls
EOF
cat >"$TMP/fixtures/host-b/surge.txt" <<'EOF'
B-Trojan = trojan, 192.0.2.2, 2096, password=fake-b
EOF
cat >"$TMP/fixtures/host-b/loon.txt" <<'EOF'
B-Trojan = trojan, 192.0.2.2, 2096, "fake-b"
EOF
cat >"$TMP/fixtures/host-b/mihomo.txt" <<'EOF'
proxies:
  - name: "B-Trojan"
    type: trojan
EOF
printf 'host-a\tA\nhost-b\tB\n' >"$TMP/hosts.tsv"

export FIXTURE_ROOT="$TMP/fixtures"
export FRM_SUB_SSH_BIN="$TMP/bin/mock-ssh"
result=$(bash "$ROOT/tools/frm-sub-collect.sh" --inventory "$TMP/hosts.tsv" --output "$TMP/out")
final=$(sed -n 's/^输出目录：//p' <<<"$result")
[[ -d $final ]]
grep -q '^A-AnyTLS = anytls,' "$final/providers/surge.list"
grep -q '^B-Trojan = trojan,' "$final/providers/surge.list"
grep -q '^\[Proxy\]$' "$final/snippets/surge-proxy.conf"
grep -q '^proxies:$' "$final/providers/mihomo.yaml"
grep -q '^  - name: "A-AnyTLS"$' "$final/providers/mihomo.yaml"
grep -q '^  - name: "B-Trojan"$' "$final/providers/mihomo.yaml"

# 精确别名模式必须逐实例保留三个客户端各自的旧名称。
printf 'host-c\tC\n' >"$TMP/alias-hosts.tsv"
printf 'host-c\tfrm-anytls-443\tLegacy Surge\tLegacy Loon\tLegacy Mihomo\n' >"$TMP/aliases.tsv"
result=$(bash "$ROOT/tools/frm-sub-collect.sh" --inventory "$TMP/alias-hosts.tsv" \
  --aliases "$TMP/aliases.tsv" --output "$TMP/alias-out")
final=$(sed -n 's/^输出目录：//p' <<<"$result")
grep -q '^Legacy Surge = anytls,' "$final/providers/surge.list"
grep -q '^Legacy Loon = AnyTLS,' "$final/providers/loon.list"
grep -q '^  - name: "Legacy Mihomo"$' "$final/providers/mihomo.yaml"

echo "subscription collector smoke tests passed"
