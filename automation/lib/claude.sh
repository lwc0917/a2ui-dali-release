# claude.sh — 헤드리스 Claude 호출 단일 래퍼. 모든 에스컬레이션이 여길 지나간다.
# 안전 규칙 (thorvg/dali-preview 패턴):
#  - cwd 는 항상 호출자가 지정한 체크아웃 — Claude 는 그 밖(dali-*, 게이트, baseline)에 못 간다.
#  - Bash/Web* 도구 금지 — 빌드/테스트/git 은 항상 오케스트레이터가 실행.
#  - *_TOKEN env 스트립 — 코드 수정 프로세스에 자격증명 노출 금지.
#  - wall-clock 상한(CLAUDE_TIMEOUT) + --output-format json 파싱(is_error 체크).

# claude_call <cwd> <allowedTools(공백구분)> <prompt> → 결과 텍스트를 stdout, 실패 비-0
claude_call() {
  local dir=$1 tools=$2 prompt=$3
  local raw rc
  raw=$(cd "$dir" && env -u GITHUB_TOKEN -u GH_TOKEN -u GH_ENTERPRISE_TOKEN -u GHCR_TOKEN \
        ANTHROPIC_MODEL="$CLAUDE_MODEL" \
        timeout "$CLAUDE_TIMEOUT" \
        claude -p "$prompt" \
          --permission-mode acceptEdits \
          --allowedTools "$tools" \
          --disallowedTools "Bash,WebFetch,WebSearch" \
          --output-format json \
        </dev/null 2>>"$WORKSPACE/claude.err")
  rc=$?
  if [ $rc -ne 0 ]; then
    ui_warn "claude 호출 실패 (rc=$rc, timeout=$CLAUDE_TIMEOUT s)"
    return 1
  fi
  printf '%s' "$raw" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except json.JSONDecodeError:
    sys.exit(1)
if d.get("is_error"):
    sys.exit(1)
print(d.get("result", ""))
'
}

# claude_judgement <cwd> <prompt> <default> <allowed>...
# 결과에서 허용 단어만 채택(마지막 등장 우선). 파싱 불가/호출 실패 → default (보수 기본값).
claude_judgement() {
  local dir=$1 prompt=$2 default=$3
  shift 3
  local allowed=("$@") out word verdict="$default"
  if out=$(claude_call "$dir" "Read Glob" "$prompt"); then
    for word in $out; do
      word=${word//[^A-Za-z_-]/}
      local a
      for a in "${allowed[@]}"; do
        [ "$word" = "$a" ] && verdict=$word
      done
    done
  fi
  echo "$verdict"
}
