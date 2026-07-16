#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INSTALL_DIR=${FRM_INSTALL_DIR:-/opt/frm-node}

[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "请使用 root 运行安装器。" >&2; exit 1; }
[[ -f $SOURCE_DIR/frm-node && -f $SOURCE_DIR/lib/common.sh ]] || {
  echo "安装包不完整。" >&2
  exit 1
}

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
fi
case ${ID:-} in
  debian|ubuntu) ;;
  *) echo "当前首版仅支持 Debian/Ubuntu。" >&2; exit 1 ;;
esac

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y bash ca-certificates curl jq openssl unzip iproute2

install -d -m 0755 "$INSTALL_DIR"
cp -a "$SOURCE_DIR/frm-node" "$SOURCE_DIR/install.sh" "$SOURCE_DIR/bootstrap.sh" \
  "$SOURCE_DIR/versions.env" "$SOURCE_DIR/README.md" "$SOURCE_DIR/lib" \
  "$SOURCE_DIR/protocols" "$INSTALL_DIR/"
chmod 0755 "$INSTALL_DIR/frm-node" "$INSTALL_DIR"/lib/*.sh "$INSTALL_DIR"/protocols/*.sh

ln -sfn "$INSTALL_DIR/frm-node" /usr/local/bin/frm-node
if [[ ! -e /usr/local/bin/frm || -L /usr/local/bin/frm ]]; then
  ln -sfn "$INSTALL_DIR/frm-node" /usr/local/bin/frm
else
  echo "[注意] /usr/local/bin/frm 已存在，未覆盖；请使用 frm-node。"
fi

"$INSTALL_DIR/frm-node" migrate
command -v frm-node >/dev/null
"$INSTALL_DIR/frm-node" version
"$INSTALL_DIR/frm-node" status

echo
echo "安装完成。以后输入 frm 打开中文菜单，或使用 frm-node。"
