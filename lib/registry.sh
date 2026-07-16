#!/usr/bin/env bash

registry_path() { printf '%s/%s.json\n' "$FRM_REGISTRY_DIR" "$1"; }
credential_path() { printf '%s/%s.env\n' "$FRM_INSTANCE_DIR" "$1"; }
config_path() { printf '%s/%s.conf\n' "$FRM_INSTANCE_DIR" "$1"; }

registry_exists() { [[ -f $(registry_path "$1") ]]; }

registry_write() {
  local id=$1 protocol=$2 name=$3 port=$4 transport=$5 version=$6 credential=$7 config=$8
  shift 8
  local services_json='[]' service
  for service in "$@"; do
    services_json=$(jq -c --arg item "$service" '. + [$item]' <<<"$services_json")
  done
  jq -n \
    --arg id "$id" --arg protocol "$protocol" --arg name "$name" \
    --argjson port "$port" --arg transport "$transport" --arg version "$version" \
    --arg credential_file "$credential" --arg config_file "$config" \
    --arg created_at "$(date -Is)" --argjson services "$services_json" \
    '{id:$id,protocol:$protocol,name:$name,port:$port,transport:$transport,version:$version,credential_file:$credential_file,config_file:$config_file,services:$services,ownership:"frm",source:"frm-node",read_only:false,created_at:$created_at}' \
    >"$(registry_path "$id").new"
  chmod 0600 "$(registry_path "$id").new"
  mv -f "$(registry_path "$id").new" "$(registry_path "$id")"
}

registry_mark_adopted() {
  local id=$1 source=$2 core_group=${3:-} binary_path=${4:-} manager_path=${5:-}
  local file tmp
  file=$(registry_path "$id")
  tmp="$file.new"
  jq --arg source "$source" --arg core_group "$core_group" \
    --arg binary_path "$binary_path" --arg manager_path "$manager_path" \
    '.ownership="adopted" | .source=$source | .read_only=true |
     .core_group=$core_group | .binary_path=$binary_path | .manager_path=$manager_path |
     .adopted_at=(now | todateiso8601)' "$file" >"$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$file"
}

registry_ownership() {
  registry_get "$1" '.ownership // "frm"'
}

registry_is_adopted() {
  [[ $(registry_ownership "$1") == adopted ]]
}

registry_is_external() {
  [[ $(registry_ownership "$1") != frm ]]
}

registry_mark_taken_over() {
  local id=$1 takeover_id=$2 file tmp
  file=$(registry_path "$id")
  tmp="$file.new"
  jq --arg takeover_id "$takeover_id" \
    '.ownership="taken-over" | .read_only=true | .takeover_id=$takeover_id |
     .taken_over_at=(now | todateiso8601)' "$file" >"$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$file"
}

registry_get() {
  local id=$1 filter=$2 file
  file=$(registry_path "$id")
  [[ -r $file ]] || return 1
  jq -r "$filter" "$file"
}

registry_ids() {
  local file
  shopt -s nullglob
  for file in "$FRM_REGISTRY_DIR"/*.json; do
    basename "$file" .json
  done
  shopt -u nullglob
}

registry_remove() {
  rm -f "$(registry_path "$1")"
}

registry_table() {
  local id service state ownership owner_label
  printf '%-24s %-18s %-8s %-6s %-10s %-10s\n' "实例" "协议" "端口" "传输" "状态" "管理模式"
  printf '%-24s %-18s %-8s %-6s %-10s %-10s\n' "------------------------" "------------------" "--------" "------" "----------" "----------"
  while IFS= read -r id; do
    service=$(registry_get "$id" '.services[0]')
    state=$(systemctl is-active "$service" 2>/dev/null || true)
    ownership=$(registry_ownership "$id")
    case $ownership in
      adopted) owner_label="兼容接管" ;;
      taken-over) owner_label="frm 接管" ;;
      *) owner_label="frm 原生" ;;
    esac
    printf '%-24s %-18s %-8s %-6s %-10s %-10s\n' \
      "$id" "$(registry_get "$id" '.protocol')" "$(registry_get "$id" '.port')" \
      "$(registry_get "$id" '.transport')" "${state:-unknown}" "$owner_label"
  done < <(registry_ids)
}
