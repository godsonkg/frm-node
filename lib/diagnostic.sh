#!/usr/bin/env bash

doctor_instance() {
  local id=$1 protocol port transport service failed=0 state
  protocol=$(registry_get "$id" '.protocol')
  port=$(registry_get "$id" '.port')
  transport=$(registry_get "$id" '.transport')
  printf '\n[%s] %s\n' "$id" "$protocol"
  if registry_is_adopted "$id"; then
    printf '  [信息] 兼容接管自 %s；原服务和配置保持不变\n' "$(registry_get "$id" '.source')"
  fi
  while IFS= read -r service; do
    state=$(systemctl is-active "$service" 2>/dev/null || true)
    if [[ $state == active ]]; then
      printf '  [正常] 服务 %s 正在运行\n' "$service"
    else
      printf '  [异常] 服务 %s 状态为 %s\n' "$service" "${state:-unknown}"
      failed=1
    fi
  done < <(instance_services "$id")
  if [[ $transport == tcp ]] && ss -H -lnt "sport = :$port" | grep -q .; then
    printf '  [正常] TCP %s 正在监听\n' "$port"
  elif [[ $transport == udp ]] && ss -H -lnu "sport = :$port" | grep -q .; then
    printf '  [正常] UDP %s 正在监听\n' "$port"
  else
    printf '  [异常] %s %s 没有监听\n' "${transport^^}" "$port"
    failed=1
  fi
  [[ $(stat -c '%a' "$(credential_path "$id")" 2>/dev/null || true) == 600 ]] || {
    printf '  [警告] 凭据文件权限不是 600\n'
    failed=1
  }
  return "$failed"
}

doctor_all() {
  local id total=0 failed=0
  printf '=== frm-node 中文诊断 ===\n'
  printf '系统：%s\n' "$(. /etc/os-release; printf '%s %s' "$ID" "$VERSION_ID")"
  printf '架构：%s\n' "$(uname -m)"
  printf '内核：%s\n' "$(uname -r)"
  if sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    printf '[正常] BBR 已启用\n'
  else
    printf '[提示] 当前拥塞控制不是 BBR\n'
  fi
  while IFS= read -r id; do
    ((total+=1))
    doctor_instance "$id" || ((failed+=1))
  done < <(registry_ids)
  printf '\n诊断完成：%d 个实例，%d 个存在异常。\n' "$total" "$failed"
  (( failed == 0 ))
}
