#!/usr/bin/env bash

protocol_rollback() {
  local id=$1 service=${2:-}
  warn "安装未完成，正在回滚实例 $id。"
  [[ -n $service ]] && remove_service "$service"
  rm -f "$(credential_path "$id")" "$(config_path "$id")" "$(registry_path "$id")"
}

protocol_rollback_multi() {
  local id=$1 service
  shift
  warn "安装未完成，正在回滚实例 $id。"
  for service in "$@"; do
    [[ -n $service ]] && remove_service "$service"
  done
  rm -f "$(credential_path "$id")" "$(config_path "$id")" "$(registry_path "$id")"
}

write_credentials() {
  local id=$1
  shift
  local file
  file=$(credential_path "$id")
  : >"$file"
  while (( $# >= 2 )); do
    printf '%s=%q\n' "$1" "$2" >>"$file"
    shift 2
  done
  chmod 0600 "$file"
}

load_credentials() {
  local id=$1 file
  file=$(credential_path "$id")
  [[ -r $file ]] || die "实例凭据不存在：$file"
  # shellcheck disable=SC1090
  source "$file"
}

install_dependencies() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y ca-certificates curl jq openssl unzip iproute2
}

ensure_anytls_binary() {
  local destination=$FRM_BIN_DIR/anytls-server arch url archive
  [[ -x $destination && ${FRM_FORCE_DOWNLOAD:-0} != 1 ]] && return 0
  arch=$(detect_arch)
  [[ $arch == amd64 || $arch == arm64 ]] || die "AnyTLS 暂不支持当前架构：$arch"
  url=$(github_latest_asset_url anytls/anytls-go "linux_${arch}\\.zip$")
  [[ -n $url ]] || die "没有找到 AnyTLS 的 $arch 官方发布包。"
  archive=$(mktemp --suffix=.zip)
  download_file "$url" "$archive"
  install_zip_binary "$archive" anytls-server "$destination"
  rm -f "$archive" "$archive.sha256"
}

ensure_hysteria_binary() {
  local destination=$FRM_BIN_DIR/hysteria arch url file
  [[ -x $destination && ${FRM_FORCE_DOWNLOAD:-0} != 1 ]] && return 0
  arch=$(detect_arch)
  [[ $arch == amd64 || $arch == arm64 ]] || die "Hysteria2 暂不支持当前架构：$arch"
  url=$(github_latest_asset_url apernet/hysteria "^hysteria-linux-${arch}$")
  [[ -n $url ]] || die "没有找到 Hysteria2 的 $arch 官方发布包。"
  file=$(mktemp)
  download_file "$url" "$file"
  install_raw_binary "$file" "$destination"
  rm -f "$file" "$file.sha256"
}

ensure_xray_binary() {
  local destination=$FRM_BIN_DIR/xray arch asset url archive
  [[ -x $destination && ${FRM_FORCE_DOWNLOAD:-0} != 1 ]] && return 0
  arch=$(detect_arch)
  case $arch in
    amd64) asset='Xray-linux-64\.zip$' ;;
    arm64) asset='Xray-linux-arm64-v8a\.zip$' ;;
    *) die "Xray 暂不支持当前架构：$arch" ;;
  esac
  url=$(github_latest_asset_url XTLS/Xray-core "$asset")
  [[ -n $url ]] || die "没有找到 Xray 的 $arch 官方发布包。"
  archive=$(mktemp --suffix=.zip)
  download_file "$url" "$archive"
  install_zip_binary "$archive" xray "$destination"
  rm -f "$archive" "$archive.sha256"
}

ensure_snell_binary() {
  local major=$1 version arch upstream_arch url archive destination
  destination="$FRM_BIN_DIR/snell-server-v$major"
  [[ -x $destination && ${FRM_FORCE_DOWNLOAD:-0} != 1 ]] && return 0
  arch=$(detect_arch)
  case $arch in
    amd64|i386|armv7l) upstream_arch=$arch ;;
    arm64) upstream_arch=aarch64 ;;
    *) die "Snell 暂不支持当前架构：$arch" ;;
  esac
  case $major in
    4) version=$SNELL4_VERSION ;;
    5) version=$SNELL5_VERSION ;;
    6) version=$SNELL6_VERSION ;;
    *) die "未知 Snell 版本：$major" ;;
  esac
  url="https://dl.nssurge.com/snell/snell-server-v${version}-linux-${upstream_arch}.zip"
  archive=$(mktemp --suffix=.zip)
  download_file "$url" "$archive"
  verify_pinned_sha256 "$archive" "SNELL${major}_SHA256_${upstream_arch^^}" "Snell v$major"
  install_zip_binary "$archive" snell-server "$destination"
  rm -f "$archive" "$archive.sha256"
}

# 若 versions.env 提供了对应校验和则强制比对；留空只提示，方便首次可信下载后钉扎。
verify_pinned_sha256() {
  local file=$1 var_name=$2 label=$3 expected
  expected=${!var_name:-}
  if [[ -z $expected ]]; then
    warn "versions.env 未提供 $var_name，本次跳过校验；可将日志中的 SHA-256 填入后钉扎。"
    return 0
  fi
  if ! printf '%s  %s\n' "$expected" "$file" | sha256sum -c - >/dev/null 2>&1; then
    die "$label 下载文件与 versions.env 中钉扎的 SHA-256 不匹配，已停止安装。"
  fi
  info "$label 下载校验通过。"
}

ensure_shadowtls_binary() {
  local destination=$FRM_BIN_DIR/shadow-tls arch asset url file
  [[ -x $destination && ${FRM_FORCE_DOWNLOAD:-0} != 1 ]] && return 0
  arch=$(detect_arch)
  case $arch in
    amd64) asset='shadow-tls-x86_64-unknown-linux-musl$' ;;
    arm64) asset='shadow-tls-aarch64-unknown-linux-musl$' ;;
    *) die "ShadowTLS 暂不支持当前架构：$arch" ;;
  esac
  url=$(github_latest_asset_url ihciah/shadow-tls "$asset")
  [[ -n $url ]] || die "没有找到 ShadowTLS 的 $arch 官方发布包。"
  file=$(mktemp)
  download_file "$url" "$file"
  install_raw_binary "$file" "$destination"
  rm -f "$file" "$file.sha256"
}
