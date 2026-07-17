#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
frm-node 本地订阅汇总器（Git Bash / Linux）

用法：
  tools/frm-sub-collect.sh --inventory hosts.tsv [--aliases aliases.tsv] [--output 目录]

hosts.tsv 每行：SSH目标<TAB>节点名前缀
aliases.tsv 每行：SSH目标<TAB>实例ID<TAB>Surge名<TAB>Loon名<TAB>Mihomo名
不支持的客户端用 -。提供某台主机的 aliases 行后，该主机只导出列出的实例。
EOF
}

inventory=''
aliases=''
output_root='./frm-sub-output'
ssh_bin=${FRM_SUB_SSH_BIN:-ssh}

while (( $# > 0 )); do
  case $1 in
    --inventory) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; inventory=$2; shift 2 ;;
    --aliases) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; aliases=$2; shift 2 ;;
    --output) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; output_root=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf '未知参数：%s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -r $inventory ]] || { printf '无法读取主机清单：%s\n' "$inventory" >&2; exit 1; }
[[ -z $aliases || -r $aliases ]] || { printf '无法读取别名清单：%s\n' "$aliases" >&2; exit 1; }
command -v "$ssh_bin" >/dev/null 2>&1 || { printf '找不到 SSH 命令：%s\n' "$ssh_bin" >&2; exit 1; }

validate_ssh_target() {
  [[ $1 =~ ^[A-Za-z0-9_.@:-]+$ ]] || { printf 'SSH 目标包含不安全字符：%s\n' "$1" >&2; exit 1; }
}

validate_text() {
  local label=$1 value=$2
  [[ -n $value && $value != *$'\n'* && $value != *$'\r'* && $value != *"'"* ]] || {
    printf '%s 不能为空或包含换行/单引号。\n' "$label" >&2
    exit 1
  }
}

shell_quote() {
  validate_text "远程参数" "$1"
  printf "'%s'" "$1"
}

host_has_aliases() {
  local target=$1
  [[ -n $aliases ]] || return 1
  awk -F '\t' -v target="$target" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    { sub(/\r$/, "", $1); if ($1 == target) { found=1; exit } }
    END { exit(found ? 0 : 1) }
  ' "$aliases"
}

invoke_remote() {
  local target=$1 format=$2 prefix=$3 instance=${4:-} exact_name=${5:-} command
  command="frm sub fragment --format $format --prefix $(shell_quote "$prefix") --stdout"
  if [[ -n $instance ]]; then
    [[ $instance =~ ^[A-Za-z0-9_.:-]+$ ]] || { printf '实例 ID 包含不安全字符。\n' >&2; return 1; }
    command+=" --instance $instance --name $(shell_quote "$exact_name")"
  fi
  "$ssh_bin" "$target" "$command"
}

append_fragment() {
  local format=$1 source=$2 destination=$3
  if [[ $format == mihomo ]]; then
    awk 'NR == 1 && /^proxies:[[:space:]]*$/ { next } { sub(/\r$/, ""); print }' "$source" >>"$destination"
  else
    awk '{ sub(/\r$/, ""); print }' "$source" >>"$destination"
  fi
}

alias_name_for_format() {
  local format=$1 surge=$2 loon=$3 mihomo=$4
  case $format in
    surge) printf '%s\n' "$surge" ;;
    loon) printf '%s\n' "$loon" ;;
    mihomo) printf '%s\n' "$mihomo" ;;
  esac
}

mkdir -p "$output_root"
build=$(mktemp -d "$output_root/.building.XXXXXX")
cleanup() { rm -rf "$build"; }
trap cleanup EXIT
chmod 0700 "$build" 2>/dev/null || true
mkdir -p "$build/providers" "$build/snippets" "$build/parts"
chmod 0700 "$build/providers" "$build/snippets" "$build/parts" 2>/dev/null || true

host_count=0
for format in surge loon mihomo; do
  merged="$build/parts/$format"
  : >"$merged"
  while IFS=$'\t' read -r target prefix extra; do
    target=${target%$'\r'}
    prefix=${prefix%$'\r'}
    [[ -n $target && $target != \#* ]] || continue
    [[ -z ${extra:-} ]] || { printf 'hosts.tsv 字段过多：%s\n' "$target" >&2; exit 1; }
    validate_ssh_target "$target"
    validate_text "节点名前缀" "$prefix"
    ((host_count+=1))
    if host_has_aliases "$target"; then
      while IFS=$'\t' read -r alias_target instance surge_name loon_name mihomo_name alias_extra; do
        alias_target=${alias_target%$'\r'}
        mihomo_name=${mihomo_name%$'\r'}
        [[ -n $alias_target && $alias_target != \#* && $alias_target == "$target" ]] || continue
        [[ -z ${alias_extra:-} ]] || { printf 'aliases.tsv 字段过多：%s\n' "$instance" >&2; exit 1; }
        name=$(alias_name_for_format "$format" "$surge_name" "$loon_name" "$mihomo_name")
        [[ -n $name && $name != - ]] || continue
        part="$build/parts/${format}-${target//[^A-Za-z0-9_.-]/_}-${instance}.part"
        invoke_remote "$target" "$format" "$prefix" "$instance" "$name" >"$part"
        append_fragment "$format" "$part" "$merged"
      done <"$aliases"
    else
      part="$build/parts/${format}-${target//[^A-Za-z0-9_.-]/_}.part"
      invoke_remote "$target" "$format" "$prefix" >"$part"
      append_fragment "$format" "$part" "$merged"
    fi
  done <"$inventory"
done

(( host_count > 0 )) || { printf '主机清单为空。\n' >&2; exit 1; }

check_duplicates() {
  local format=$1 file=$2 names duplicates
  names="$build/parts/$format.names"
  case $format in
    surge|loon) sed -nE 's/^[[:space:]]*([^=]+)[[:space:]]*=.*/\1/p' "$file" ;;
    mihomo) sed -nE 's/^[[:space:]]*-[[:space:]]+name:[[:space:]]*"([^"]+)".*/\1/p' "$file" ;;
  esac | sed -E 's/[[:space:]]+$//' >"$names"
  duplicates=$(sort "$names" | uniq -d)
  [[ -z $duplicates ]] || {
    printf '%s 出现重复节点名，请修正前缀或别名：\n%s\n' "$format" "$duplicates" >&2
    exit 1
  }
}

check_duplicates surge "$build/parts/surge"
check_duplicates loon "$build/parts/loon"
check_duplicates mihomo "$build/parts/mihomo"

cp "$build/parts/surge" "$build/providers/surge.list"
cp "$build/parts/loon" "$build/providers/loon.list"
{ printf 'proxies:\n'; cat "$build/parts/mihomo"; } >"$build/providers/mihomo.yaml"
{ printf '[Proxy]\n'; cat "$build/parts/surge"; } >"$build/snippets/surge-proxy.conf"
{ printf '[Proxy]\n'; cat "$build/parts/loon"; } >"$build/snippets/loon-proxy.conf"
cp "$build/providers/mihomo.yaml" "$build/snippets/mihomo-proxies.yaml"

find "$build/providers" "$build/snippets" -type f -exec chmod 0600 {} + 2>/dev/null || true
rm -rf "$build/parts"
run_id=$(date +%Y%m%d-%H%M%S)
final="$output_root/$run_id"
counter=0
while [[ -e $final ]]; do ((counter+=1)); final="$output_root/$run_id-$counter"; done
mv "$build" "$final"
trap - EXIT
printf '%s\n' "$final" >"$output_root/latest.txt"
chmod 0600 "$output_root/latest.txt" 2>/dev/null || true

printf '[完成] 已生成订阅汇总，不包含规则和策略组改写。\n'
printf '输出目录：%s\n' "$final"
printf '  纯订阅：providers/surge.list、loon.list、mihomo.yaml\n'
printf '  嵌入片段：snippets/surge-proxy.conf、loon-proxy.conf、mihomo-proxies.yaml\n'
