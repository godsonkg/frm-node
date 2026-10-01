#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export FRM_HOME=$ROOT FRM_ETC=$TMP/etc FRM_STATE=$TMP/state FRM_LOG=$TMP/log
source "$ROOT/versions.env"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/registry.sh"
source "$ROOT/lib/service.sh"
source "$ROOT/lib/update_checks.sh"
source "$ROOT/lib/maintenance.sh"
init_layout
export FRM_UPDATE_HEALTH_SAMPLES=3 FRM_UPDATE_HEALTH_INTERVAL=1
printf 'config\n' >"$FRM_INSTANCE_DIR/native.conf"
printf 'private\n' >"$FRM_INSTANCE_DIR/native.env"
registry_write native anytls Native 12345 tcp old "$FRM_INSTANCE_DIR/native.env" "$FRM_INSTANCE_DIR/native.conf" native.service
registry_write external anytls External 12346 tcp old "$FRM_INSTANCE_DIR/native.env" "$FRM_INSTANCE_DIR/native.conf" external.service
registry_mark_adopted external test shared /old/bin
printf '#!/usr/bin/env bash\necho anytls 1.0.0\n' >"$FRM_BIN_DIR/anytls-server"
chmod +x "$FRM_BIN_DIR/anytls-server"
MODE=healthy
systemctl() {
  [[ $* != *external.service* ]] || { echo 'External service touched' >&2; return 99; }
  case $1 in
    is-active) [[ $MODE != dead ]] ;;
    show)
      local count=0
      [[ ! -f $TMP/count ]] || read -r count <"$TMP/count"
      ((count+=1)); echo "$count" >"$TMP/count"
      if [[ $MODE == flapping ]]; then printf 'MainPID=%s\nNRestarts=%s\n' "$((100+count))" "$count"
      else printf 'MainPID=100\nNRestarts=0\nExecMainStartTimestampMonotonic=1000\n'; fi ;;
    restart) [[ ${RESTART_FAIL:-0} == 0 ]] || return 1; printf '%s\n' "$2" >>"$TMP/restarts" ;;
    *) return 99 ;;
  esac
}
ss() { [[ $MODE != noport ]] && echo LISTEN; }
sleep() { :; }
curl() {
  case ${API_MODE:-ok} in
    ok) printf '{"tag_name":"v1.1.0","draft":false,"prerelease":false}\n' ;;
    same) printf '{"tag_name":"v1.0.0","draft":false,"prerelease":false}\n' ;;
    hysteria) printf '{"tag_name":"app/v1.0.0","draft":false,"prerelease":false}\n' ;;
    invalid) echo '{"message":"rate limit"}' ;;
    fail) return 22 ;;
  esac
}
assert_fails() { if "$@"; then echo "Unexpected success: $*" >&2; exit 1; fi; }
update_health_instance native
MODE=dead; assert_fails update_health_instance native
MODE=noport; assert_fails update_health_instance native
MODE=flapping; assert_fails update_health_instance native
MODE=healthy
FRM_UPDATE_HEALTH_SAMPLES=08 assert_fails update_health_instance native
FRM_UPDATE_HEALTH_SAMPLES=1 assert_fails update_health_instance native
FRM_UPDATE_HEALTH_INTERVAL=0 assert_fails update_health_instance native
update_preflight
printf broken >"$FRM_REGISTRY_DIR/broken.json"
assert_fails update_preflight
rm "$FRM_REGISTRY_DIR/broken.json"
update_preflight
[[ ! -e $TMP/restarts ]]
check_core_updates >"$TMP/version-report"
grep -q '1.1.0' "$TMP/version-report"
API_MODE=same check_core_updates >"$TMP/version-report"
grep -q '版本相同' "$TMP/version-report"
API_MODE=fail assert_fails check_core_updates
API_MODE=invalid assert_fails check_core_updates
# Hysteria's official app/v prefix must not be rejected.
cp "$FRM_BIN_DIR/anytls-server" "$FRM_BIN_DIR/hysteria"
mv "$FRM_BIN_DIR/anytls-server" "$TMP/saved-anytls"
API_MODE=hysteria check_core_updates >"$TMP/version-report"
grep -q '版本相同' "$TMP/version-report"
rm "$FRM_BIN_DIR/hysteria"
mv "$TMP/saved-anytls" "$FRM_BIN_DIR/anytls-server"
[[ ! -e $TMP/restarts ]]
mv "$FRM_INSTANCE_DIR/native.conf" "$TMP/config"
assert_fails update_preflight
mv "$TMP/config" "$FRM_INSTANCE_DIR/native.conf"

# Stub only the download boundary; all restart/health/rollback code is real.
update_download_core() { printf '#!/usr/bin/env bash\necho new\n' >"$FRM_BIN_DIR/anytls-server"; }
update_core anytls "$FRM_BIN_DIR/anytls-server" anytls
grep -q 'echo new' "$FRM_BIN_DIR/anytls-server"
[[ $(wc -l <"$TMP/restarts") == 1 ]]
if compgen -G "$FRM_BIN_DIR/*.bak.*" >/dev/null; then exit 1; fi
printf '#!/usr/bin/env bash\necho old\n' >"$FRM_BIN_DIR/anytls-server"
MODE=flapping
assert_fails update_core anytls "$FRM_BIN_DIR/anytls-server" anytls
grep -q 'echo old' "$FRM_BIN_DIR/anytls-server"
[[ $(wc -l <"$TMP/restarts") == 3 ]]
MODE=healthy
RESTART_FAIL=1 assert_fails update_core anytls "$FRM_BIN_DIR/anytls-server" anytls
grep -q 'echo old' "$FRM_BIN_DIR/anytls-server"
# Invoked indirectly by update_core.
# shellcheck disable=SC2329
update_download_core() { printf broken >"$FRM_BIN_DIR/anytls-server"; return 1; }
assert_fails update_core anytls "$FRM_BIN_DIR/anytls-server" anytls
grep -q 'echo old' "$FRM_BIN_DIR/anytls-server"
[[ $(wc -l <"$TMP/restarts") == 3 ]]
[[ ${FRM_FORCE_DOWNLOAD:-unset} == unset ]]

# Real isolated downloader: false must stop even if caller is conditional.
source "$ROOT/lib/update_checks.sh"
mkdir -p "$TMP/fake-home/lib" "$TMP/fake-home/protocols"
printf ':\n' >"$TMP/fake-home/versions.env"
printf ':\n' >"$TMP/fake-home/lib/common.sh"
printf ':\n' >"$TMP/fake-home/lib/download.sh"
# Child shell expands this variable when the fixture runs.
# shellcheck disable=SC2016
printf 'ensure_anytls_binary() { false; echo BAD >"$FRM_BIN_DIR/fallthrough"; }\n' >"$TMP/fake-home/protocols/base.sh"
FRM_HOME="$TMP/fake-home" assert_fails update_download_core anytls
[[ ! -e $FRM_BIN_DIR/fallthrough ]]

# CLI read-only routing: no init_layout, directories or log may be created.
FRM_STATE="$TMP/nonexistent" FRM_ETC="$TMP/nonexistent-etc" FRM_BIN_DIR="$TMP/missing-bin" \
  FRM_LOG="$TMP/no-log" bash "$ROOT/frm-node" update --check
[[ ! -e $TMP/nonexistent && ! -e $TMP/nonexistent-etc && ! -e $TMP/no-log ]]
FRM_STATE="$TMP/nonexistent" FRM_ETC="$TMP/nonexistent-etc" FRM_BIN_DIR="$TMP/missing-bin" \
  FRM_REGISTRY_DIR="$TMP/missing-registry" FRM_LOG="$TMP/no-log" \
  assert_fails bash "$ROOT/frm-node" update --dry-run
[[ ! -e $TMP/nonexistent && ! -e $TMP/nonexistent-etc && ! -e $TMP/no-log ]]
assert_fails bash "$ROOT/frm-node" update --unknown
printf 'update reliability smoke: PASS\n'
