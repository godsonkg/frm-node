#!/usr/bin/env bash

firewall_open() {
  local port=$1 transport=$2 label=${3:-frm-node}
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "$port/$transport" comment "$label"
    return
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="$port/$transport"
    firewall-cmd --reload
    return
  fi
  warn "未检测到启用中的 UFW/firewalld，请确认厂商防火墙已放行 $port/$transport。"
}

firewall_close() {
  local port=$1 transport=$2
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw --force delete allow "$port/$transport" >/dev/null 2>&1 || true
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --remove-port="$port/$transport" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
}

