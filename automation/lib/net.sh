# net.sh — 네트워크 작업 재시도 래퍼. lib/load_env.sh, lib/ui.sh 이후 source.
# 사용: net_retry git fetch --tags origin
# 4회 시도, 3/6/9초 백오프. 마지막 실패 시 비-0 리턴.
# ※ 각 시도를 timeout(NET_TIMEOUT)으로 감싼다 — TCP 스톨(연결 후 무응답)로 git 이
#   영원히 hang 하면 재시도조차 못 돌던 실측 버그 방지. timeout 만료(124)도 재시도 대상.
net_retry() {
  local tries=4 delay=3 i rc
  for ((i = 1; i <= tries; i++)); do
    timeout "${NET_TIMEOUT:-900}" "$@" && return 0
    rc=$?
    if ((i < tries)); then
      ui_warn "재시도 $i/$((tries - 1)): $* (rc=$rc, ${delay}s 대기)"
      sleep "$delay"
      delay=$((delay + 3))
    fi
  done
  return "$rc"
}
