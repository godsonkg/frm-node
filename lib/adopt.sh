#!/usr/bin/env bash

# Compatibility adapters are deliberately read-only: registration never rewrites
# an upstream config, unit, binary, cron job, firewall rule, or subscription.

adopt_path() {
  printf '%s%s\n' "${FRM_ADOPT_ROOT:-}" "$1"
}

adopt_service_state() {
  if [[ -n ${FRM_ADOPT_ROOT:-} ]]; then
    printf '测试样本\n'
  else
    systemctl is-active "$1" 2>/dev/null || printf '未运行\n'
  fi
}

adopt_row() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@"
}

adopt_vless_service() {
  local core=$1 proto=$2
  case $proto in
    hy2|tuic|ss2022|ss-legacy) printf 'vless-singbox.service\n' ;;
    snell) printf 'vless-snell.service\n' ;;
    snell-v5) printf 'vless-snell-v5.service\n' ;;
    anytls) printf 'vless-anytls.service\n' ;;
    naive) printf 'vless-naive.service\n' ;;
    snell-shadowtls) printf 'vless-snell-shadowtls.service,vless-snell-shadowtls-backend.service\n' ;;
    snell-v5-shadowtls) printf 'vless-snell-v5-shadowtls.service,vless-snell-v5-shadowtls-backend.service\n' ;;
    ss2022-shadowtls) printf 'vless-ss2022-shadowtls.service,vless-ss2022-shadowtls-backend.service\n' ;;
    *) [[ $core == xray ]] && printf 'vless-reality.service\n' || printf 'vless-singbox.service\n' ;;
  esac
}

adopt_protocol_name() {
  case $1 in
    vless) printf 'reality\n' ;;
    hy2) printf 'hysteria2\n' ;;
    snell) printf 'snell4\n' ;;
    snell-v5) printf 'snell5\n' ;;
    snell-shadowtls) printf 'snell4\n' ;;
    snell-v5-shadowtls) printf 'snell5\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

adopt_transport() {
  case $1 in hy2|hysteria2|tuic) printf 'udp\n' ;; *) printf 'tcp\n' ;; esac
}

adopt_scan_vless_all_in_one() {
  local db core proto item port service transport state
  db=$(adopt_path /etc/vless-reality/db.json)
  [[ -r $db ]] || return 0
  while IFS=$'\t' read -r core proto item; do
    [[ -n $proto ]] || continue
    item=${item//$'\r'/}
    port=$(printf '%s' "$item" | base64 -d | jq -r '.outer_port // .port // empty')
    [[ $port =~ ^[0-9]+$ ]] || port='?'
    service=$(adopt_vless_service "$core" "$proto")
    transport=$(adopt_transport "$proto")
    state=$(adopt_service_state "${service%%,*}")
    adopt_row vless-all-in-one "$(adopt_protocol_name "$proto")" "$port" "$transport" "$service" "$db" "$state"
  done < <(jq -r '
    [{key:"xray",value:(.xray // {})},{key:"singbox",value:(.singbox // {})}][] as $core |
    $core.value | to_entries[] |
    .key as $proto | (if (.value|type)=="array" then .value[] else .value end) |
    [$core.key,$proto,(.|@base64)] | @tsv' "$db" 2>/dev/null)
}

adopt_scan_v2ray_agent() {
  local base file proto port transport service state
  base=$(adopt_path /etc/v2ray-agent)
  [[ -d $base ]] || return 0
  for file in \
    "$base/xray/conf/07_VLESS_vision_reality_inbounds.json" \
    "$base/sing-box/conf/config/06_hysteria2_inbounds.json" \
    "$base/sing-box/conf/config/09_tuic_inbounds.json" \
    "$base/sing-box/conf/config/13_anytls_inbounds.json"; do
    [[ -r $file ]] || continue
    case $file in
      *07_VLESS*) proto=reality; transport=tcp; service=xray.service ;;
      *06_hysteria2*) proto=hysteria2; transport=udp; service=sing-box.service ;;
      *09_tuic*) proto=tuic; transport=udp; service=sing-box.service ;;
      *) proto=anytls; transport=tcp; service=sing-box.service ;;
    esac
    port=$(jq -r '.inbounds[0].port // .inbounds[0].listen_port // empty' "$file" 2>/dev/null)
    [[ $port =~ ^[0-9]+$ ]] || port='?'
    state=$(adopt_service_state "$service")
    adopt_row v2ray-agent "$proto" "$port" "$transport" "$service" "$file" "$state"
  done

  # Keep composite nginx/fallback protocols visible in the report. Their public
  # endpoint cannot be inferred safely from an inbound fragment alone.
  shopt -s nullglob
  for file in "$base/xray/conf/"*_inbounds.json "$base/sing-box/conf/config/"*_inbounds.json; do
    case $file in
      *07_VLESS_vision_reality_inbounds.json|*06_hysteria2_inbounds.json|*09_tuic_inbounds.json|*13_anytls_inbounds.json) continue ;;
    esac
    if [[ $file == *'/xray/'* ]]; then
      service=xray.service
      proto=$(jq -r '[.inbounds[] | select(.protocol != "dokodemo-door") | .protocol][0] // "unknown"' "$file" 2>/dev/null)
      port=$(jq -r '.inbounds[0].port // empty' "$file" 2>/dev/null)
    else
      service=sing-box.service
      proto=$(jq -r '.inbounds[0].type // "unknown"' "$file" 2>/dev/null)
      port=$(jq -r '.inbounds[0].listen_port // empty' "$file" 2>/dev/null)
    fi
    [[ $port =~ ^[0-9]+$ ]] || port='?'
    adopt_row v2ray-agent "待适配:$proto" "$port" '?' "$service" "$file" '需核对外层端口'
  done
  shopt -u nullglob
}

adopt_snell_version() {
  local config=$1 unit binary output version
  version=$(sed -nE 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*([456]).*/\1/p' "$config" | head -n 1)
  [[ -n $version ]] && { printf '%s\n' "$version"; return; }
  unit=$(adopt_path /etc/systemd/system/snell.service)
  binary=$(sed -nE 's|^ExecStart=([^ ]+).*|\1|p' "$unit" 2>/dev/null | head -n 1)
  [[ -x $binary ]] || binary=$(adopt_path /usr/local/bin/snell-server)
  if [[ -x $binary && -z ${FRM_ADOPT_ROOT:-} ]]; then
    output=$({ "$binary" --version || "$binary" -v; } 2>&1 || true)
    version=$(grep -Eo '([Vv]ersion[[:space:]]*|[Vv])([456])([.]|[^0-9]|$)' <<<"$output" | grep -Eo '[456]' | head -n 1)
  fi
  printf '%s\n' "${version:-${FRM_ADOPT_SNELL_VERSION:-unknown}}"
}

adopt_scan_manual_snell() {
  local config unit version port state
  config=$(adopt_path /etc/snell-server.conf)
  unit=$(adopt_path /etc/systemd/system/snell.service)
  [[ -r $config && -r $unit ]] || return 0
  version=$(adopt_snell_version "$config")
  port=$(sed -nE 's/^[[:space:]]*listen[[:space:]]*=.*:([0-9]+)[[:space:]]*$/\1/p' "$config" | head -n 1)
  [[ $port =~ ^[0-9]+$ ]] || port='?'
  state=$(adopt_service_state snell.service)
  adopt_row manual-snell "snell${version}" "$port" tcp snell.service "$config" "$state"
}

adopt_scan_raw() {
  adopt_scan_vless_all_in_one
  adopt_scan_v2ray_agent
  adopt_scan_manual_snell
}

adopt_scan() {
  local found=0 source protocol port transport service config state
  printf '=== frm-node 兼容接管扫描（只读）===\n'
  printf '%-18s %-18s %-7s %-5s %-42s %-10s\n' 来源 协议 端口 传输 服务 状态
  printf '%-18s %-18s %-7s %-5s %-42s %-10s\n' ------------------ ------------------ ------- ----- ------------------------------------------ ----------
  while IFS=$'\t' read -r source protocol port transport service config state; do
    found=1
    printf '%-18s %-18s %-7s %-5s %-42s %-10s\n' "$source" "$protocol" "$port" "$transport" "$service" "$state"
  done < <(adopt_scan_raw)
  if (( found == 0 )); then
    info "没有识别到 v2ray-agent、vless-all-in-one 或独立 Snell 服务。"
  else
    printf '\n扫描没有读取或输出任何密码、UUID、PSK、私钥。\n'
  fi
}

adopt_report() {
  local source protocol port transport service config state
  printf 'frm-node 兼容接管脱敏报告\n生成时间：%s\n\n' "$(date -Is)"
  while IFS=$'\t' read -r source protocol port transport service config state; do
    printf -- '- 来源：%s；协议：%s；端口：%s/%s；服务：%s；状态：%s；配置：%s\n' \
      "$source" "$protocol" "$port" "$transport" "$service" "$state" "$config"
  done < <(adopt_scan_raw)
}

adopt_already_registered() {
  local source=$1 config=$2 port=$3 file
  shopt -s nullglob
  for file in "$FRM_REGISTRY_DIR"/*.json; do
    jq -e --arg s "$source" --arg c "$config" --argjson p "$port" \
      '(.source==$s) and (.config_file==$c) and (.port==$p)' "$file" >/dev/null 2>&1 && {
        shopt -u nullglob
        return 0
      }
  done
  shopt -u nullglob
  return 1
}

adopt_register_record() {
  local source=$1 source_proto=$2 port=$3 transport=$4 services_csv=$5 config=$6 binary=$7 manager=$8
  shift 8
  local protocol id credential core_group
  protocol=$(adopt_protocol_name "$source_proto")
  [[ $port =~ ^[0-9]+$ ]] || { warn "跳过 $source/$source_proto：无法确认监听端口。"; return 1; }
  adopt_already_registered "$source" "$config" "$port" && { info "已登记，跳过：$source_proto:$port"; return 0; }
  id=$(unique_instance_id "adopt-${source}-${protocol}-${port}")
  credential=$(credential_path "$id")
  write_credentials "$id" SERVER_IPV4 "$(public_ipv4)" PORT "$port" "$@"
  IFS=',' read -r -a services <<<"$services_csv"
  core_group="$source:${services[0]}"
  registry_write "$id" "$protocol" "$protocol（兼容接管）" "$port" "$transport" legacy \
    "$credential" "$config" "${services[@]}"
  registry_mark_adopted "$id" "$source" "$core_group" "$binary" "$manager"
  ok "已登记 $id；没有改动或重启原服务。"
}

adopt_register_vless_all_in_one() {
  local db core proto item json port service transport mode version binary
  db=$(adopt_path /etc/vless-reality/db.json)
  [[ -r $db ]] || return 0
  while IFS=$'\t' read -r core proto item; do
    item=${item//$'\r'/}
    json=$(printf '%s' "$item" | base64 -d)
    port=$(jq -r '.outer_port // .port // empty' <<<"$json")
    service=$(adopt_vless_service "$core" "$proto")
    transport=$(adopt_transport "$proto")
    case $proto in
      vless)
        adopt_register_record vless-all-in-one "$proto" "$port" "$transport" "$service" "$db" /usr/local/bin/xray /etc/vless-reality/vless-server.sh \
          UUID "$(jq -r '.uuid // empty' <<<"$json")" PUBLIC_KEY "$(jq -r '.public_key // empty' <<<"$json")" \
          SHORT_ID "$(jq -r '.short_id // empty' <<<"$json")" SNI "$(jq -r '.sni // empty' <<<"$json")" ;;
      hy2)
        adopt_register_record vless-all-in-one "$proto" "$port" "$transport" "$service" "$db" /usr/local/bin/sing-box /etc/vless-reality/vless-server.sh \
          PASSWORD "$(jq -r '.password // empty' <<<"$json")" SNI "$(jq -r '.sni // empty' <<<"$json")" OBFS_PASSWORD "$(jq -r '.obfs_password // empty' <<<"$json")" ;;
      anytls)
        adopt_register_record vless-all-in-one "$proto" "$port" "$transport" "$service" "$db" /usr/local/bin/anytls-server /etc/vless-reality/vless-server.sh \
          PASSWORD "$(jq -r '.password // empty' <<<"$json")" SNI "$(jq -r '.sni // empty' <<<"$json")" ;;
      tuic)
        adopt_register_record vless-all-in-one "$proto" "$port" "$transport" "$service" "$db" /usr/local/bin/sing-box /etc/vless-reality/vless-server.sh \
          UUID "$(jq -r '.uuid // empty' <<<"$json")" PASSWORD "$(jq -r '.password // empty' <<<"$json")" SNI "$(jq -r '.sni // empty' <<<"$json")" ;;
      snell|snell-v5|snell-shadowtls|snell-v5-shadowtls)
        version=$(jq -r '.version // empty' <<<"$json")
        [[ -n $version ]] || { [[ $proto == *v5* ]] && version=5 || version=4; }
        mode=native; [[ $proto == *shadowtls ]] && mode=shadowtls
        binary=/usr/local/bin/snell-server
        [[ $version == 5 ]] && binary=/usr/local/bin/snell-server-v5
        adopt_register_record vless-all-in-one "$proto" "$port" tcp "$service" "$db" "$binary" /etc/vless-reality/vless-server.sh \
          PSK "$(jq -r '.psk // empty' <<<"$json")" SNELL_VERSION "$version" MODE "$mode" \
          SHADOWTLS_PASSWORD "$(jq -r '.stls_password // empty' <<<"$json")" SHADOWTLS_SNI "$(jq -r '.sni // empty' <<<"$json")" ;;
      *)
        adopt_register_record vless-all-in-one "$proto" "$port" "$transport" "$service" "$db" "" /etc/vless-reality/vless-server.sh ;;
    esac
  done < <(jq -r '
    [{key:"xray",value:(.xray // {})},{key:"singbox",value:(.singbox // {})}][] as $core |
    $core.value | to_entries[] | .key as $proto |
    (if (.value|type)=="array" then .value[] else .value end) |
    [$core.key,$proto,(.|@base64)] | @tsv' "$db")
}

adopt_register_v2ray_agent() {
  local base file port uuid password sni private public short
  base=$(adopt_path /etc/v2ray-agent)
  file="$base/xray/conf/07_VLESS_vision_reality_inbounds.json"
  if [[ -r $file ]]; then
    port=$(jq -r '.inbounds[0].port // empty' "$file")
    uuid=$(jq -r '[.inbounds[] | select(.protocol=="vless") | .settings.clients[]?.id][0] // empty' "$file")
    sni=$(jq -r '[.inbounds[] | select(.protocol=="vless") | .streamSettings.realitySettings.serverNames[0]][0] // empty' "$file")
    private=$(jq -r '[.inbounds[] | select(.protocol=="vless") | .streamSettings.realitySettings.privateKey][0] // empty' "$file")
    public=$(jq -r '[.inbounds[] | select(.protocol=="vless") | .streamSettings.realitySettings.publicKey][0] // empty' "$file")
    short=$(jq -r '[.inbounds[] | select(.protocol=="vless") | .streamSettings.realitySettings.shortIds[] | select(length>0)][0] // empty' "$file")
    adopt_register_record v2ray-agent reality "$port" tcp xray.service "$file" /etc/v2ray-agent/xray/xray /etc/v2ray-agent/install.sh \
      UUID "$uuid" PRIVATE_KEY "$private" PUBLIC_KEY "$public" SHORT_ID "$short" SNI "$sni"
  fi
  for file in "$base/sing-box/conf/config/06_hysteria2_inbounds.json" "$base/sing-box/conf/config/09_tuic_inbounds.json" "$base/sing-box/conf/config/13_anytls_inbounds.json"; do
    [[ -r $file ]] || continue
    port=$(jq -r '.inbounds[0].listen_port // empty' "$file")
    sni=$(jq -r '.inbounds[0].tls.server_name // empty' "$file")
    case $file in
      *06_hysteria2*)
        password=$(jq -r '.inbounds[0].users[0].password // empty' "$file")
        adopt_register_record v2ray-agent hysteria2 "$port" udp sing-box.service "$file" /etc/v2ray-agent/sing-box/sing-box /etc/v2ray-agent/install.sh PASSWORD "$password" SNI "$sni" OBFS_PASSWORD "" ;;
      *09_tuic*)
        uuid=$(jq -r '.inbounds[0].users[0].uuid // empty' "$file"); password=$(jq -r '.inbounds[0].users[0].password // empty' "$file")
        adopt_register_record v2ray-agent tuic "$port" udp sing-box.service "$file" /etc/v2ray-agent/sing-box/sing-box /etc/v2ray-agent/install.sh UUID "$uuid" PASSWORD "$password" SNI "$sni" ;;
      *)
        password=$(jq -r '.inbounds[0].users[0].password // empty' "$file")
        adopt_register_record v2ray-agent anytls "$port" tcp sing-box.service "$file" /etc/v2ray-agent/sing-box/sing-box /etc/v2ray-agent/install.sh PASSWORD "$password" SNI "$sni" ;;
    esac
  done
}

adopt_register_manual_snell() {
  local config unit version port psk mode=legacy-native service_list=snell.service stls stls_password='' stls_sni=''
  config=$(adopt_path /etc/snell-server.conf)
  unit=$(adopt_path /etc/systemd/system/snell.service)
  [[ -r $config && -r $unit ]] || return 0
  version=$(adopt_snell_version "$config")
  if [[ $version == unknown ]]; then
    warn "发现独立 Snell，但无法无歧义判断 v4/v5/v6；请执行 FRM_ADOPT_SNELL_VERSION=6 frm adopt register。"
    return 1
  fi
  port=$(sed -nE 's/^[[:space:]]*listen[[:space:]]*=.*:([0-9]+)[[:space:]]*$/\1/p' "$config" | head -n 1)
  psk=$(sed -nE 's/^[[:space:]]*psk[[:space:]]*=[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1/p' "$config" | head -n 1)
  stls=$(adopt_path /etc/systemd/system/shadow-tls.service)
  if [[ -r $stls ]]; then
    mode=legacy-shadowtls
    service_list=snell.service,shadow-tls.service
    port=$(sed -nE 's/.*--listen ([^ ]*:)?([0-9]+).*/\2/p' "$stls" | head -n 1)
    stls_password=$(sed -nE 's/.*--password ([^ ]+).*/\1/p' "$stls" | head -n 1)
    stls_sni=$(sed -nE 's/.*--tls ([^ :]+)(:[0-9]+)?.*/\1/p' "$stls" | head -n 1)
  fi
  adopt_register_record manual-snell "snell$version" "$port" tcp "$service_list" "$config" /usr/local/bin/snell-server official \
    PSK "$psk" SNELL_VERSION "$version" MODE "$mode" SHADOWTLS_PASSWORD "$stls_password" SHADOWTLS_SNI "$stls_sni"
}

adopt_register() {
  local before after failed=0
  before=$(registry_ids | wc -l)
  adopt_register_vless_all_in_one || failed=1
  adopt_register_v2ray_agent || failed=1
  adopt_register_manual_snell || failed=1
  after=$(registry_ids | wc -l)
  printf '\n兼容接管登记完成：新增 %d 个实例。原配置、服务、端口和定时任务均未修改。\n' "$((after-before))"
  (( failed == 0 )) || warn "部分项目因信息不完整被跳过，请根据上方提示处理。"
}

adopt_forget() {
  local id=$1
  registry_exists "$id" || die "实例不存在：$id"
  registry_is_adopted "$id" || die "仅兼容接管实例可以使用 adopt forget。"
  confirm "只删除 frm-node 的登记和凭据，不改动原服务，继续吗" N || return 0
  rm -f "$(credential_path "$id")"
  registry_remove "$id"
  ok "已忘记 $id；原节点仍照常运行。"
}

adopt_command() {
  case ${1:-scan} in
    scan|preview) adopt_scan ;;
    report) adopt_report ;;
    register) adopt_register ;;
    forget) [[ -n ${2:-} ]] || die "请指定兼容接管实例。"; adopt_forget "$2" ;;
    takeover) die "完整 takeover 尚未开放。请先运行 adopt register，并在各台 VPS 验证导出和诊断结果。" ;;
    *) die "未知接管命令：$1。可用：scan、report、register、forget。" ;;
  esac
}
