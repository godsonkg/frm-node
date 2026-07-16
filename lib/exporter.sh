#!/usr/bin/env bash

export_anytls() {
  local id=$1 name="FRM-AnyTLS"
  load_credentials "$id"
  cat <<EOF
--- Mihomo / OpenClash / FlClash ---
- name: "$name"
  type: anytls
  server: $SERVER_IPV4
  port: $PORT
  password: "$PASSWORD"
  udp: true
  tls: true
  skip-cert-verify: true
  servername: $SNI
  client-fingerprint: chrome

--- Surge ---
$name = anytls, $SERVER_IPV4, $PORT, password=$PASSWORD, ip-version=v4-only, skip-cert-verify=true, sni=$SNI

--- Loon ---
$name = AnyTLS, $SERVER_IPV4, $PORT, "$PASSWORD", sni=$SNI, udp=true, skip-cert-verify=true
EOF
}

export_hysteria2() {
  local id=$1 name="FRM-Hy2" obfs_uri='' obfs_yaml='' obfs_surge='' loon_output
  load_credentials "$id"
  if [[ -n ${OBFS_PASSWORD:-} ]]; then
    obfs_uri="&obfs=salamander&obfs-password=$OBFS_PASSWORD"
    obfs_yaml=$'\n  obfs: salamander\n  obfs-password: "'$OBFS_PASSWORD'"'
    obfs_surge=", salamander-password=$OBFS_PASSWORD"
    loon_output="当前实例启用了 Salamander，请在 Loon 中导入下方通用 URI，避免手写参数产生兼容差异。"
  else
    loon_output="$name = Hysteria2, $SERVER_IPV4, $PORT, \"$PASSWORD\", sni = $SNI, udp = true, fast-open = true, skip-cert-verify = true"
  fi
  cat <<EOF
--- Mihomo / OpenClash / FlClash ---
- name: "$name"
  type: hysteria2
  server: $SERVER_IPV4
  port: $PORT
  password: "$PASSWORD"
  sni: $SNI
  skip-cert-verify: true$obfs_yaml

--- Surge ---
$name = hysteria2, $SERVER_IPV4, $PORT, password=$PASSWORD, ip-version=v4-only, ecn=true, skip-cert-verify=true, sni=$SNI$obfs_surge

--- Loon ---
$loon_output

--- 通用 URI ---
hysteria2://$PASSWORD@$SERVER_IPV4:$PORT/?sni=$SNI&insecure=1$obfs_uri#$name
EOF
}

export_snell() {
  local id=$1 name extras=''
  load_credentials "$id"
  name="FRM-Snell-v$SNELL_VERSION"
  if [[ ${MODE:-native} == shadowtls ]]; then
    name="$name-ShadowTLS"
    extras=", shadow-tls-password=$SHADOWTLS_PASSWORD, shadow-tls-sni=$SHADOWTLS_SNI, shadow-tls-version=3"
  fi
  cat <<EOF
--- Surge ---
$name = snell, $SERVER_IPV4, $PORT, psk=$PSK, version=$SNELL_VERSION, reuse=true, tfo=true, ip-version=v4-only$extras

说明：Snell 仅导出给 Surge。Snell v6 固定使用原生流量整形，不叠加 ShadowTLS。
EOF
}

export_reality() {
  local id=$1 name="FRM-Reality"
  load_credentials "$id"
  cat <<EOF
--- Mihomo / OpenClash / FlClash ---
- name: "$name"
  type: vless
  server: $SERVER_IPV4
  port: $PORT
  uuid: $UUID
  network: tcp
  udp: true
  tls: true
  flow: xtls-rprx-vision
  servername: $SNI
  reality-opts:
    public-key: $PUBLIC_KEY
    short-id: $SHORT_ID
  client-fingerprint: chrome

--- Loon ---
$name = VLESS, $SERVER_IPV4, $PORT, "$UUID", transport = tcp, flow = xtls-rprx-vision, public-key = "$PUBLIC_KEY", short-id = $SHORT_ID, over-tls = true, sni = $SNI, udp = true, skip-cert-verify = true

--- 通用 URI ---
vless://$UUID@$SERVER_IPV4:$PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SNI&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID&type=tcp#$name
EOF
}

export_instance() {
  local id=$1 protocol
  registry_exists "$id" || die "实例不存在：$id"
  protocol=$(registry_get "$id" '.protocol')
  printf '\n========== %s（敏感信息，请勿公开）==========\n' "$id"
  case $protocol in
    anytls) export_anytls "$id" ;;
    hysteria2) export_hysteria2 "$id" ;;
    snell4|snell5|snell6) export_snell "$id" ;;
    reality) export_reality "$id" ;;
    *) die "尚未实现 $protocol 的导出器。" ;;
  esac
  printf '================================================\n'
}

export_all() {
  local id found=0
  while IFS= read -r id; do
    found=1
    export_instance "$id"
  done < <(registry_ids)
  (( found == 1 )) || warn "尚未安装任何节点。"
}
