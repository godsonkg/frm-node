#!/usr/bin/env bash

protocol_install_hysteria2() {
  local id port password sni ip service credential config cert key obfs_password=''
  id=$(unique_instance_id hysteria2)
  port=$(ask_value "Hysteria2 UDP 端口" "$(random_port udp)")
  validate_port "$port"
  port_available udp "$port" || die "UDP 端口 $port 已被占用。"
  sni=$(ask_value "TLS 伪装域名" "www.apple.com")
  password=$(random_hex 16)
  ip=$(public_ipv4)
  service="frm-${id}.service"
  credential=$(credential_path "$id")
  config="$FRM_INSTANCE_DIR/$id.yaml"
  cert="$FRM_INSTANCE_DIR/$id.crt"
  key="$FRM_INSTANCE_DIR/$id.key"
  if confirm "启用 Salamander 混淆" N; then
    obfs_password=$(random_hex 16)
  fi

  trap 'protocol_rollback "$id" "$service"; rm -f "$config" "$cert" "$key"' ERR
  ensure_hysteria_binary
  openssl req -x509 -nodes -newkey rsa:2048 -sha256 -days 3650 \
    -keyout "$key" -out "$cert" -subj "/CN=$sni" \
    -addext "subjectAltName=DNS:$sni" >/dev/null 2>&1
  chmod 0600 "$key" "$cert"
  {
    printf 'listen: 0.0.0.0:%s\n' "$port"
    printf 'tls:\n  cert: %s\n  key: %s\n' "$cert" "$key"
    printf 'auth:\n  type: password\n  password: "%s"\n' "$password"
    if [[ -n $obfs_password ]]; then
      printf 'obfs:\n  type: salamander\n  salamander:\n    password: "%s"\n' "$obfs_password"
    fi
    printf 'masquerade:\n  type: proxy\n  proxy:\n    url: https://www.apple.com/\n    rewriteHost: true\n'
  } >"$config"
  chmod 0600 "$config"
  write_credentials "$id" SERVER_IPV4 "$ip" PORT "$port" PASSWORD "$password" SNI "$sni" OBFS_PASSWORD "$obfs_password"
  write_service_unit "$service" "frm-node Hysteria2 ($id)" \
    "$FRM_BIN_DIR/hysteria server -c $config" "" "$FRM_INSTANCE_DIR"
  enable_service_checked "$service" udp "$port"
  firewall_open "$port" udp "frm-node Hysteria2"
  registry_write "$id" hysteria2 "Hysteria2" "$port" udp latest "$credential" "$config" "$service"
  trap - ERR
  log_action "installed $id hysteria2 udp/$port"
  ok "Hysteria2 已安装：$id"
  export_instance "$id"
}

