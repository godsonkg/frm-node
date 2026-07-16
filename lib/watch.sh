#!/usr/bin/env bash

# frm watch：零暴露面的 Telegram 推送监控。
# 无监听端口、无常驻进程，由 systemd timer 周期拉起一次巡检后立即退出。
# 消息永不包含密码、PSK、UUID、私钥或订阅地址；默认不包含端口号。

FRM_WATCH_ENV=${FRM_WATCH_ENV:-$FRM_ETC/watch.env}
FRM_WATCH_STATE=${FRM_WATCH_STATE:-$FRM_STATE/watch}

watch_state_init() {
  install -d "$FRM_WATCH_STATE" "$FRM_WATCH_STATE/alerts"
  chmod 0700 "$FRM_WATCH_STATE" "$FRM_WATCH_STATE/alerts"
}

watch_normalize_int() {
  local value=$1 fallback=$2
  if [[ $value =~ ^[0-9]+$ ]]; then
    printf '%d\n' "$((10#$value))"
  else
    printf '%d\n' "$fallback"
  fi
}

watch_load_config() {
  [[ -r $FRM_WATCH_ENV ]] || die "尚未配置推送监控，请先执行：frm watch setup"
  # shellcheck disable=SC1090
  source "$FRM_WATCH_ENV"
  [[ -n ${WATCH_TG_TOKEN:-} && -n ${WATCH_TG_CHAT_ID:-} ]] || \
    die "watch.env 缺少 WATCH_TG_TOKEN 或 WATCH_TG_CHAT_ID。"
  WATCH_NODE_NAME=${WATCH_NODE_NAME:-$(hostname)}
  WATCH_DISK_WARN=$(watch_normalize_int "${WATCH_DISK_WARN:-}" 85)
  WATCH_DISK_CRIT=$(watch_normalize_int "${WATCH_DISK_CRIT:-}" 95)
  WATCH_DAILY_HOUR=$(watch_normalize_int "${WATCH_DAILY_HOUR:-}" 9)
  WATCH_INTERVAL_MIN=$(watch_normalize_int "${WATCH_INTERVAL_MIN:-}" 5)
  WATCH_REPEAT_SECS=$(watch_normalize_int "${WATCH_REPEAT_SECS:-}" 21600)
  WATCH_TRAFFIC_QUOTA_GB=${WATCH_TRAFFIC_QUOTA_GB:-}
  WATCH_SHOW_PORTS=${WATCH_SHOW_PORTS:-0}
  WATCH_SSH_KNOWN_IPS=${WATCH_SSH_KNOWN_IPS:-}
}

watch_api() {
  local method=$1
  shift
  curl -fsS --max-time 15 --retry 2 \
    "https://api.telegram.org/bot${WATCH_TG_TOKEN}/${method}" "$@"
}

watch_send() {
  local text=$1
  if ! watch_api sendMessage --data-urlencode "chat_id=${WATCH_TG_CHAT_ID}" \
      --data-urlencode "text=【${WATCH_NODE_NAME}】${text}" >/dev/null; then
    log_action "watch send failed"
    return 1
  fi
}

# 同一问题在 WATCH_REPEAT_SECS 内只推一次；发送失败不落时间戳，下轮重试。
watch_alert() {
  local key=$1 text=$2 stamp now last
  stamp="$FRM_WATCH_STATE/alerts/$key"
  now=$(date +%s)
  last=$(cat "$stamp" 2>/dev/null || printf '0')
  [[ $last =~ ^[0-9]+$ ]] || last=0
  if (( now - last >= WATCH_REPEAT_SECS )); then
    watch_send "$text" && printf '%s\n' "$now" >"$stamp"
  fi
  return 0
}

watch_resolve() {
  local key=$1 text=$2 stamp
  stamp="$FRM_WATCH_STATE/alerts/$key"
  [[ -f $stamp ]] || return 0
  rm -f "$stamp"
  watch_send "$text" || true
  return 0
}

# ---------- 检查项 ----------

watch_instance_ok() {
  local id=$1 service port transport
  while IFS= read -r service; do
    systemctl is-active --quiet "$service" || return 1
  done < <(instance_services "$id")
  port=$(registry_get "$id" '.port')
  transport=$(registry_get "$id" '.transport')
  if [[ $transport == udp ]]; then
    ss -H -lnu "sport = :$port" | grep -q .
  else
    ss -H -lnt "sport = :$port" | grep -q .
  fi
}

watch_check_instances() {
  local id protocol label
  while IFS= read -r id; do
    [[ -n $id ]] || continue
    protocol=$(registry_get "$id" '.protocol')
    label="$id（$protocol）"
    [[ $WATCH_SHOW_PORTS != 1 ]] || label="$label 端口 $(registry_get "$id" '.port')"
    if watch_instance_ok "$id"; then
      watch_resolve "inst-$id" "✅ 实例已恢复：$label"
    else
      watch_alert "inst-$id" "🚨 实例异常：$label 服务或端口未正常监听，请上机执行 frm doctor。"
    fi
  done < <(registry_ids)
  return 0
}

watch_disk_used_pct() {
  df -P / 2>/dev/null | awk 'NR==2 {gsub(/%/,""); print $5}'
}

watch_check_disk() {
  local pct
  pct=$(watch_disk_used_pct)
  [[ $pct =~ ^[0-9]+$ ]] || return 0
  if (( pct >= WATCH_DISK_CRIT )); then
    watch_alert disk-crit "🆘 磁盘严重不足：已用 ${pct}%（阈值 ${WATCH_DISK_CRIT}%），请尽快清理。"
  elif (( pct >= WATCH_DISK_WARN )); then
    watch_alert disk-warn "⚠️ 磁盘偏高：已用 ${pct}%（阈值 ${WATCH_DISK_WARN}%）。"
  else
    if [[ -f $FRM_WATCH_STATE/alerts/disk-crit || -f $FRM_WATCH_STATE/alerts/disk-warn ]]; then
      rm -f "$FRM_WATCH_STATE/alerts/disk-crit" "$FRM_WATCH_STATE/alerts/disk-warn"
      watch_send "✅ 磁盘占用已回落到 ${pct}%。" || true
    fi
  fi
  return 0
}

watch_check_traffic() {
  [[ -n $WATCH_TRAFFIC_QUOTA_GB ]] || return 0
  [[ $WATCH_TRAFFIC_QUOTA_GB =~ ^[0-9]+$ && $WATCH_TRAFFIC_QUOTA_GB -gt 0 ]] || return 0
  command -v vnstat >/dev/null 2>&1 || return 0
  local bytes quota pct month level stamp
  bytes=$({ vnstat --oneline b 2>/dev/null || true; } | awk -F';' 'NR==1 {print $11}')
  [[ $bytes =~ ^[0-9]+$ ]] || return 0
  quota=$(( WATCH_TRAFFIC_QUOTA_GB * 1024 * 1024 * 1024 ))
  pct=$(( bytes * 100 / quota ))
  printf '%s\n' "$pct" >"$FRM_WATCH_STATE/traffic.pct"
  month=$(date +%Y%m)
  for level in 95 80; do
    stamp="$FRM_WATCH_STATE/traffic-$month-$level"
    if (( pct >= level )) && [[ ! -f $stamp ]]; then
      watch_send "📈 本月流量已用 ${pct}%（配额 ${WATCH_TRAFFIC_QUOTA_GB}G），请留意商家计费规则。" && touch "$stamp"
      break
    fi
  done
  return 0
}

watch_check_ssh() {
  local since_file="$FRM_WATCH_STATE/ssh.since" now since lines line user ip when
  now=$(date +%s)
  # 首轮只落游标不告警，避免把历史登录一次性推爆。
  if [[ ! -f $since_file ]]; then
    printf '%s\n' "$now" >"$since_file"
    chmod 0600 "$since_file"
    return 0
  fi
  since=$(<"$since_file")
  [[ $since =~ ^[0-9]+$ ]] || since=$now
  lines=$(journalctl --since "@$since" --no-pager -q -o short-iso 2>/dev/null |
    grep -E 'sshd(\[[0-9]+\])?: Accepted ' || true)
  printf '%s\n' "$now" >"$since_file"
  [[ -n $lines ]] || return 0
  local todaylog msg='' skip
  todaylog="$FRM_WATCH_STATE/ssh-$(date +%F).log"
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    user=$(sed -nE 's/.*Accepted [a-z0-9-]+ for ([^ ]+) from .*/\1/p' <<<"$line")
    ip=$(sed -nE 's/.*from ([0-9a-fA-F:.]+) port.*/\1/p' <<<"$line")
    when=$(awk '{print $1}' <<<"$line")
    printf '%s %s %s\n' "$when" "${user:-?}" "${ip:-?}" >>"$todaylog"
    skip=0
    if [[ -n $WATCH_SSH_KNOWN_IPS && -n $ip ]]; then
      [[ ",$WATCH_SSH_KNOWN_IPS," == *",$ip,"* ]] && skip=1
    fi
    (( skip )) || msg+=$'\n'"- $when ${user:-?} 来自 ${ip:-?}"
  done <<<"$lines"
  chmod 0600 "$todaylog" 2>/dev/null || true
  [[ -z $msg ]] || watch_send "🔐 SSH 登录成功：$msg"
  return 0
}

watch_ports_snapshot() {
  ss -H -lntu 2>/dev/null |
    awk '{n=split($5,a,":"); if (a[n] ~ /^[0-9]+$/) print tolower($1)"/"a[n]}' |
    sort -u
}

watch_check_ports() {
  local baseline="$FRM_WATCH_STATE/ports.baseline" current allowed new_ports id
  current=$(watch_ports_snapshot)
  if [[ ! -f $baseline ]]; then
    printf '%s\n' "$current" >"$baseline"
    chmod 0600 "$baseline"
    return 0
  fi
  # 注册表内实例的端口视为合法，新装 frm 节点不误报。
  allowed=$(
    cat "$baseline"
    while IFS= read -r id; do
      [[ -n $id ]] || continue
      printf 'tcp/%s\nudp/%s\n' "$(registry_get "$id" '.port')" "$(registry_get "$id" '.port')"
    done < <(registry_ids)
  )
  new_ports=$(comm -23 <(printf '%s\n' "$current" | sort -u) <(printf '%s\n' "$allowed" | sort -u))
  if [[ -n $new_ports ]]; then
    watch_alert ports "🚨 发现基线外的新监听端口：
$new_ports
如果是你自己安装的服务，请运行 frm watch accept-ports 更新基线；否则请立即排查是否被植入后门。"
  else
    watch_resolve ports "✅ 监听端口已回到基线范围。"
  fi
  return 0
}

watch_cron_hash() {
  { crontab -l 2>/dev/null || true; } | sha256sum | awk '{print $1}'
}

watch_check_cron() {
  local baseline="$FRM_WATCH_STATE/cron.sha256" current
  current=$(watch_cron_hash)
  if [[ ! -f $baseline ]]; then
    printf '%s\n' "$current" >"$baseline"
    chmod 0600 "$baseline"
    return 0
  fi
  if [[ $current != "$(<"$baseline")" ]]; then
    watch_alert cron "🚨 root crontab 发生变化。如果是你自己改的，请运行 frm watch accept-cron 更新基线；否则请立即排查是否被植入持久化任务。"
  else
    watch_resolve cron "✅ root crontab 已恢复与基线一致。"
  fi
  return 0
}

watch_daily_summary() {
  local today hour stampfile total=0 failed=0 id disk mem load traffic='' ssh_today=0
  local latest backup_line
  today=$(date +%F)
  hour=$(watch_normalize_int "$(date +%H)" 0)
  stampfile="$FRM_WATCH_STATE/daily.last"
  (( hour >= WATCH_DAILY_HOUR )) || return 0
  [[ $(cat "$stampfile" 2>/dev/null || true) != "$today" ]] || return 0
  while IFS= read -r id; do
    [[ -n $id ]] || continue
    ((total+=1))
    watch_instance_ok "$id" || ((failed+=1))
  done < <(registry_ids)
  disk=$(watch_disk_used_pct)
  mem=$({ free -m 2>/dev/null || true; } | awk 'NR==2 && $2>0 {printf "%d", $3*100/$2}')
  load=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || true)
  [[ ! -f $FRM_WATCH_STATE/traffic.pct ]] || traffic="，本月流量已用 $(<"$FRM_WATCH_STATE/traffic.pct")%"
  if [[ -f "$FRM_WATCH_STATE/ssh-$today.log" ]]; then
    ssh_today=$(wc -l <"$FRM_WATCH_STATE/ssh-$today.log")
  fi
  latest=$(find "$FRM_BACKUP_DIR" -maxdepth 1 -type f -name 'frm-node-*.tar.gz' 2>/dev/null | sort | tail -n 1)
  if [[ -n $latest ]]; then
    backup_line="最近备份：$(( ( $(date +%s) - $(stat -c %Y "$latest") ) / 86400 )) 天前"
  else
    backup_line="最近备份：无"
  fi
  watch_send "📊 每日巡检 $today
实例：$total 个，异常 $failed 个
磁盘：${disk:-?}%，内存：${mem:-?}%，负载：${load:-?}$traffic
今日 SSH 登录：$ssh_today 次
$backup_line" && printf '%s\n' "$today" >"$stampfile"
  # 清理 3 天前的登录日志。
  find "$FRM_WATCH_STATE" -maxdepth 1 -type f -name 'ssh-*.log' -mtime +3 -delete 2>/dev/null || true
  return 0
}

# ---------- systemd 单元 ----------

watch_install_units() {
  local tmp home=${FRM_HOME:-/opt/frm-node}
  tmp=$(mktemp)
  cat >"$tmp" <<EOF
[Unit]
Description=frm-node watch 巡检

[Service]
Type=oneshot
ExecStart=$home/frm-node watch run
NoNewPrivileges=true
PrivateTmp=true
EOF
  atomic_install_file "$tmp" "$FRM_SYSTEMD_DIR/frm-watch.service" 0644
  cat >"$tmp" <<EOF
[Unit]
Description=frm-node watch 定时器

[Timer]
OnBootSec=3min
OnUnitActiveSec=${WATCH_INTERVAL_MIN}min
RandomizedDelaySec=30

[Install]
WantedBy=timers.target
EOF
  atomic_install_file "$tmp" "$FRM_SYSTEMD_DIR/frm-watch.timer" 0644
  rm -f "$tmp"
  systemctl daemon-reload
  systemctl enable --now frm-watch.timer
}

# ---------- 子命令 ----------

watch_setup() {
  require_command curl
  require_command jq
  local token chat_id detected username name quota hour tmp
  info "开始配置 Telegram 推送监控。Token 只写入本机 0600 文件，不要粘贴到聊天或截图。"
  token=$(ask_value "Bot Token")
  WATCH_TG_TOKEN=$token
  username=$(watch_api getMe 2>/dev/null | jq -r '.result.username // empty' || true)
  [[ -n $username ]] || die "Token 校验失败：无法访问 Telegram Bot API 或 Token 无效。"
  ok "Token 有效，Bot：@$username"
  detected=$(watch_api getUpdates 2>/dev/null |
    jq -r '[.result[] | .message.chat.id?] | map(select(. != null)) | last // empty' || true)
  if [[ -n $detected ]]; then
    info "检测到最近与 Bot 对话的 chat_id：$detected"
    chat_id=$(ask_value "chat_id" "$detected")
  else
    warn "没有检测到对话记录。请先在 Telegram 给 @$username 发一条消息，然后重跑 setup，或手动填入 chat_id。"
    chat_id=$(ask_value "chat_id")
  fi
  name=$(ask_value "本机显示名称" "$(hostname)")
  quota=$(ask_value "月流量配额 GB（0 表示不监控流量）" "0")
  [[ $quota != 0 ]] || quota=''
  hour=$(ask_value "每日汇总时刻（本机时区 0-23 点）" "9")

  tmp=$(mktemp)
  {
    printf 'WATCH_TG_TOKEN=%q\n' "$token"
    printf 'WATCH_TG_CHAT_ID=%q\n' "$chat_id"
    printf 'WATCH_NODE_NAME=%q\n' "$name"
    printf 'WATCH_TRAFFIC_QUOTA_GB=%q\n' "$quota"
    printf 'WATCH_DAILY_HOUR=%q\n' "$hour"
    printf 'WATCH_DISK_WARN=85\n'
    printf 'WATCH_DISK_CRIT=95\n'
    printf 'WATCH_SHOW_PORTS=0\n'
    printf 'WATCH_INTERVAL_MIN=5\n'
    printf 'WATCH_REPEAT_SECS=21600\n'
    printf 'WATCH_SSH_KNOWN_IPS=\n'
  } >"$tmp"
  atomic_install_file "$tmp" "$FRM_WATCH_ENV" 0600
  rm -f "$tmp"

  watch_load_config
  watch_state_init
  watch_ports_snapshot >"$FRM_WATCH_STATE/ports.baseline"
  watch_cron_hash >"$FRM_WATCH_STATE/cron.sha256"
  date +%s >"$FRM_WATCH_STATE/ssh.since"
  chmod 0600 "$FRM_WATCH_STATE/ports.baseline" "$FRM_WATCH_STATE/cron.sha256" "$FRM_WATCH_STATE/ssh.since"
  watch_send "✅ 推送监控配置完成，每 ${WATCH_INTERVAL_MIN} 分钟巡检一次；异常即时推送，每天 ${WATCH_DAILY_HOUR} 点发日报。" || \
    die "测试消息发送失败，请检查 chat_id（先给 Bot 发一条消息再重试）。"
  watch_install_units
  ok "frm watch 已启用。端口与 crontab 基线已按当前状态记录。"
}

watch_run() {
  watch_load_config
  watch_state_init
  watch_check_instances || log_action "watch instances check error"
  watch_check_disk || log_action "watch disk check error"
  watch_check_traffic || log_action "watch traffic check error"
  watch_check_ssh || log_action "watch ssh check error"
  watch_check_ports || log_action "watch ports check error"
  watch_check_cron || log_action "watch cron check error"
  watch_daily_summary || log_action "watch summary error"
  date +%s >"$FRM_WATCH_STATE/run.last"
}

watch_status() {
  if [[ ! -r $FRM_WATCH_ENV ]]; then
    info "尚未配置推送监控。运行 frm watch setup 开始。"
    return 0
  fi
  watch_load_config
  printf '机器名称：%s\n' "$WATCH_NODE_NAME"
  printf 'Bot Token：%s…（已打码）\n' "${WATCH_TG_TOKEN:0:8}"
  printf 'chat_id：%s\n' "$WATCH_TG_CHAT_ID"
  printf '巡检间隔：%s 分钟；日报时刻：%s 点\n' "$WATCH_INTERVAL_MIN" "$WATCH_DAILY_HOUR"
  printf '磁盘阈值：%s%%/%s%%；流量配额：%sG\n' "$WATCH_DISK_WARN" "$WATCH_DISK_CRIT" "${WATCH_TRAFFIC_QUOTA_GB:-未设置}"
  printf '定时器：%s / %s\n' \
    "$(systemctl is-enabled frm-watch.timer 2>/dev/null || printf '未安装')" \
    "$(systemctl is-active frm-watch.timer 2>/dev/null || printf '未运行')"
  if [[ -f $FRM_WATCH_STATE/run.last ]]; then
    printf '上次巡检：%s\n' "$(date -d "@$(<"$FRM_WATCH_STATE/run.last")" '+%F %T' 2>/dev/null || printf '未知')"
  else
    printf '上次巡检：尚未运行\n'
  fi
}

watch_accept_ports() {
  watch_state_init
  watch_ports_snapshot >"$FRM_WATCH_STATE/ports.baseline"
  chmod 0600 "$FRM_WATCH_STATE/ports.baseline"
  rm -f "$FRM_WATCH_STATE/alerts/ports"
  ok "已把当前监听端口设为新基线。"
}

watch_accept_cron() {
  watch_state_init
  watch_cron_hash >"$FRM_WATCH_STATE/cron.sha256"
  chmod 0600 "$FRM_WATCH_STATE/cron.sha256"
  rm -f "$FRM_WATCH_STATE/alerts/cron"
  ok "已把当前 root crontab 设为新基线。"
}

watch_command() {
  case ${1:-status} in
    setup) watch_setup ;;
    run) watch_run ;;
    test)
      watch_load_config
      if watch_send "📨 测试消息：推送链路正常。"; then
        ok "已发送，请查看 Telegram。"
      else
        die "测试消息发送失败，请检查网络、Token 与 chat_id。"
      fi
      ;;
    status) watch_status ;;
    accept-ports) watch_accept_ports ;;
    accept-cron) watch_accept_cron ;;
    off)
      systemctl disable --now frm-watch.timer 2>/dev/null || true
      ok "已停用定时巡检（配置与基线保留，frm watch on 可恢复）。"
      ;;
    on)
      [[ -f $FRM_SYSTEMD_DIR/frm-watch.timer ]] || die "尚未安装定时器，请先执行 frm watch setup。"
      systemctl enable --now frm-watch.timer
      ok "已启用定时巡检。"
      ;;
    *) die "未知 watch 命令：$1。可用：setup、run、test、status、accept-ports、accept-cron、off、on。" ;;
  esac
}
