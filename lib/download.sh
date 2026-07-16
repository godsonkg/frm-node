#!/usr/bin/env bash

download_file() {
  local url=$1 destination=$2
  info "下载：$url"
  curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 -o "$destination" "$url"
  [[ -s $destination ]] || die "下载文件为空：$url"
  sha256sum "$destination" | tee "$destination.sha256" >>"$FRM_LOG"
}

github_latest_asset_url() {
  local repo=$1 pattern=$2
  curl -fsSL --retry 3 "https://api.github.com/repos/$repo/releases/latest" |
    jq -r --arg pattern "$pattern" '.assets[] | select(.name | test($pattern)) | .browser_download_url' |
    head -n 1
}

install_zip_binary() {
  local archive=$1 binary_name=$2 destination=$3 dir candidate
  dir=$(mktemp -d)
  unzip -q -o "$archive" -d "$dir"
  candidate=$(find "$dir" -type f -name "$binary_name" -print -quit)
  [[ -n $candidate ]] || { rm -rf "$dir"; die "压缩包中没有找到 $binary_name。"; }
  atomic_install_file "$candidate" "$destination" 0755
  rm -rf "$dir"
}

install_raw_binary() {
  local file=$1 destination=$2
  atomic_install_file "$file" "$destination" 0755
}

