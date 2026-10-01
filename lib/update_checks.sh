#!/usr/bin/env bash

# The check/preflight entry points are read-only; download/restart helpers are
# used only by the explicitly requested mutating update path.
update_core_rows() {
  printf '%s\n' \
    'anytls anytls-server anytls anytls/anytls-go' \
    'hysteria2 hysteria hysteria2 HyNetworks/hysteria' \
    'xray xray reality XTLS/Xray-core' \
    'snell4 snell-server-v4 snell4 pinned' \
    'snell5 snell-server-v5 snell5 pinned' \
    'snell6 snell-server-v6 snell6 pinned'
}

update_owned_ids() {
  local protocol=$1 id
  while IFS= read -r id; do
    registry_is_external "$id" && continue
    [[ $(registry_get "$id" '.protocol') != "$protocol" ]] || printf '%s\n' "$id"
  done < <(registry_ids)
}

update_health_instance() {
  local id=$1 samples=${FRM_UPDATE_HEALTH_SAMPLES:-3} interval=${FRM_UPDATE_HEALTH_INTERVAL:-2}
  local sample service fingerprint previous port transport flag services
  local -A seen=()
  [[ $samples =~ ^[1-9][0-9]?$ && $interval =~ ^[1-9][0-9]?$ ]] || return 1
  (( samples >= 2 && samples <= 30 && interval >= 1 && interval <= 10 )) || return 1
  services=$(instance_services "$id") || return 1
  [[ -n $services ]] || return 1
  port=$(registry_get "$id" '.port') || return 1
  transport=$(registry_get "$id" '.transport') || return 1
  [[ $port =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || return 1
  case $transport in tcp) flag=-lnt ;; udp) flag=-lnu ;; *) return 1 ;; esac
  for ((sample=0; sample<samples; sample++)); do
    # Allow one interval for a just-restarted process to open its listener.
    sleep "$interval"
    while IFS= read -r service; do
      systemctl is-active --quiet "$service" || return 1
      fingerprint=$(systemctl show "$service" --property=MainPID,NRestarts,ExecMainStartTimestampMonotonic) || return 1
      # Require a live PID; fingerprint must remain unchanged across the window.
      grep -Eq '^MainPID=[1-9][0-9]*$' <<<"$fingerprint" || return 1
      previous=${seen[$service]:-}
      [[ -z $previous || $previous == "$fingerprint" ]] || return 1
      seen[$service]=$fingerprint
    done <<<"$services"
    ss -H "$flag" "sport = :$port" | grep -q . || return 1
  done
}

update_restart_instance() {
  local id=$1 service services failed=0
  services=$(instance_services "$id") || return 1
  [[ -n $services ]] || return 1
  while IFS= read -r service; do
    systemctl restart "$service" || failed=1
  done <<<"$services"
  return "$failed"
}

update_preflight() {
  local tool core file protocol upstream id config credential available required record arch total=0 failed=0
  for tool in jq systemctl ss df stat cp mv curl unzip timeout; do
    command -v "$tool" >/dev/null 2>&1 || { warn "预检缺少命令：$tool"; failed=1; }
  done
  (( failed == 0 )) || return 1
  arch=$(uname -m)
  case $arch in x86_64|amd64|aarch64|arm64|armv7l|i386|i686) ;; *)
    warn '当前架构不支持自动更新；请保留当前核心。'; return 1 ;;
  esac
  [[ -d $FRM_REGISTRY_DIR && -r $FRM_REGISTRY_DIR ]] || { warn '实例登记目录不可读。'; return 1; }
  while IFS= read -r id; do
    record=$(registry_path "$id")
    if ! jq -e --arg id "$id" '
      type == "object" and .id == $id and
      (.protocol | type == "string") and
      ((.ownership // "frm") | IN("frm", "adopted", "taken-over")) and
      (.services | type == "array" and length > 0 and all(.[]; type == "string" and length > 0))
    ' "$record" >/dev/null 2>&1; then
      warn "实例登记无效，停止预检。"; return 1
    fi
  done < <(registry_ids)
  while read -r core file protocol upstream; do
    [[ -x $FRM_BIN_DIR/$file ]] || continue
    ((total+=1))
    if [[ $core != snell* && $arch != x86_64 && $arch != amd64 && $arch != aarch64 && $arch != arm64 ]]; then
      warn "$core 不支持当前架构，停止更新。"; failed=1
    fi
    [[ -w $FRM_BIN_DIR && -w $FRM_BACKUP_DIR ]] || { warn '核心或备份目录不可写。'; failed=1; }
    required=$(stat -c '%s' "$FRM_BIN_DIR/$file") || return 1
    available=$(df -Pk "$FRM_BIN_DIR" | awk 'NR==2 {print $4}')
    # A conservative headroom check, not an exact archive size prediction.
    if [[ ! $available =~ ^[0-9]+$ ]] || (( available * 1024 < required * 3 + 104857600 )); then
      warn "$core 更新空间不足（要求核心大小三倍另加 100 MiB 余量）。"; failed=1
    fi
    info "$core 将检查 FRM 原生实例；接管实例跳过。"
    while IFS= read -r id; do
      config=$(registry_get "$id" '.config_file // ""') || return 1
      credential=$(registry_get "$id" '.credential_file // ""') || return 1
      if [[ -z $config || ! -r $config || -z $credential || ! -r $credential ]]; then
        warn "$id 配置或凭据不可读。"; failed=1; continue
      fi
      update_health_instance "$id" || { warn "$id 当前服务或监听不稳定。"; failed=1; }
    done < <(update_owned_ids "$protocol")
  done < <(update_core_rows)
  info "预检完成：$total 个已安装核心；未下载或重启。"
  (( failed == 0 ))
}

check_core_updates() {
  local core file protocol upstream response latest normalized_latest installed output failed=0 var total=0
  require_command curl
  require_command jq
  require_command timeout
  while read -r core file protocol upstream; do
    [[ -x $FRM_BIN_DIR/$file ]] || continue
    ((total+=1))
    output=''
    case $core in
      anytls) output=$(timeout -k 1 3 "$FRM_BIN_DIR/$file" -version 2>/dev/null) || output='' ;;
      hysteria2|xray) output=$(timeout -k 1 3 "$FRM_BIN_DIR/$file" version 2>/dev/null) || output='' ;;
      snell*) output=$(timeout -k 1 3 "$FRM_BIN_DIR/$file" --version 2>/dev/null) || output='' ;;
    esac
    installed=$(grep -Eo '[0-9]+\.[0-9]+\.[0-9]+([a-zA-Z][a-zA-Z0-9.-]*|-[a-zA-Z0-9.-]+)?' <<<"$output" | head -n 1) || installed=''
    if [[ $upstream == pinned ]]; then
      var="${core^^}_VERSION"
      printf '%s：当前=%s；锁定目标=%s（非在线最新版，需人工核对官方公告）\n' "$core" "${installed:-未知}" "${!var}"
      continue
    fi
    if ! response=$(curl --proto '=https' --proto-redir '=https' -fLsS --connect-timeout 5 --max-time 15 \
      "https://api.github.com/repos/$upstream/releases/latest"); then
      warn "$core 版本检查失败（网络或 API 限流）；未更新。"; failed=1; continue
    fi
    latest=$(jq -er 'select(.draft == false and .prerelease == false) | .tag_name | strings' <<<"$response" 2>/dev/null) || latest=''
    normalized_latest=$latest
    [[ $core != hysteria2 ]] || normalized_latest=${normalized_latest#app/}
    normalized_latest=${normalized_latest#v}
    if [[ ! $normalized_latest =~ ^[0-9]+\.[0-9]+\.[0-9]+([a-zA-Z][a-zA-Z0-9.-]*|-[a-zA-Z0-9.-]+)?$ ]]; then
      warn "$core 发布元数据不可用；未更新。"; failed=1; continue
    fi
    if [[ -n $installed && $installed == "$normalized_latest" ]]; then
      printf '%s：当前=%s；上游=%s（版本相同）\n' "$core" "$installed" "$latest"
    else
      printf '%s：当前=%s；上游=%s（请人工核对版本差异，不自动升级）\n' "$core" "${installed:-未知}" "$latest"
    fi
  done < <(update_core_rows)
  (( total > 0 )) || info "未发现 FRM 核心目录中的已安装核心。"
  return "$failed"
}

# Only called by the explicit mutating update path, never --check/--dry-run.
update_download_core() {
  FRM_FORCE_DOWNLOAD=1 FRM_BIN_DIR="$FRM_BIN_DIR" FRM_LOG="$FRM_LOG" \
    bash --noprofile --norc -Eeuo pipefail -c '
      home=$1; core=$2
      source "$home/versions.env"
      source "$home/lib/common.sh"
      source "$home/lib/download.sh"
      source "$home/protocols/base.sh"
      case $core in
        anytls) ensure_anytls_binary ;;
        hysteria2) ensure_hysteria_binary ;;
        xray) ensure_xray_binary ;;
        snell4) ensure_snell_binary 4 ;;
        snell5) ensure_snell_binary 5 ;;
        snell6) ensure_snell_binary 6 ;;
        *) exit 1 ;;
      esac
    ' bash "$FRM_HOME" "$1"
}
