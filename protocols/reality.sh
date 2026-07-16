#!/usr/bin/env bash

reality_target_valid() {
  local host=$1
  timeout 10 bash -c \
    "openssl s_client -connect '$host:443' -servername '$host' -tls1_3 </dev/null 2>/dev/null | openssl x509 -noout -checkhost '$host' >/dev/null 2>&1"
}

select_reality_target() {
  local host
  for host in www.apple.com www.microsoft.com www.samsung.com; do
    if reality_target_valid "$host"; then
      printf '%s\n' "$host"
      return 0
    fi
  done
  return 1
}

protocol_install_reality() {
  local id port ip service credential config target keys private_key public_key uuid short_id default_target
  id=$(unique_instance_id reality)
  port=$(ask_value "Reality TCP 端口" "$(random_port tcp)")
  validate_port "$port"
  port_available tcp "$port" || die "TCP 端口 $port 已被占用。"
  default_target=$(select_reality_target || true)
  [[ -n $default_target ]] || die "没有找到可用的 TLS 1.3 目标，请检查服务器网络。"
  target=$(ask_value "Reality 目标域名" "$default_target")
  reality_target_valid "$target" || die "$target 未通过 TLS 1.3 与证书主机名检查。"
  ip=$(public_ipv4)
  service="frm-${id}.service"
  credential=$(credential_path "$id")
  config="$FRM_INSTANCE_DIR/$id.json"

  trap 'protocol_rollback "$id" "$service"; rm -f "$config"' ERR
  ensure_xray_binary
  keys=$("$FRM_BIN_DIR/xray" x25519)
  private_key=$(awk -F': *' '/PrivateKey|Private key/{print $2; exit}' <<<"$keys")
  public_key=$(awk -F': *' '/Password|PublicKey|Public key/{print $2; exit}' <<<"$keys")
  [[ -n $private_key && -n $public_key ]] || die "无法解析 Xray x25519 密钥。"
  uuid=$("$FRM_BIN_DIR/xray" uuid)
  short_id=$(random_hex 8)
  jq -n \
    --argjson port "$port" --arg uuid "$uuid" --arg target "$target" \
    --arg privateKey "$private_key" --arg shortId "$short_id" \
    '{log:{loglevel:"warning"},inbounds:[{listen:"0.0.0.0",port:$port,protocol:"vless",settings:{clients:[{id:$uuid,flow:"xtls-rprx-vision"}],decryption:"none"},streamSettings:{method:"raw",security:"reality",realitySettings:{show:false,target:($target+":443"),xver:0,serverNames:[$target],privateKey:$privateKey,shortIds:[$shortId],limitFallbackUpload:{afterBytes:0,bytesPerSec:1048576,burstBytesPerSec:2097152},limitFallbackDownload:{afterBytes:0,bytesPerSec:1048576,burstBytesPerSec:2097152}}}}],outbounds:[{protocol:"freedom",tag:"direct"},{protocol:"blackhole",tag:"block"}]}' \
    >"$config"
  chmod 0600 "$config"
  "$FRM_BIN_DIR/xray" run -test -config "$config"
  write_credentials "$id" SERVER_IPV4 "$ip" PORT "$port" UUID "$uuid" SNI "$target" PUBLIC_KEY "$public_key" SHORT_ID "$short_id"
  write_service_unit "$service" "frm-node VLESS Reality ($id)" \
    "$FRM_BIN_DIR/xray run -config $config" "" "$config"
  enable_service_checked "$service" tcp "$port"
  firewall_open "$port" tcp "frm-node Reality"
  registry_write "$id" reality "VLESS Reality Vision" "$port" tcp latest "$credential" "$config" "$service"
  trap - ERR
  log_action "installed $id reality tcp/$port target=$target"
  ok "Reality 已安装：$id"
  export_instance "$id"
}
