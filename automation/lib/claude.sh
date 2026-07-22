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
  # 원문을 반드시 남긴다. 예전엔 실패 시 응답을 버려서 '왜' 를 알 수 없었고, 그 결과
  # 사용량 한도(429) 같은 '모델이 아예 실행되지 못한' 경우까지 "AI 가 시도했으나 해결 못 함"
  # 으로 보고됐다(실측 2026-07-21: session limit → 수정 시도 0회인데 예산만 소진).
  printf '%s' "$raw" > "$WORKSPACE/claude.last.json" 2>/dev/null || true
  if [ $rc -ne 0 ]; then
    # 실패 원문은 덮어쓰지 말고 보존한다 — claude.last.json 은 매 호출마다 덮여서 정작 실패한
    # 호출의 원문이 사라지고 진단이 불가능했다(실측 2026-07-22). 실패만 append.
    { echo "=== rc=$rc $(date +%H:%M:%S) ==="; printf '%s\n' "$raw"; } >> "$WORKSPACE/claude.failures.log" 2>/dev/null || true
    ui_warn "claude 호출 실패 (rc=$rc, timeout=$CLAUDE_TIMEOUT s)"
    return "$(claude_failure_kind "$raw" "$rc")"
  fi
    local parsed
  if ! parsed=$(printf '%s' "$raw" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except json.JSONDecodeError:
    sys.exit(1)
if d.get("is_error"):
    sys.exit(1)
print(d.get("result", ""))
'); then
    # 실패 사유를 사람이 읽을 수 있게 남긴다(한도/네트워크/거부를 구분해야 대응이 갈린다).
    { echo "=== parse-fail $(date +%H:%M:%S) ==="; printf '%s\n' "$raw"; } >> "$WORKSPACE/claude.failures.log" 2>/dev/null || true
    ui_warn "claude 응답 오류: $(claude_failure_reason "$raw")"
    return "$(claude_failure_kind "$raw" 0)"
  fi
  printf '%s' "$parsed"
}

# claude_failure_reason <raw json> → 사람이 읽을 한 줄 (사유 없으면 원문 앞부분)
claude_failure_reason() {
  printf '%s' "${1:-}" | python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception:
    print("응답 파싱 불가: " + raw[:160].replace("\n", " ")); raise SystemExit
st = d.get("api_error_status")
msg = str(d.get("result", ""))[:160].replace("\n", " ")
print((f"api_error_status={st} · " if st else "") + (msg or "(사유 없음)"))
' 2>/dev/null || printf '(사유 확인 불가)'
}

# claude_failure_kind <raw json> <rc> → 2 = 일시적 인프라 실패(사용량 한도/네트워크/타임아웃),
#                                        1 = 그 외(모델이 실제로 응답했으나 쓸 수 없음)
#   구분이 필요한 이유: 일시적 실패는 '수정 시도' 가 아니다. 예산을 깎거나 "고치지 못했다" 고
#   보고하면, 사람은 AI 가 무능하다고 오해하고 실제로는 잠시 뒤 재시도하면 될 일을 놓친다.
claude_failure_kind() {
  local raw="${1:-}" rc="${2:-0}"
  [ "$rc" = "124" ] && { printf '2'; return; }   # timeout
  printf '%s' "$raw" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    print(1); raise SystemExit
st = d.get("api_error_status")
msg = str(d.get("result", "")).lower()
transient = st in (429, 500, 502, 503, 504) or "limit" in msg or "overloaded" in msg or "rate" in msg
print(2 if transient else 1)
' 2>/dev/null || printf '1'
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
