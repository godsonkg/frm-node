#!/usr/bin/env bash
set -Eeuo pipefail

REPO=${FRM_REPO:-godsonkg/frm-node}
REF=${FRM_REF:-main}
WORK_DIR=$(mktemp -d)
ARCHIVE="$WORK_DIR/frm-node.tar.gz"

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "请使用 root 运行安装器。" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "缺少 curl。" >&2; exit 1; }
command -v tar >/dev/null 2>&1 || { echo "缺少 tar。" >&2; exit 1; }

echo "正在下载 $REPO ($REF)..."
# archive/<ref> 同时支持分支、tag 和 commit，便于用 FRM_REF 固定版本。
curl -fL --retry 3 --connect-timeout 15 \
  "https://github.com/$REPO/archive/$REF.tar.gz" -o "$ARCHIVE"
echo "安装包 SHA-256：$(sha256sum "$ARCHIVE" | cut -d' ' -f1)"
if [[ -n ${FRM_SHA256:-} ]]; then
  printf '%s  %s\n' "$FRM_SHA256" "$ARCHIVE" | sha256sum -c - >/dev/null 2>&1 || {
    echo "安装包与 FRM_SHA256 校验值不匹配，已停止安装。" >&2
    exit 1
  }
  echo "安装包校验通过。"
fi
tar -xzf "$ARCHIVE" -C "$WORK_DIR"

SOURCE_DIR=$(find "$WORK_DIR" -mindepth 1 -maxdepth 1 -type d -name 'frm-node-*' -print -quit)
[[ -n $SOURCE_DIR && -f $SOURCE_DIR/install.sh ]] || {
  echo "下载包结构不完整，已停止安装。" >&2
  exit 1
}

bash "$SOURCE_DIR/install.sh"

