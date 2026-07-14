# net.sh — 네트워크 작업 재시도 래퍼. lib/load_env.sh, lib/ui.sh 이후 source.
# 사용: net_retry git fetch --tags origin
# 4회 시도, 3/6/9초 백오프. 마지막 실패 시 비-0 리턴.
net_retry() {
  local tries=4 delay=3 i rc
  for ((i = 1; i <= tries; i++)); do
    "$@" && return 0
    rc=$?
    if ((i < tries)); then
      ui_warn "재시도 $i/$((tries - 1)): $* (rc=$rc, ${delay}s 대기)"
      sleep "$delay"
      delay=$((delay + 3))
    fi
  done
  return "$rc"
}
