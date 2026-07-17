#!/usr/bin/env bash

# 纯渲染函数只输出一个节点定义，不带标题、横幅或说明。
# 人类可读的 frm show 与机器可读的 frm sub fragment 共用这些函数。

render_anytls_mihomo() {
  local id=$1 name=$2
  load_credentials "$id"
  cat <<EOF
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
EOF
}

render_anytls_surge() {
  local id=$1 name=$2
  load_credentials "$id"
  printf '%s = anytls, %s, %s, password=%s, ip-version=v4-only, skip-cert-verify=true, sni=%s\n' \
    "$name" "$SERVER_IPV4" "$PORT" "$PASSWORD" "$SNI"
}

render_anytls_loon() {
  local id=$1 name=$2
  load_credentials "$id"
  printf '%s = AnyTLS, %s, %s, "%s", sni=%s, udp=true, skip-cert-verify=true\n' \
    "$name" "$SERVER_IPV4" "$PORT" "$PASSWORD" "$SNI"
}

render_hysteria2_mihomo() {
  local id=$1 name=$2 pin_yaml='' obfs_yaml=''
  local OBFS_PASSWORD='' FINGERPRINT=''
  load_credentials "$id"
  [[ -z ${FINGERPRINT:-} ]] || pin_yaml=$'\n  fingerprint: "'$FINGERPRINT'"'
  if [[ -n ${OBFS_PASSWORD:-} ]]; then
    obfs_yaml=$'\n  obfs: salamander\n  obfs-password: "'$OBFS_PASSWORD'"'
  fi
  cat <<EOF
- name: "$name"
  type: hysteria2
  server: $SERVER_IPV4
  port: $PORT
  password: "$PASSWORD"
  sni: $SNI
  skip-cert-verify: true$pin_yaml$obfs_yaml
EOF
}

render_hysteria2_surge() {
  local id=$1 name=$2 obfs_surge=''
  local OBFS_PASSWORD=''
  load_credentials "$id"
  [[ -z ${OBFS_PASSWORD:-} ]] || obfs_surge=", salamander-password=$OBFS_PASSWORD"
  printf '%s = hysteria2, %s, %s, password=%s, ip-version=v4-only, ecn=true, skip-cert-verify=true, sni=%s%s\n' \
    "$name" "$SERVER_IPV4" "$PORT" "$PASSWORD" "$SNI" "$obfs_surge"
}

render_hysteria2_loon() {
  local id=$1 name=$2
  local OBFS_PASSWORD=''
  load_credentials "$id"
  [[ -z ${OBFS_PASSWORD:-} ]] || return 2
  printf '%s = Hysteria2, %s, %s, "%s", sni = %s, udp = true, fast-open = true, skip-cert-verify = true\n' \
    "$name" "$SERVER_IPV4" "$PORT" "$PASSWORD" "$SNI"
}

render_hysteria2_uri() {
  local id=$1 name=$2 obfs_uri='' pin_uri=''
  local OBFS_PASSWORD='' FINGERPRINT=''
  load_credentials "$id"
  [[ -z ${FINGERPRINT:-} ]] || pin_uri="&pinSHA256=$FINGERPRINT"
  [[ -z ${OBFS_PASSWORD:-} ]] || obfs_uri="&obfs=salamander&obfs-password=$OBFS_PASSWORD"
  printf 'hysteria2://%s@%s:%s/?sni=%s&insecure=1%s%s#%s\n' \
    "$PASSWORD" "$SERVER_IPV4" "$PORT" "$SNI" "$pin_uri" "$obfs_uri" "$name"
}

render_snell_surge() {
  local id=$1 name=$2 extras=''
  local MODE='' SHADOWTLS_PASSWORD='' SHADOWTLS_SNI='' SNELL_VERSION='' PSK=''
  load_credentials "$id"
  if [[ ${MODE:-native} == *shadowtls ]]; then
    extras=", shadow-tls-password=$SHADOWTLS_PASSWORD, shadow-tls-sni=$SHADOWTLS_SNI, shadow-tls-version=3"
  fi
  printf '%s = snell, %s, %s, psk=%s, version=%s, reuse=true, tfo=true, ip-version=v4-only%s\n' \
    "$name" "$SERVER_IPV4" "$PORT" "$PSK" "$SNELL_VERSION" "$extras"
}

render_reality_mihomo() {
  local id=$1 name=$2
  load_credentials "$id"
  cat <<EOF
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
EOF
}

render_reality_loon() {
  local id=$1 name=$2
  load_credentials "$id"
  printf '%s = VLESS, %s, %s, "%s", transport = tcp, flow = xtls-rprx-vision, public-key = "%s", short-id = %s, over-tls = true, sni = %s, udp = true, skip-cert-verify = true\n' \
    "$name" "$SERVER_IPV4" "$PORT" "$UUID" "$PUBLIC_KEY" "$SHORT_ID" "$SNI"
}

render_reality_uri() {
  local id=$1 name=$2
  load_credentials "$id"
  printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s\n' \
    "$UUID" "$SERVER_IPV4" "$PORT" "$SNI" "$PUBLIC_KEY" "$SHORT_ID" "$name"
}

render_tuic_mihomo() {
  local id=$1 name=$2
  load_credentials "$id"
  cat <<EOF
- name: "$name"
  type: tuic
  server: $SERVER_IPV4
  port: $PORT
  uuid: $UUID
  password: "$PASSWORD"
  sni: $SNI
  alpn: [h3]
  disable-sni: false
  reduce-rtt: true
  udp-relay-mode: native
  congestion-controller: bbr
  skip-cert-verify: true
EOF
}

render_tuic_uri() {
  local id=$1 name=$2
  load_credentials "$id"
  printf 'tuic://%s:%s@%s:%s?sni=%s&alpn=h3&allow_insecure=1&congestion_control=bbr#%s\n' \
    "$UUID" "$PASSWORD" "$SERVER_IPV4" "$PORT" "$SNI" "$name"
}

render_trojan_mihomo() {
  local id=$1 name=$2
  load_credentials "$id"
  cat <<EOF
- name: "$name"
  type: trojan
  server: $SERVER_IPV4
  port: $PORT
  password: "$PASSWORD"
  sni: $SNI
  udp: true
  skip-cert-verify: true
EOF
}

render_trojan_surge() {
  local id=$1 name=$2
  load_credentials "$id"
  printf '%s = trojan, %s, %s, password=%s, sni=%s, skip-cert-verify=true, ip-version=v4-only\n' \
    "$name" "$SERVER_IPV4" "$PORT" "$PASSWORD" "$SNI"
}

render_trojan_loon() {
  local id=$1 name=$2
  load_credentials "$id"
  printf '%s = trojan, %s, %s, "%s", sni=%s, skip-cert-verify=true, udp=true\n' \
    "$name" "$SERVER_IPV4" "$PORT" "$PASSWORD" "$SNI"
}

render_trojan_uri() {
  local id=$1 name=$2
  load_credentials "$id"
  printf 'trojan://%s@%s:%s?sni=%s&allowInsecure=1#%s\n' \
    "$PASSWORD" "$SERVER_IPV4" "$PORT" "$SNI" "$name"
}

render_instance_format() {
  local format=$1 id=$2 name=$3 protocol
  registry_exists "$id" || die "实例不存在：$id"
  protocol=$(registry_get "$id" '.protocol')
  case "$protocol:$format" in
    anytls:mihomo) render_anytls_mihomo "$id" "$name" ;;
    anytls:surge) render_anytls_surge "$id" "$name" ;;
    anytls:loon) render_anytls_loon "$id" "$name" ;;
    hysteria2:mihomo) render_hysteria2_mihomo "$id" "$name" ;;
    hysteria2:surge) render_hysteria2_surge "$id" "$name" ;;
    hysteria2:loon) render_hysteria2_loon "$id" "$name" ;;
    snell4:surge|snell5:surge|snell6:surge) render_snell_surge "$id" "$name" ;;
    reality:mihomo) render_reality_mihomo "$id" "$name" ;;
    reality:loon) render_reality_loon "$id" "$name" ;;
    tuic:mihomo) render_tuic_mihomo "$id" "$name" ;;
    trojan:mihomo) render_trojan_mihomo "$id" "$name" ;;
    trojan:surge) render_trojan_surge "$id" "$name" ;;
    trojan:loon) render_trojan_loon "$id" "$name" ;;
    *) return 2 ;;
  esac
}

export_anytls() {
  local id=$1 name="FRM-AnyTLS"
  printf '%s\n' '--- Mihomo / OpenClash / FlClash ---'
  render_anytls_mihomo "$id" "$name"
  printf '\n%s\n' '--- Surge ---'
  render_anytls_surge "$id" "$name"
  printf '\n%s\n' '--- Loon ---'
  render_anytls_loon "$id" "$name"
}

export_hysteria2() {
  local id=$1 name="FRM-Hy2"
  local OBFS_PASSWORD=''
  load_credentials "$id"
  printf '%s\n' '--- Mihomo / OpenClash / FlClash ---'
  render_hysteria2_mihomo "$id" "$name"
  printf '\n%s\n' '--- Surge ---'
  render_hysteria2_surge "$id" "$name"
  printf '\n%s\n' '--- Loon ---'
  if [[ -n ${OBFS_PASSWORD:-} ]]; then
    printf '%s\n' '当前实例启用了 Salamander，请在 Loon 中导入下方通用 URI，避免手写参数产生兼容差异。'
  else
    render_hysteria2_loon "$id" "$name"
  fi
  printf '\n%s\n' '--- 通用 URI ---'
  render_hysteria2_uri "$id" "$name"
}

export_snell() {
  local id=$1 name note='Snell 仅导出给 Surge。'
  local MODE='' SNELL_VERSION=''
  load_credentials "$id"
  name="FRM-Snell-v$SNELL_VERSION"
  if [[ ${MODE:-native} == *shadowtls ]]; then
    name="$name-ShadowTLS"
    if [[ ${MODE:-} == legacy-shadowtls ]]; then
      note='这是原节点的旧版 ShadowTLS 拓扑，frm-node 仅按现状兼容接管，没有主动改造。'
    fi
  fi
  printf '%s\n' '--- Surge ---'
  render_snell_surge "$id" "$name"
  printf '\n说明：%s 新建 Snell v6 仍固定使用官方原生流量整形，不叠加 ShadowTLS。\n' "$note"
}

export_reality() {
  local id=$1 name="FRM-Reality"
  printf '%s\n' '--- Mihomo / OpenClash / FlClash ---'
  render_reality_mihomo "$id" "$name"
  printf '\n%s\n' '--- Loon ---'
  render_reality_loon "$id" "$name"
  printf '\n%s\n' '--- 通用 URI ---'
  render_reality_uri "$id" "$name"
}

export_tuic() {
  local id=$1 name="FRM-TUIC"
  printf '%s\n' '--- Mihomo / OpenClash / FlClash ---'
  render_tuic_mihomo "$id" "$name"
  printf '\n%s\n' '--- 通用 URI ---'
  render_tuic_uri "$id" "$name"
}

export_trojan() {
  local id=$1 name="FRM-Trojan"
  printf '%s\n' '--- Mihomo / OpenClash / FlClash ---'
  render_trojan_mihomo "$id" "$name"
  printf '\n%s\n' '--- Surge ---'
  render_trojan_surge "$id" "$name"
  printf '\n%s\n' '--- Loon ---'
  render_trojan_loon "$id" "$name"
  printf '\n%s\n' '--- 通用 URI ---'
  render_trojan_uri "$id" "$name"
}

export_adopted_metadata() {
  local id=$1
  cat <<EOF
该协议已纳入兼容接管，但 frm-node 当前还没有对应的客户端导出器。
来源：$(registry_get "$id" '.source')
协议：$(registry_get "$id" '.protocol')
端口：$(registry_get "$id" '.port')/$(registry_get "$id" '.transport')
原配置：$(registry_get "$id" '.config_file')
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
    tuic) export_tuic "$id" ;;
    trojan) export_trojan "$id" ;;
    *)
      if registry_is_external "$id"; then export_adopted_metadata "$id"; else die "尚未实现 $protocol 的导出器。"; fi
      ;;
  esac
  printf '%s\n' '================================================'
}

export_all() {
  local id found=0
  while IFS= read -r id; do
    found=1
    export_instance "$id"
  done < <(registry_ids)
  (( found == 1 )) || warn "尚未安装任何节点。"
}
