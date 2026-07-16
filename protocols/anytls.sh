#!/usr/bin/env bash

protocol_install_anytls() {
  local id port password sni ip service credential
  id=$(unique_instance_id anytls)
  port=$(ask_value "AnyTLS TCP 端口" "$(random_port tcp)")
  validate_port "$port"
  port_available tcp "$port" || die "TCP 端口 $port 已被占用。"
  sni=$(ask_value "客户端伪装 SNI" "www.apple.com")
  password=$(random_hex 16)
  ip=$(public_ipv4)
  service="frm-${id}.service"
  credential=$(credential_path "$id")

  trap 'protocol_rollback "$id" "$service"' ERR
  ensure_anytls_binary
  write_credentials "$id" SERVER_IPV4 "$ip" PORT "$port" PASSWORD "$password" SNI "$sni"
  write_service_unit "$service" "frm-node AnyTLS ($id)" \
    "$FRM_BIN_DIR/anytls-server -l 0.0.0.0:\${PORT} -p \${PASSWORD}" "$credential"
  enable_service_checked "$service" tcp "$port"
  firewall_open "$port" tcp "frm-node AnyTLS"
  registry_write "$id" anytls "AnyTLS" "$port" tcp latest "$credential" "" "$service"
  trap - ERR
  log_action "installed $id anytls tcp/$port"
  ok "AnyTLS 已安装：$id"
  export_instance "$id"
}

