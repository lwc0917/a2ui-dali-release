# ui.sh — 로깅 헬퍼. automation/*.sh 가 source 한다.
# [step]/[ERROR] 접두사는 agent.yaml 의 logs.step_patterns 와 일치 → 허브가 진행/에러로 렌더.
ui_step() { printf '[step] %s\n' "$*"; }
ui_info() { printf '  %s\n' "$*"; }
ui_ok()   { printf '  [ok] %s\n' "$*"; }
ui_warn() { printf '  [warn] %s\n' "$*"; }
ui_err()  { printf '[ERROR] %s\n' "$*" >&2; }
