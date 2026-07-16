#!/usr/bin/env bash

service_unit_path() { printf '%s/%s\n' "$FRM_SYSTEMD_DIR" "$1"; }

write_service_unit() {
  local service=$1 description=$2 exec_start=$3 environment_file=${4:-} read_paths=${5:-}
  local unit tmp
  unit=$(service_unit_path "$service")
  tmp=$(mktemp)
  {
    printf '[Unit]\nDescription=%s\nAfter=network-online.target\nWants=network-online.target\n\n' "$description"
    printf '[Service]\nType=simple\n'
    [[ -n $environment_file ]] && printf 'EnvironmentFile=%s\n' "$environment_file"
    printf 'ExecStart=%s\nRestart=on-failure\nRestartSec=3\nLimitNOFILE=1048576\n' "$exec_start"
    printf 'NoNewPrivileges=true\nPrivateTmp=true\nProtectHome=true\nProtectSystem=strict\n'
    [[ -n $read_paths ]] && printf 'ReadOnlyPaths=%s\n' "$read_paths"
    printf '\n[Install]\nWantedBy=multi-user.target\n'
  } >"$tmp"
  atomic_install_file "$tmp" "$unit" 0644
  rm -f "$tmp"
}

enable_service_checked() {
  local service=$1 transport=$2 port=$3
  systemctl daemon-reload
  systemctl enable --now "$service"
  sleep 1
  if ! systemctl is-active --quiet "$service"; then
    journalctl -u "$service" --no-pager -n 30 >&2 || true
    return 1
  fi
  if [[ $transport == tcp ]]; then
    ss -H -lnt "sport = :$port" | grep -q .
  else
    ss -H -lnu "sport = :$port" | grep -q .
  fi
}

remove_service() {
  local service=$1
  systemctl disable --now "$service" 2>/dev/null || true
  rm -f "$(service_unit_path "$service")"
  systemctl daemon-reload
}

instance_services() {
  registry_get "$1" '.services[]'
}

instance_service_action() {
  local id=$1 action=$2 service
  registry_exists "$id" || die "实例不存在：$id"
  while IFS= read -r service; do
    systemctl "$action" "$service"
  done < <(instance_services "$id")
}

