#!/usr/bin/env bash

backup_all() {
  local timestamp archive
  timestamp=$(date +%Y%m%d-%H%M%S)
  archive="$FRM_BACKUP_DIR/frm-node-$timestamp.tar.gz"
  # takeovers 目录本身就是独立备份，不再重复打包，避免体积滚雪球。
  tar -C / --wildcards --ignore-failed-read \
    --exclude='var/lib/frm-node/backups' --exclude='var/lib/frm-node/takeovers' -czf "$archive" \
    etc/frm-node var/lib/frm-node 'etc/systemd/system/frm-*.service' 2>/dev/null || {
      rm -f "$archive"
      die "备份失败。"
    }
  chmod 0600 "$archive"
  # 只保留最近 7 份日常备份，防止无限累积占满磁盘。
  find "$FRM_BACKUP_DIR" -maxdepth 1 -type f -name 'frm-node-*.tar.gz' | sort | head -n -7 | xargs -r rm -f --
  ok "备份完成：$archive"
}

restore_backup() {
  local archive=${1:-} id service
  [[ -n $archive ]] || archive=$(find "$FRM_BACKUP_DIR" -maxdepth 1 -type f -name 'frm-node-*.tar.gz' | sort | tail -n 1)
  [[ -r $archive ]] || die "找不到备份文件。"
  tar -tzf "$archive" >/dev/null || die "备份压缩包损坏。"
  confirm "恢复 $archive 会覆盖当前节点配置，继续吗" N || return 0
  tar -C / -xzf "$archive"
  systemctl daemon-reload
  while IFS= read -r id; do
    # 接管实例的共享旧核心不属于本备份范围，恢复时不动它们的服务。
    if registry_is_external "$id"; then
      warn "跳过接管实例 $id 的服务重启；如有需要请单独处理。"
      continue
    fi
    while IFS= read -r service; do
      systemctl enable "$service" >/dev/null 2>&1 || true
    done < <(instance_services "$id")
    instance_service_action "$id" restart
  done < <(registry_ids)
  doctor_all
}

update_core() {
  local core=$1 binary=$2 protocol_filter=$3 backup id failed=0
  [[ -x $binary ]] || { warn "$core 尚未安装，跳过。"; return 0; }
  backup="$binary.bak.$(date +%s)"
  cp -a "$binary" "$backup"
  export FRM_FORCE_DOWNLOAD=1
  case $core in
    anytls) ensure_anytls_binary ;;
    hysteria2) ensure_hysteria_binary ;;
    xray) ensure_xray_binary ;;
    snell4) ensure_snell_binary 4 ;;
    snell5) ensure_snell_binary 5 ;;
    snell6) ensure_snell_binary 6 ;;
  esac
  unset FRM_FORCE_DOWNLOAD
  while IFS= read -r id; do
    registry_is_external "$id" && continue
    instance_service_action "$id" restart || failed=1
  done < <(jq -r --arg p "$protocol_filter" 'select(.protocol == $p and (.ownership // "frm") == "frm") | .id' "$FRM_REGISTRY_DIR"/*.json 2>/dev/null || true)
  if (( failed )); then
    warn "$core 更新后服务异常，正在回滚。"
    mv -f "$backup" "$binary"
    while IFS= read -r id; do
      registry_is_external "$id" && continue
      instance_service_action "$id" restart || true
    done < <(jq -r --arg p "$protocol_filter" 'select(.protocol == $p and (.ownership // "frm") == "frm") | .id' "$FRM_REGISTRY_DIR"/*.json 2>/dev/null || true)
    return 1
  fi
  rm -f "$backup"
  ok "$core 核心更新完成。"
}

update_installed_cores() {
  backup_all
  update_core anytls "$FRM_BIN_DIR/anytls-server" anytls
  update_core hysteria2 "$FRM_BIN_DIR/hysteria" hysteria2
  update_core xray "$FRM_BIN_DIR/xray" reality
  update_core snell4 "$FRM_BIN_DIR/snell-server-v4" snell4
  update_core snell5 "$FRM_BIN_DIR/snell-server-v5" snell5
  if [[ -x $FRM_BIN_DIR/snell-server-v6 ]]; then
    warn "Snell v6 是测试版，将按 versions.env 中锁定的版本更新。"
  fi
  update_core snell6 "$FRM_BIN_DIR/snell-server-v6" snell6
  doctor_all
}

remove_instance() {
  local id=$1 port transport service config credential
  registry_exists "$id" || die "实例不存在：$id"
  if registry_is_external "$id"; then
    die "该实例来自原地接管。为避免误删共用核心，不能使用普通 uninstall；兼容登记可用 adopt forget，完整接管可先 adopt rollback。"
  fi
  port=$(registry_get "$id" '.port')
  transport=$(registry_get "$id" '.transport')
  config=$(registry_get "$id" '.config_file')
  credential=$(registry_get "$id" '.credential_file')
  confirm "确认删除实例 $id" N || return 0
  while IFS= read -r service; do remove_service "$service"; done < <(instance_services "$id")
  firewall_close "$port" "$transport"
  [[ -z $config ]] || rm -f "$config" "${config%.*}.crt" "${config%.*}.key"
  rm -f "$credential"
  registry_remove "$id"
  log_action "removed $id"
  ok "实例 $id 已删除，共享核心文件保留。"
}

migrate_legacy() {
  local legacy=$FRM_ETC/credentials.env any_cred hy_cred
  [[ -r $legacy ]] || { info "没有发现旧版 FRM 配置。"; return 0; }
  # shellcheck disable=SC1090
  source "$legacy"
  if [[ -n ${ANYTLS_PORT:-} && ! -e $FRM_REGISTRY_DIR/anytls-legacy.json ]]; then
    any_cred=$(credential_path anytls-legacy)
    write_credentials anytls-legacy SERVER_IPV4 "${SERVER_IPV4:-$(public_ipv4)}" PORT "$ANYTLS_PORT" \
      PASSWORD "$ANYTLS_PASSWORD" SNI "${ANYTLS_SNI:-www.apple.com}"
    registry_write anytls-legacy anytls "AnyTLS（旧版导入）" "$ANYTLS_PORT" tcp legacy \
      "$any_cred" "" frm-anytls.service
    ok "已接管旧版 AnyTLS，未改动服务配置。"
  fi
  if [[ -n ${HY2_PORT:-} && ! -e $FRM_REGISTRY_DIR/hysteria2-legacy.json ]]; then
    hy_cred=$(credential_path hysteria2-legacy)
    write_credentials hysteria2-legacy SERVER_IPV4 "${SERVER_IPV4:-$(public_ipv4)}" PORT "$HY2_PORT" \
      PASSWORD "$HY2_PASSWORD" SNI "${HY2_SNI:-www.apple.com}" OBFS_PASSWORD ""
    registry_write hysteria2-legacy hysteria2 "Hysteria2（旧版导入）" "$HY2_PORT" udp legacy \
      "$hy_cred" "$FRM_ETC/hysteria.yaml" frm-hysteria.service
    ok "已接管旧版 Hysteria2，未改动服务配置。"
  fi
}
