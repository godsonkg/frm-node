#!/usr/bin/env bash

sub_format_valid() {
  [[ $1 == surge || $1 == loon || $1 == mihomo ]]
}

sub_validate_name() {
  local name=$1
  [[ -n $name ]] || die "订阅节点名称不能为空。"
  [[ $name != *$'\n'* && $name != *$'\r'* && $name != *'='* && $name != *'"'* && $name != *$'\\'* ]] ||
    die "订阅节点名称不能包含换行、等号、双引号或反斜杠：$name"
}

sub_protocol_suffix() {
  case $1 in
    anytls) printf 'AnyTLS\n' ;;
    hysteria2) printf 'Hysteria2\n' ;;
    reality) printf 'Reality\n' ;;
    tuic) printf 'TUIC\n' ;;
    trojan) printf 'Trojan\n' ;;
    snell4) printf 'Snell-v4\n' ;;
    snell5) printf 'Snell-v5\n' ;;
    snell6) printf 'Snell-v6\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

sub_default_prefix() {
  if [[ -n ${FRM_SUB_PREFIX:-} ]]; then
    printf '%s\n' "$FRM_SUB_PREFIX"
  else
    hostname -s
  fi
}

sub_fragment_render() {
  local format=$1 prefix=$2 only_id=${3:-} exact_name=${4:-}
  local id protocol name port rc output rendered=0 skipped=0
  local -A names=()
  sub_format_valid "$format" || die "未知订阅格式：$format"
  sub_validate_name "$prefix"
  if [[ -n $exact_name ]]; then
    [[ -n $only_id ]] || die "--name 必须与 --instance 一起使用。"
    sub_validate_name "$exact_name"
  fi
  [[ -z $only_id ]] || registry_exists "$only_id" || die "实例不存在：$only_id"

  [[ $format != mihomo ]] || printf 'proxies:\n'
  while IFS= read -r id; do
    [[ -z $only_id || $id == "$only_id" ]] || continue
    protocol=$(registry_get "$id" '.protocol')
    if [[ -n $exact_name ]]; then
      name=$exact_name
    else
      name="$prefix-$(sub_protocol_suffix "$protocol")"
      if [[ -n ${names[$name]:-} ]]; then
        port=$(registry_get "$id" '.port')
        name="$name-$port"
      fi
    fi
    sub_validate_name "$name"
    if output=$(render_instance_format "$format" "$id" "$name"); then
      if [[ $format == mihomo ]]; then
        while IFS= read -r line; do printf '  %s\n' "$line"; done <<<"$output"
      else
        printf '%s\n' "$output"
      fi
      names[$name]=1
      ((rendered+=1))
    else
      rc=$?
      (( rc == 2 )) || return "$rc"
      ((skipped+=1))
    fi
  done < <(registry_ids)

  if [[ $format == mihomo && $rendered -eq 0 ]]; then
    printf '  []\n'
  fi
  if (( skipped > 0 )); then
    warn "$format 跳过 $skipped 个客户端不支持或暂无纯格式导出的实例。" >&2
  fi
  (( rendered > 0 )) || warn "$format 没有可导出的实例。" >&2
}

sub_fragment_write_all() {
  local prefix=$1 format tmp target
  umask 077
  install -d "$FRM_SUB_DIR"
  chmod 0700 "$FRM_SUB_DIR"
  for format in surge loon mihomo; do
    case $format in
      surge|loon) target="$FRM_SUB_DIR/$format.list" ;;
      mihomo) target="$FRM_SUB_DIR/mihomo.yaml" ;;
    esac
    tmp="$target.new"
    sub_fragment_render "$format" "$prefix" >"$tmp"
    chmod 0600 "$tmp"
    mv -f "$tmp" "$target"
  done
  ok "订阅片段已生成：$FRM_SUB_DIR"
  printf '  Surge: %s\n  Loon: %s\n  Mihomo: %s\n' \
    "$FRM_SUB_DIR/surge.list" "$FRM_SUB_DIR/loon.list" "$FRM_SUB_DIR/mihomo.yaml"
}

sub_fragment_command() {
  local format='' prefix='' only_id='' exact_name='' stdout=0
  shift
  while (( $# > 0 )); do
    case $1 in
      --format) [[ $# -ge 2 ]] || die "--format 缺少参数。"; format=$2; shift 2 ;;
      --prefix) [[ $# -ge 2 ]] || die "--prefix 缺少参数。"; prefix=$2; shift 2 ;;
      --instance) [[ $# -ge 2 ]] || die "--instance 缺少参数。"; only_id=$2; shift 2 ;;
      --name) [[ $# -ge 2 ]] || die "--name 缺少参数。"; exact_name=$2; shift 2 ;;
      --stdout) stdout=1; shift ;;
      *) die "未知 fragment 参数：$1" ;;
    esac
  done
  prefix=${prefix:-$(sub_default_prefix)}
  if (( stdout )); then
    [[ -n $format ]] || die "--stdout 必须同时指定 --format surge、loon 或 mihomo。"
    sub_fragment_render "$format" "$prefix" "$only_id" "$exact_name"
  elif [[ -n $format || -n $only_id || -n $exact_name ]]; then
    die "写入本机片段时不接受 --format、--instance 或 --name；请使用 --stdout。"
  else
    sub_fragment_write_all "$prefix"
  fi
}

sub_status() {
  local file
  printf '订阅片段目录：%s\n' "$FRM_SUB_DIR"
  for file in "$FRM_SUB_DIR/surge.list" "$FRM_SUB_DIR/loon.list" "$FRM_SUB_DIR/mihomo.yaml"; do
    if [[ -r $file ]]; then
      printf '  [存在] %s（%s 字节）\n' "$file" "$(wc -c <"$file")"
    else
      printf '  [未生成] %s\n' "$file"
    fi
  done
}

sub_command() {
  case ${1:-status} in
    fragment) sub_fragment_command "$@" ;;
    status) sub_status ;;
    *) die "未知订阅命令：${1:-}。可用：fragment、status。" ;;
  esac
}
