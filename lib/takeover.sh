#!/usr/bin/env bash

takeover_latest_link() { printf '%s/latest\n' "$FRM_TAKEOVER_DIR"; }
takeover_latest_file() { printf '%s/latest.path\n' "$FRM_TAKEOVER_DIR"; }

takeover_latest_dir() {
  local link pointer dir
  link=$(takeover_latest_link)
  if [[ -L $link ]]; then
    readlink -f "$link"
    return
  fi
  pointer=$(takeover_latest_file)
  [[ -r $pointer ]] || return 1
  IFS= read -r dir <"$pointer"
  [[ -d $dir ]] || return 1
  printf '%s\n' "$dir"
}

takeover_add_path() {
  local list=$1 path=${2:-} relative
  [[ -n $path && $path == /* && $path != *'..'* && -e $path ]] || return 0
  relative=${path#/}
  grep -Fqx "$relative" "$list" 2>/dev/null || printf '%s\n' "$relative" >>"$list"
}

takeover_registered_sources() {
  local file
  shopt -s nullglob
  for file in "$FRM_REGISTRY_DIR"/*.json; do
    jq -r 'select((.ownership // "frm") == "adopted") | .source' "$file"
  done | tr -d '\r' | sort -u
  shopt -u nullglob
}

takeover_adopted_ids() {
  local file
  shopt -s nullglob
  for file in "$FRM_REGISTRY_DIR"/*.json; do
    jq -r 'select((.ownership // "frm") == "adopted") | .id' "$file"
  done | tr -d '\r'
  shopt -u nullglob
}

takeover_preflight() {
  local id count=0 failed=0
  info "执行接管前健康检查。"
  while IFS= read -r id; do
    [[ -n $id ]] || continue
    ((count+=1))
    doctor_instance "$id" || failed=1
  done < <(takeover_adopted_ids)
  (( count > 0 )) || die "没有等待完整接管的兼容实例。"
  (( failed == 0 )) || die "接管前诊断未通过；没有执行任何修改。"
}

takeover_collect_paths() {
  local list=$1 id service fragment source
  takeover_add_path "$list" "$FRM_ETC"
  takeover_add_path "$list" "$FRM_REGISTRY_DIR"
  while IFS= read -r id; do
    [[ -n $id ]] || continue
    takeover_add_path "$list" "$(registry_get "$id" '.config_file')"
    takeover_add_path "$list" "$(registry_get "$id" '.credential_file')"
    takeover_add_path "$list" "$(registry_get "$id" '.binary_path // empty')"
    takeover_add_path "$list" "$(registry_get "$id" '.manager_path // empty')"
    while IFS= read -r service; do
      fragment=$(systemctl show -p FragmentPath --value "$service" 2>/dev/null || true)
      takeover_add_path "$list" "$fragment"
    done < <(instance_services "$id")
  done < <(takeover_adopted_ids)
  while IFS= read -r source; do
    case $source in
      v2ray-agent) takeover_add_path "$list" /etc/v2ray-agent ;;
      vless-all-in-one)
        takeover_add_path "$list" /etc/vless-reality
        takeover_add_path "$list" /etc/systemd/system/vless-watchdog.service
        ;;
      manual-snell)
        takeover_add_path "$list" /etc/snell-server.conf
        takeover_add_path "$list" /usr/local/bin/snell-server
        takeover_add_path "$list" /usr/local/bin/shadow-tls
        ;;
    esac
  done < <(takeover_registered_sources)
  sort -u -o "$list" "$list"
}

takeover_save_cron() {
  local dir=$1
  if command -v crontab >/dev/null 2>&1 && crontab -l >"$dir/root.cron.before" 2>/dev/null; then
    printf 'yes\n' >"$dir/root.cron.existed"
  else
    : >"$dir/root.cron.before"
    printf 'no\n' >"$dir/root.cron.existed"
  fi
  chmod 0600 "$dir/root.cron.before" "$dir/root.cron.existed"
}

takeover_freeze_cron() {
  local dir=$1 before after removed
  before="$dir/root.cron.before"
  after="$dir/root.cron.after"
  removed="$dir/root.cron.frozen"
  awk '
    /\/etc\/v2ray-agent\/install[.]sh/ ||
    (/vless-server[.]sh/ && (/--check-expire/ || /--sync-traffic/)) { print > frozen; next }
    { print }
  ' frozen="$removed" "$before" >"$after"
  touch "$removed"
  chmod 0600 "$after" "$removed"
  if command -v crontab >/dev/null 2>&1 && ! cmp -s "$before" "$after"; then
    crontab "$after"
  fi
}

takeover_save_watchdog() {
  local dir=$1 enabled=inactive active=inactive
  if systemctl cat vless-watchdog.service >/dev/null 2>&1; then
    enabled=$(systemctl is-enabled vless-watchdog.service 2>/dev/null || true)
    active=$(systemctl is-active vless-watchdog.service 2>/dev/null || true)
  else
    enabled=missing
    active=missing
  fi
  printf '%s\n' "$enabled" >"$dir/watchdog.enabled.before"
  printf '%s\n' "$active" >"$dir/watchdog.active.before"
}

takeover_freeze_watchdog() {
  local dir=$1
  [[ $(<"$dir/watchdog.active.before") == missing ]] && return 0
  systemctl disable --now vless-watchdog.service >/dev/null 2>&1 || return 1
}

takeover_restore_control_plane() {
  local dir=$1 existed enabled active
  existed=$(<"$dir/root.cron.existed")
  if command -v crontab >/dev/null 2>&1; then
    if [[ $existed == yes ]]; then crontab "$dir/root.cron.before"; else crontab -r 2>/dev/null || true; fi
  fi
  enabled=$(<"$dir/watchdog.enabled.before")
  active=$(<"$dir/watchdog.active.before")
  if [[ $enabled == enabled ]]; then systemctl enable vless-watchdog.service >/dev/null 2>&1 || true; fi
  if [[ $active == active ]]; then systemctl start vless-watchdog.service >/dev/null 2>&1 || true; fi
}

takeover_write_manifest() {
  local dir=$1 takeover_id=$2 sources_json instances_json
  sources_json=$(takeover_registered_sources | jq -R . | jq -s .)
  instances_json=$(takeover_adopted_ids | jq -R . | jq -s .)
  jq -n --arg id "$takeover_id" --arg created_at "$(date -Is)" \
    --argjson sources "$sources_json" --argjson instances "$instances_json" \
    '{id:$id,status:"prepared",created_at:$created_at,sources:$sources,instances:$instances,
      mode:"in-place-control-plane",data_plane_rewritten:false}' >"$dir/manifest.json"
  chmod 0600 "$dir/manifest.json"
}

takeover_mark_registries() {
  local dir=$1 takeover_id id
  takeover_id=$(jq -r '.id' "$dir/manifest.json" | tr -d '\r')
  while IFS= read -r id; do
    [[ -n $id ]] || continue
    registry_mark_taken_over "$id" "$takeover_id" || return 1
  done < <(jq -r '.instances[]' "$dir/manifest.json" | tr -d '\r')
}

takeover_set_manifest_active() {
  local dir=$1
  jq '.status="active" | .activated_at=(now|todateiso8601)' "$dir/manifest.json" \
    >"$dir/manifest.json.new" || return 1
  mv -f "$dir/manifest.json.new" "$dir/manifest.json" || return 1
  chmod 0600 "$dir/manifest.json"
}

takeover_restore_registries() {
  local dir=$1
  [[ -d $dir/registry-before ]] || return 1
  cp -a "$dir/registry-before/." "$FRM_REGISTRY_DIR/"
}

takeover_verify_after() {
  local dir=$1 id failed=0
  while IFS= read -r id; do
    [[ -n $id ]] || continue
    doctor_instance "$id" || failed=1
  done < <(jq -r '.instances[]' "$dir/manifest.json" | tr -d '\r')
  (( failed == 0 ))
}

adopt_takeover() {
  local takeover_id dir list archive latest id
  takeover_preflight
  takeover_id="$(date +%Y%m%d-%H%M%S)"
  dir="$FRM_TAKEOVER_DIR/$takeover_id"
  install -d "$dir" "$dir/registry-before"
  chmod 0700 "$dir" "$dir/registry-before"
  cp -a "$FRM_REGISTRY_DIR/." "$dir/registry-before/"
  takeover_save_cron "$dir"
  takeover_save_watchdog "$dir"
  takeover_write_manifest "$dir" "$takeover_id"
  list="$dir/backup-files.txt"
  : >"$list"
  takeover_collect_paths "$list"
  archive="$dir/payload.tar.gz"
  tar -C / -czf "$archive" -T "$list" || die "接管备份创建失败；尚未修改控制面。"
  tar -tzf "$archive" >/dev/null || die "接管备份校验失败；尚未修改控制面。"
  sha256sum "$archive" >"$dir/payload.sha256"
  chmod 0600 "$archive" "$dir/payload.sha256" "$list"
  printf '\n即将执行的变化：\n'
  printf '  - 冻结旧管理脚本的 root cron 自动任务\n'
  printf '  - 停用旧 vless-watchdog（协议服务本身不停止）\n'
  printf '  - 将 %s 个实例标记为 frm-node 原地接管\n' "$(jq '.instances|length' "$dir/manifest.json")"
  printf '  - 不修改端口、密钥、协议配置和数据服务 unit\n'
  printf '备份：%s\n' "$archive"
  confirm "确认在本机完成控制面接管吗" N || { info "已取消；备份保留，未修改控制面。"; return 0; }

  if ! takeover_freeze_cron "$dir" || ! takeover_freeze_watchdog "$dir"; then
    takeover_restore_control_plane "$dir"
    die "冻结旧控制面失败，已自动恢复。"
  fi
  if ! takeover_mark_registries "$dir" || ! takeover_set_manifest_active "$dir"; then
    takeover_restore_registries "$dir" || true
    takeover_restore_control_plane "$dir"
    die "写入接管状态失败，已自动恢复控制面。"
  fi

  if ! takeover_verify_after "$dir"; then
    takeover_restore_registries "$dir" || true
    takeover_restore_control_plane "$dir"
    jq '.status="rolled-back-automatically"' "$dir/manifest.json" >"$dir/manifest.json.new"
    mv -f "$dir/manifest.json.new" "$dir/manifest.json"
    die "接管后健康检查失败，已自动回滚控制面。"
  fi
  latest=$(takeover_latest_link)
  printf '%s\n' "$dir" >"$(takeover_latest_file)"
  chmod 0600 "$(takeover_latest_file)"
  ln -sfn "$dir" "$latest" 2>/dev/null || true
  log_action "takeover activated $takeover_id"
  ok "完整控制面接管成功；数据服务未重启。"
  printf '回滚命令：frm adopt rollback %s\n' "$takeover_id"
}

adopt_takeover_rollback() {
  local requested=${1:-} dir id status
  if [[ -n $requested ]]; then dir="$FRM_TAKEOVER_DIR/$requested"; else dir=$(takeover_latest_dir || true); fi
  [[ -d $dir && -r $dir/manifest.json ]] || die "找不到接管记录：${requested:-latest}"
  id=$(jq -r '.id' "$dir/manifest.json" | tr -d '\r')
  status=$(jq -r '.status' "$dir/manifest.json" | tr -d '\r')
  [[ $status == active ]] || die "接管记录 $id 当前状态为 $status，不能重复回滚。"
  confirm "回滚接管 $id（不会重启协议服务）吗" N || return 0
  takeover_restore_control_plane "$dir"
  takeover_restore_registries "$dir"
  jq '.status="rolled-back" | .rolled_back_at=(now|todateiso8601)' "$dir/manifest.json" >"$dir/manifest.json.new"
  mv -f "$dir/manifest.json.new" "$dir/manifest.json"
  chmod 0600 "$dir/manifest.json"
  log_action "takeover rolled back $id"
  ok "接管已回滚；旧 cron、watchdog 和兼容登记状态已恢复。"
}

adopt_takeover_status() {
  local dir
  dir=$(takeover_latest_dir || true)
  [[ -d $dir && -r $dir/manifest.json ]] || { info "本机尚无完整接管记录。"; return 0; }
  jq -r '"接管编号：\(.id)\n状态：\(.status)\n模式：原地控制面接管\n实例数：\(.instances|length)\n来源：\(.sources|join(", "))\n创建时间：\(.created_at)"' "$dir/manifest.json"
  printf '备份校验：'
  (cd "$dir" && sha256sum -c payload.sha256 >/dev/null 2>&1) && printf '正常\n' || printf '异常\n'
}
