#!/usr/bin/env bash

protocol_install_snell() {
  local major=$1 mode=${2:-native} id port listen_port psk ip service stls_service='' credential config version
  local stls_password='' stls_sni=''
  [[ $major =~ ^[456]$ ]] || die "仅支持 Snell 4、5、6。"
  [[ $mode == native || $mode == shadowtls ]] || die "未知 Snell 部署模式：$mode"
  if [[ $major == 6 && $mode == shadowtls ]]; then
    die "Snell v6 使用原生流量整形，不提供 ShadowTLS 模式。"
  fi
  id=$(unique_instance_id "snell$major${mode/native/}")
  port=$(ask_value "Snell v$major TCP 端口" "$(random_port tcp)")
  validate_port "$port"
  port_available tcp "$port" || die "TCP 端口 $port 已被占用。"
  listen_port=$port
  if [[ $mode == shadowtls ]]; then
    listen_port=$(random_port tcp)
    while [[ $listen_port == "$port" ]]; do listen_port=$(random_port tcp); done
    stls_sni=$(ask_value "ShadowTLS 握手域名（必须支持 TLS 1.3）" "www.apple.com")
    timeout 10 openssl s_client -connect "$stls_sni:443" -servername "$stls_sni" -tls1_3 </dev/null >/dev/null 2>&1 || \
      die "$stls_sni 的 TLS 1.3 握手检查失败。"
    stls_password=$(random_hex 16)
  fi
  psk=$(random_hex 16)
  ip=$(public_ipv4)
  service="frm-${id}.service"
  [[ $mode == native ]] || stls_service="frm-${id}-shadowtls.service"
  credential=$(credential_path "$id")
  config=$(config_path "$id")
  case $major in
    4) version=$SNELL4_VERSION ;;
    5) version=$SNELL5_VERSION ;;
    6) version=$SNELL6_VERSION ;;
  esac

  [[ $major != 6 ]] || warn "Snell v6 仍为测试版；采用原生流量整形，不叠加 ShadowTLS。"
  trap 'protocol_rollback_multi "$id" "$service" "$stls_service"' ERR
  ensure_snell_binary "$major"
  [[ $mode == native ]] || ensure_shadowtls_binary
  {
    printf '[snell-server]\n'
    if [[ $mode == native ]]; then
      printf 'listen = 0.0.0.0:%s\n' "$listen_port"
    else
      printf 'listen = 127.0.0.1:%s\n' "$listen_port"
    fi
    printf 'psk = %s\n' "$psk"
    [[ $major != 6 ]] || printf 'dns-ip-preference = prefer-ipv4\n'
  } >"$config"
  chmod 0600 "$config"
  write_credentials "$id" SERVER_IPV4 "$ip" PORT "$port" INTERNAL_PORT "$listen_port" PSK "$psk" \
    SNELL_VERSION "$major" MODE "$mode" SHADOWTLS_PASSWORD "$stls_password" SHADOWTLS_SNI "$stls_sni"
  write_service_unit "$service" "frm-node Snell v$major ($id)" \
    "$FRM_BIN_DIR/snell-server-v$major -c $config" "" "$config"
  enable_service_checked "$service" tcp "$listen_port"
  if [[ $mode == shadowtls ]]; then
    write_service_unit "$stls_service" "frm-node ShadowTLS v3 for Snell v$major ($id)" \
      "$FRM_BIN_DIR/shadow-tls --fastopen --v3 server --listen 0.0.0.0:$port --server 127.0.0.1:$listen_port --tls $stls_sni:443 --password $stls_password"
    enable_service_checked "$stls_service" tcp "$port"
  fi
  firewall_open "$port" tcp "frm-node Snell v$major"
  if [[ $mode == native ]]; then
    registry_write "$id" "snell$major" "Snell v$major" "$port" tcp "$version" "$credential" "$config" "$service"
  else
    registry_write "$id" "snell$major" "Snell v$major + ShadowTLS v3" "$port" tcp "$version" "$credential" "$config" "$service" "$stls_service"
  fi
  trap - ERR
  log_action "installed $id snell$major tcp/$port"
  if [[ $mode == native ]]; then
    ok "Snell v$major 原生模式已安装：$id"
  else
    ok "Snell v$major + ShadowTLS v3 已安装：$id"
  fi
  export_instance "$id"
}
