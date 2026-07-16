#!/usr/bin/env bash

FRM_ETC=${FRM_ETC:-/etc/frm-node}
FRM_STATE=${FRM_STATE:-/var/lib/frm-node}
FRM_BIN_DIR=${FRM_BIN_DIR:-$FRM_STATE/bin}
FRM_INSTANCE_DIR=${FRM_INSTANCE_DIR:-$FRM_ETC/instances}
FRM_REGISTRY_DIR=${FRM_REGISTRY_DIR:-$FRM_STATE/instances}
FRM_BACKUP_DIR=${FRM_BACKUP_DIR:-$FRM_STATE/backups}
FRM_SYSTEMD_DIR=${FRM_SYSTEMD_DIR:-/etc/systemd/system}
FRM_LOG=${FRM_LOG:-/var/log/frm-node.log}

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
  C_RED='\033[31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_BLUE='\033[34m'; C_RESET='\033[0m'
else
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_RESET=''
fi

info() { printf '%b[信息]%b %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok() { printf '%b[完成]%b %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%b[注意]%b %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die() { printf '%b[错误]%b %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

need_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 运行，或执行 sudo frm $*."
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "缺少必要命令：$1"
}

init_layout() {
  install -d -m 0755 "$FRM_ETC" "$FRM_STATE" "$FRM_BIN_DIR" "$FRM_REGISTRY_DIR" "$FRM_BACKUP_DIR"
  install -d "$FRM_INSTANCE_DIR"
  chmod 0700 "$FRM_INSTANCE_DIR"
  touch "$FRM_LOG"
  chmod 0600 "$FRM_LOG"
}

detect_os() {
  [[ -r /etc/os-release ]] || die "无法识别系统，仅支持 Debian/Ubuntu。"
  # shellcheck disable=SC1091
  source /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) : ;;
    *) die "当前仅支持 Debian/Ubuntu，检测到：${ID:-unknown}" ;;
  esac
  command -v systemctl >/dev/null 2>&1 || die "当前版本要求 systemd。"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'amd64\n' ;;
    aarch64|arm64) printf 'arm64\n' ;;
    armv7l) printf 'armv7l\n' ;;
    i386|i686) printf 'i386\n' ;;
    *) die "暂不支持的 CPU 架构：$(uname -m)" ;;
  esac
}

random_hex() {
  openssl rand -hex "${1:-16}"
}

random_port() {
  local transport=${1:-tcp} port
  for _ in $(seq 1 200); do
    port=$(shuf -i 20000-60000 -n 1)
    if port_available "$transport" "$port"; then
      printf '%s\n' "$port"
      return 0
    fi
  done
  die "无法找到空闲的 ${transport^^} 端口。"
}

port_available() {
  local transport=$1 port=$2 flag=-lnt
  [[ $transport == udp ]] && flag=-lnu
  ! ss -H "$flag" "sport = :$port" 2>/dev/null | grep -q .
}

validate_port() {
  if [[ ! ${1:-} =~ ^[0-9]+$ ]] || (( $1 < 1 || $1 > 65535 )); then
    die "端口无效：${1:-空}"
  fi
}

ask_value() {
  local prompt=$1 default=${2:-} value
  if [[ -n $default ]]; then
    read -r -p "$prompt [$default]: " value
    printf '%s\n' "${value:-$default}"
  else
    read -r -p "$prompt: " value
    [[ -n $value ]] || die "$prompt 不能为空。"
    printf '%s\n' "$value"
  fi
}

confirm() {
  local prompt=$1 default=${2:-N} answer suffix='[y/N]'
  [[ $default == Y ]] && suffix='[Y/n]'
  read -r -p "$prompt $suffix: " answer
  answer=${answer:-$default}
  [[ $answer =~ ^[Yy]$ ]]
}

sanitize_id() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_-]+/-/g; s/^-+|-+$//g'
}

unique_instance_id() {
  local base id index=2
  base=$(sanitize_id "$1")
  id=$base
  while [[ -e $FRM_REGISTRY_DIR/$id.json || -e $FRM_INSTANCE_DIR/$id.env || -e $FRM_INSTANCE_DIR/$id.conf ]]; do
    id="${base}-${index}"
    ((index++))
  done
  printf '%s\n' "$id"
}

public_ipv4() {
  local ip=${FRM_SERVER_IPV4:-}
  if [[ -z $ip ]]; then
    ip=$(curl -4fsSL --max-time 8 https://api.ipify.org 2>/dev/null || true)
  fi
  if [[ -z $ip ]]; then
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
  fi
  [[ -n $ip ]] || die "无法检测公网 IPv4，请设置 FRM_SERVER_IPV4 后重试。"
  printf '%s\n' "$ip"
}

atomic_install_file() {
  local source=$1 target=$2 mode=${3:-0644}
  install -D -m "$mode" "$source" "$target.new"
  mv -f "$target.new" "$target"
}

log_action() {
  printf '%s %s\n' "$(date -Is)" "$*" >>"$FRM_LOG" 2>/dev/null || true
}
