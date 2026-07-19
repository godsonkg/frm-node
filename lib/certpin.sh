#!/usr/bin/env bash

# frm cert：为使用长期固定自签证书的实例补录 SHA-256 指纹。
# 纯 IP 节点签不了受信证书，客户端只能 skip-cert-verify；补录指纹后，
# 支持钉扎的客户端可凭指纹识别服务端，在不做 CA 链验证的前提下抵御中间人。
#
# 本模块只写实例凭据文件（0600），绝不改动节点配置、证书文件或服务状态。

# 有效期短于该天数的证书视为临时证书，拒绝钉扎。
# 这条阀门的存在理由：anytls-server 无法指定证书，每次启动自签一张仅 2 小时
# 有效期的证书，钉扎它会导致每次重启后全部客户端断连。
CERTPIN_MIN_LIFETIME_DAYS=${CERTPIN_MIN_LIFETIME_DAYS:-30}

certpin_protocol_supported() {
  case $1 in
    hysteria2|trojan) return 0 ;;
    *) return 1 ;;
  esac
}

certpin_unsupported_reason() {
  case $1 in
    anytls) printf 'anytls-server 无法指定证书，每次启动自签一张 2 小时有效期的临时证书；钉扎会导致重启后断连' ;;
    reality) printf 'REALITY 借用真实站点证书，客户端凭 public-key 验证，无需指纹钉扎' ;;
    snell4|snell5|snell6) printf 'Snell 不使用 TLS 证书' ;;
    tuic) printf '尚未验证客户端对 TUIC 指纹钉扎的支持，暂不处理' ;;
    *) printf '该协议暂不支持指纹钉扎' ;;
  esac
}

# 在子 shell 中读取凭据字段，避免把实例凭据泄进当前作用域。
certpin_credential_field() {
  local id=$1 field=$2
  (
    load_credentials "$id" 2>/dev/null || exit 0
    printf '%s' "${!field:-}"
  )
}

certpin_current_pin() {
  certpin_credential_field "$1" FINGERPRINT
}

# 目录里出现多张候选证书时，把候选清单留在这里供调用方展示。
CERTPIN_CANDIDATES=''

# sing-box 用 certificate_path，xray 用 certificateFile。同一目录常同时承载
# 两个核心（如 vless-all-in-one 的 /etc/vless-reality），按实例所属服务挑选
# 对应键名，避免把另一个核心的证书张冠李戴地钉到本实例上。
certpin_preferred_cert_key() {
  local id=$1 services
  services=$(instance_services "$id" 2>/dev/null | tr '\n' ' ')
  case $services in
    *sing-box*|*singbox*) printf 'certificate_path' ;;
    *xray*) printf 'certificateFile' ;;
    *) printf '' ;;
  esac
}

# key 为空时匹配所有已知键名；否则只匹配指定键名。
certpin_scan_config_for_key() {
  local file=$1 key=${2:-} path=''
  [[ -r $file ]] || return 0
  if [[ -n $key ]]; then
    path=$(sed -nE "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"([^\"]+)\".*/\1/p" "$file" 2>/dev/null | head -n 1)
  else
    path=$(sed -nE 's/.*"(certificate_path|certificateFile|cert_file)"[[:space:]]*:[[:space:]]*"([^"]+)".*/\2/p' "$file" 2>/dev/null | head -n 1)
    [[ -n $path ]] || path=$(sed -nE 's/^[[:space:]]*cert:[[:space:]]*"?([^"]+)"?[[:space:]]*$/\1/p' "$file" 2>/dev/null | head -n 1)
  fi
  printf '%s' "$path"
}

# 列出目录下互不相同的候选证书路径。
certpin_candidate_certs() {
  local dir=$1 key=${2:-} file path
  [[ -d $dir ]] || return 0
  shopt -s nullglob
  for file in "$dir"/*.json "$dir"/*.yaml "$dir"/*.yml; do
    path=$(certpin_scan_config_for_key "$file" "$key")
    [[ -n $path && -r $path ]] && printf '%s\n' "$path"
  done
  shopt -u nullglob
}

# 返回 0 并打印路径；找不到返回 1；候选多于一张无法确定时返回 2。
certpin_find_cert_file() {
  local id=$1 native config dir key path candidates count
  CERTPIN_CANDIDATES=''
  native="$FRM_INSTANCE_DIR/$id.crt"
  if [[ -r $native ]]; then
    printf '%s\n' "$native"
    return 0
  fi
  config=$(registry_get "$id" '.config_file' 2>/dev/null || true)
  [[ -n $config && $config != null ]] || return 1

  # 实例自己的配置里直接写了证书路径时最可靠。
  path=$(certpin_scan_config_for_key "$config" '')
  if [[ -n $path && -r $path ]]; then
    printf '%s\n' "$path"
    return 0
  fi

  # 否则扫描同目录：先按本实例核心对应的键名收敛。
  dir=$(dirname "$config")
  key=$(certpin_preferred_cert_key "$id")
  candidates=$(certpin_candidate_certs "$dir" "$key" | sort -u)
  [[ -n $candidates ]] || candidates=$(certpin_candidate_certs "$dir" '' | sort -u)
  count=$(grep -c . <<<"$candidates" || true)

  if (( count == 1 )); then
    printf '%s\n' "$candidates"
    return 0
  fi
  if (( count > 1 )); then
    # 宁可拒绝，也不能钉错证书——钉错会让客户端因指纹不匹配而完全连不上。
    CERTPIN_CANDIDATES=$candidates
    return 2
  fi
  return 1
}

# 取证书 PEM 落到 $3；成功时在 stdout 打印来源说明。
certpin_fetch_pem() {
  local id=$1 explicit=${2:-} out=$3
  local transport port sni cert
  local -a args
  if [[ -n $explicit ]]; then
    [[ -r $explicit ]] || { warn "指定的证书文件不可读：$explicit"; return 1; }
    openssl x509 -in "$explicit" -outform pem >"$out" 2>/dev/null || {
      warn "无法解析证书文件：$explicit"
      return 1
    }
    printf '证书文件 %s' "$explicit"
    return 0
  fi

  transport=$(registry_get "$id" '.transport')
  port=$(registry_get "$id" '.port')
  # TCP 协议直接探测本机端口：拿到的正是客户端实际看到的证书，与来源脚本无关。
  if [[ $transport == tcp ]]; then
    sni=$(certpin_credential_field "$id" SNI)
    args=(s_client -connect "127.0.0.1:$port")
    [[ -z $sni ]] || args+=(-servername "$sni")
    if timeout 10 openssl "${args[@]}" </dev/null 2>/dev/null |
        openssl x509 -outform pem >"$out" 2>/dev/null && [[ -s $out ]]; then
      printf '本机 %s 端口实测' "$port"
      return 0
    fi
  fi

  # QUIC/UDP 无法用 s_client 探测，退回定位证书文件。
  local rc=0
  cert=$(certpin_find_cert_file "$id") || rc=$?
  if (( rc == 2 )); then
    warn "$id 所在目录存在多张候选证书，无法确定属于本实例，已中止以免钉错："
    printf '%s\n' "$CERTPIN_CANDIDATES" | sed 's/^/           /' >&2
    warn "请核对后用 frm cert pin $id --cert <路径> 指定。"
    return 1
  fi
  if (( rc != 0 )) || [[ -z $cert ]]; then
    warn "无法自动定位 $id 的证书；确认路径后用 frm cert pin $id --cert <路径> 指定。"
    return 1
  fi
  openssl x509 -in "$cert" -outform pem >"$out" 2>/dev/null || {
    warn "无法解析证书文件：$cert"
    return 1
  }
  printf '证书文件 %s' "$cert"
}

certpin_lifetime_days() {
  local pem=$1 start end start_epoch end_epoch
  start=$(openssl x509 -in "$pem" -noout -startdate 2>/dev/null | cut -d= -f2)
  end=$(openssl x509 -in "$pem" -noout -enddate 2>/dev/null | cut -d= -f2)
  [[ -n $start && -n $end ]] || return 1
  start_epoch=$(date -d "$start" +%s 2>/dev/null) || return 1
  end_epoch=$(date -d "$end" +%s 2>/dev/null) || return 1
  printf '%d\n' $(( (end_epoch - start_epoch) / 86400 ))
}

certpin_fingerprint_of() {
  openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2
}

# 只替换 FINGERPRINT 一行，保留其余凭据字段。
certpin_store() {
  local id=$1 fingerprint=$2 file tmp
  file=$(credential_path "$id")
  [[ -r $file ]] || die "实例凭据不存在：$file"
  tmp="$file.new"
  {
    grep -v '^FINGERPRINT=' "$file" || true
    [[ -z $fingerprint ]] || printf 'FINGERPRINT=%q\n' "$fingerprint"
  } >"$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$file"
}

certpin_pin_instance() {
  local id=$1 explicit=${2:-} protocol pem source days fingerprint existing
  registry_exists "$id" || die "实例不存在：$id"
  protocol=$(registry_get "$id" '.protocol')
  if ! certpin_protocol_supported "$protocol"; then
    printf '  [跳过] %s（%s）：%s\n' "$id" "$protocol" "$(certpin_unsupported_reason "$protocol")"
    return 0
  fi

  pem=$(mktemp)
  if ! source=$(certpin_fetch_pem "$id" "$explicit" "$pem"); then
    rm -f "$pem"
    printf '  [失败] %s：未能取得证书\n' "$id"
    return 1
  fi

  if ! days=$(certpin_lifetime_days "$pem"); then
    rm -f "$pem"
    printf '  [失败] %s：无法解析证书有效期\n' "$id"
    return 1
  fi

  # 安全阀：临时证书钉扎后会在下次重启失效，宁可不钉。
  if (( days < CERTPIN_MIN_LIFETIME_DAYS )); then
    rm -f "$pem"
    printf '  [拒绝] %s：证书有效期仅 %d 天（阈值 %d 天），判定为临时证书。\n' \
      "$id" "$days" "$CERTPIN_MIN_LIFETIME_DAYS"
    printf '         钉扎它会在服务重启换证后导致客户端断连，因此不予钉扎。\n'
    return 1
  fi

  fingerprint=$(certpin_fingerprint_of "$pem")
  rm -f "$pem"
  [[ -n $fingerprint ]] || { printf '  [失败] %s：指纹计算为空\n' "$id"; return 1; }

  existing=$(certpin_current_pin "$id")
  if [[ $existing == "$fingerprint" ]]; then
    printf '  [已是最新] %s（来源：%s，有效期 %d 天）\n' "$id" "$source" "$days"
    return 0
  fi

  certpin_store "$id" "$fingerprint"
  if [[ -n $existing ]]; then
    printf '  [已更新] %s（来源：%s，有效期 %d 天）——证书已变更，旧指纹被替换\n' "$id" "$source" "$days"
  else
    printf '  [已钉扎] %s（来源：%s，有效期 %d 天）\n' "$id" "$source" "$days"
  fi
  log_action "cert pinned $id"
}

certpin_pin_command() {
  local target=${1:-all} explicit=${2:-} id failed=0 handled=0
  if [[ $target != all ]]; then
    certpin_pin_instance "$target" "$explicit" || failed=1
  else
    [[ -z $explicit ]] || die "--cert 只能与单个实例一起使用。"
    printf '为所有支持的实例补录证书指纹：\n'
    while IFS= read -r id; do
      [[ -n $id ]] || continue
      ((handled+=1))
      certpin_pin_instance "$id" || failed=1
    done < <(registry_ids)
    (( handled > 0 )) || warn "注册表中没有实例。"
  fi
  printf '\n完成后请重新生成订阅（frm sub fragment），并确认客户端能正常解析与连接。\n'
  (( failed == 0 ))
}

certpin_unpin_command() {
  local id=$1
  registry_exists "$id" || die "实例不存在：$id"
  [[ -n $(certpin_current_pin "$id") ]] || { info "$id 当前没有指纹钉扎。"; return 0; }
  certpin_store "$id" ''
  log_action "cert unpinned $id"
  ok "已移除 $id 的指纹钉扎；请重新生成订阅。"
}

certpin_scan_command() {
  local id protocol pin state
  printf '=== 证书指纹钉扎状态（只读）===\n'
  printf '%-34s %-12s %-10s %s\n' 实例 协议 状态 说明
  printf '%-34s %-12s %-10s %s\n' ---------------------------------- ------------ ---------- ----
  while IFS= read -r id; do
    [[ -n $id ]] || continue
    protocol=$(registry_get "$id" '.protocol')
    if ! certpin_protocol_supported "$protocol"; then
      printf '%-34s %-12s %-10s %s\n' "$id" "$protocol" 不适用 "$(certpin_unsupported_reason "$protocol")"
      continue
    fi
    pin=$(certpin_current_pin "$id")
    if [[ -n $pin ]]; then
      state=已钉扎
    else
      state=待钉扎
    fi
    printf '%-34s %-12s %-10s %s\n' "$id" "$protocol" "$state" "${pin:-执行 frm cert pin $id 补录}"
  done < <(registry_ids)
  printf '\n钉扎只影响客户端导出，不改动服务端配置与证书。\n'
}

certpin_command() {
  local action=${1:-scan} target=${2:-} explicit=''
  shift || true
  shift || true
  while (( $# > 0 )); do
    case $1 in
      --cert) [[ $# -ge 2 ]] || die "--cert 缺少参数。"; explicit=$2; shift 2 ;;
      *) die "未知 cert 参数：$1" ;;
    esac
  done
  case $action in
    scan|status) certpin_scan_command ;;
    pin) certpin_pin_command "${target:-all}" "$explicit" ;;
    unpin) [[ -n $target ]] || die "请指定实例：frm cert unpin <实例>"; certpin_unpin_command "$target" ;;
    *) die "未知 cert 命令：$action。可用：scan、pin、unpin。" ;;
  esac
}
