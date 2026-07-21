#!/bin/bash
# release.sh — GREEN 게이트 후 완전 자동 릴리스.
# 버전: 코드 적응 있으면 minor, 순수 리빌드면 patch.
# 4파일 범프(CMakeLists/spec/README 호환표/CHANGELOG) → 커밋(사용자 author) → 태그 → push.
# 멱등: origin/main 이 이미 이 dali-ui 태그 기준이거나 릴리스 태그가 이미 있으면 생략.
# DRY_RUN=1: 계획만 산출(레포 파일 미수정, push 없음).
# 요구 env: DALI_UI_TAG, CORE_ADAPTOR_TAG, RUNDIR
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/automation/lib/load_env.sh"
source "$ROOT/automation/lib/ui.sh"
source "$ROOT/automation/lib/net.sh"
source "$ROOT/automation/lib/claude.sh"

REPO="$SRC/a2ui-dali"
: "${DALI_UI_TAG:?}" "${CORE_ADAPTOR_TAG:?}" "${RUNDIR:?}"
REL_JSON="$RUNDIR/release.json"

write_release_json() { # $1=status $2=old $3=new $4=bump $5=note
  python3 -c '
import json, sys
json.dump({"status": sys.argv[2], "old_version": sys.argv[3], "new_version": sys.argv[4],
           "bump": sys.argv[5], "note": sys.argv[6]}, open(sys.argv[1], "w"),
          indent=1, ensure_ascii=False)
' "$REL_JSON" "$@"
}

ui_step "[release] 릴리스 준비 (dali-ui $DALI_UI_TAG)"
export GIT_AUTHOR_NAME="$GIT_RELEASE_NAME" GIT_AUTHOR_EMAIL="$GIT_RELEASE_EMAIL" \
       GIT_COMMITTER_NAME="$GIT_RELEASE_NAME" GIT_COMMITTER_EMAIL="$GIT_RELEASE_EMAIL"

net_retry git -C "$REPO" fetch --tags --force origin || { ui_err "fetch 실패"; exit 1; }

# SKIP_IDEMPOTENCY=1 (리허설 전용, DRY_RUN 과 함께만 의미): 이미 릴리스된 태그로도
# 버전 계산/CHANGELOG 초안 경로를 연습할 수 있게 멱등 가드를 건너뜀.
: "${SKIP_IDEMPOTENCY:=0}"

# 멱등 가드 1: origin/main 이 이미 이 dali-ui 태그로 릴리스됨 (ledger 유실 재실행 대비)
if [ "$SKIP_IDEMPOTENCY" != "1" ] \
  && git -C "$REPO" show origin/main:README.md 2>/dev/null | grep -qF "$DALI_UI_TAG"; then
  OLD=$(git -C "$REPO" show origin/main:CMakeLists.txt | python3 -c '
import re, sys
m = re.search(r"PROJECT\s*\([^)]*?VERSION\s+([0-9]+\.[0-9]+\.[0-9]+)", sys.stdin.read(), re.S | re.I)
print(m.group(1) if m else "?")
')
  write_release_json skipped "$OLD" "$OLD" none "origin/main 이 이미 $DALI_UI_TAG 기준 — 릴리스 생략(멱등)"
  ui_ok "origin/main 이 이미 $DALI_UI_TAG 기준 — 릴리스 생략(멱등)"
  exit 0
fi

# stale 가드: 적응 수정은 워킹트리에만 있어야 하고 HEAD 는 origin/main 과 일치해야 함
if [ "$(git -C "$REPO" rev-parse HEAD)" != "$(git -C "$REPO" rev-parse origin/main)" ]; then
  ui_err "origin/main 이 실행 중 이동 — 이번 주기 중단, 다음 주기 재시도"
  exit 1
fi

CODE_CHANGED=0
[ -n "$(git -C "$REPO" status --porcelain -- src)" ] && CODE_CHANGED=1

# PROJECT(...) 블록의 VERSION 만 — 1행 CMAKE_MINIMUM_REQUIRED(VERSION 3.x) 오인 방지
OLD=$(python3 -c '
import re, sys
t = open(sys.argv[1]).read()
m = re.search(r"PROJECT\s*\([^)]*?VERSION\s+([0-9]+\.[0-9]+\.[0-9]+)", t, re.S | re.I)
print(m.group(1) if m else "")
' "$REPO/CMakeLists.txt")
[ -n "$OLD" ] || { ui_err "현재 버전 파싱 실패 (CMakeLists.txt PROJECT VERSION)"; exit 1; }
IFS=. read -r VA VB VC <<<"$OLD"
if [ "$CODE_CHANGED" = 1 ]; then
  NEW="$VA.$((VB + 1)).0" BUMP=minor
else
  NEW="$VA.$VB.$((VC + 1))" BUMP=patch
fi
ui_info "버전: $OLD → $NEW ($BUMP, 코드변경=$CODE_CHANGED)"

# 멱등 가드 2: 릴리스 태그가 이미 원격에 존재
if [ "$SKIP_IDEMPOTENCY" != "1" ] \
  && [ -n "$(git -C "$REPO" ls-remote --tags origin "refs/tags/v$NEW")" ]; then
  write_release_json skipped "$OLD" "$NEW" "$BUMP" "v$NEW 태그가 이미 원격에 존재 — 생략(멱등)"
  ui_ok "v$NEW 이미 존재 — 릴리스 생략(멱등)"
  exit 0
fi

CONF=$(cat "$RUNDIR/conformance.txt" 2>/dev/null || echo "n/a")

# CHANGELOG 본문 초안 — Claude(Read 전용, 실패 시 결정론 폴백). 파일 기록은 오케스트레이터.
DRAFT="$RUNDIR/changelog_draft.md"
if [ "$CODE_CHANGED" = 1 ]; then
  DIFF_SUMMARY=$(git -C "$REPO" diff --stat | tail -20; git -C "$REPO" diff -- src | head -200)
  PROMPT="a2ui-dali 를 새 dali-ui $DALI_UI_TAG 에 적응시킨 아래 diff 를 보고, CHANGELOG 의 '### Changed' 섹션에 넣을 마크다운 불릿 2~5개를 영어로 작성하세요. 과장 금지 — diff 에 실제로 있는 변경만. 불릿 텍스트만 출력하세요.

$DIFF_SUMMARY"
  BODY=$(claude_call "$REPO" "Read Grep Glob" "$PROMPT") || BODY=""
  [ -n "$BODY" ] || BODY="- Adapt renderer sources to the reorganized dali-ui \`$DALI_UI_TAG\` API (automated port)."
else
  BODY="- Rebuild against dali-ui \`$DALI_UI_TAG\` — no renderer source changes required."
fi
cat >"$DRAFT" <<EOF
## [$NEW] — $(date +%F)

Automated release tracking **dali-ui $DALI_UI_TAG** (with \`dali2-core\` / \`dali2-adaptor\` \`$CORE_ADAPTOR_TAG\`).

### Changed

$BODY

### Compatibility

- Built against \`dali-ui $DALI_UI_TAG\` with \`dali2-core\`/\`dali2-adaptor\` \`$CORE_ADAPTOR_TAG\` on the
  desktop \`dali-env\` build. Gallery corpus verified against the previous release
  (pixel-regression gate + visual judge). Conformance: $CONF.
EOF

# README 호환표 '설명 셀' 재작성 초안 — 코드 적응(minor) 시에만.
# 옛 dali-ui API 구조 서술이 새 태그와 어긋나지 않도록 Claude(Read 전용)로 갱신.
# 호출 실패/빈 응답 → 빈 초안 → 원문 설명 유지(보수적 폴백, replace_compat_desc 가 처리).
COMPAT_DRAFT="$RUNDIR/readme_compat_draft.txt"
: >"$COMPAT_DRAFT"
if [ "$CODE_CHANGED" = 1 ]; then
  OLD_DESC=$(python3 "$ROOT/tools/readme_bump.py" get-desc "$REPO/README.md" 2>/dev/null || true)
  CPROMPT="a2ui-dali README 의 'DALi compatibility' 표에는 이 릴리스가 빌드된 dali-ui API 표면을 한 구절로 설명하는 셀이 있습니다. 코드가 새 dali-ui \`$DALI_UI_TAG\` 에 맞춰 적응되었습니다. src/ 의 실제 #include 헤더 경로와 참조 네임스페이스만 근거로 그 설명 셀을 갱신한 '한 줄' 영어 구절을 출력하세요. 규칙: (1) 기존 스타일 유지 — 경로/네임스페이스는 백틱, 표 셀 1줄, (2) 과장·추측 금지 — src/ 에 실제로 있는 것만, 확신 없으면 기존 설명을 보수적으로 유지, (3) 표 파이프(|)·줄바꿈·머리말 없이 구절 텍스트만.

현재 설명(참고): $OLD_DESC"
  DESC=$(claude_call "$REPO" "Read Grep Glob" "$CPROMPT") || DESC=""
  # 정규화: 모델이 '한 줄만' 이라는 지시를 어기고 근거 표까지 덧붙이는 일이 실측으로 확인됐다
  # (1,100자 블롭 + 마크다운 표). 예전 정규화는 개행을 공백으로 바꾸기만 해서 그 블롭이 통째로
  # README 표 셀에 들어갈 수 있었다. 그래서 (1) 첫 번째 의미 있는 줄만 취하고, (2) 파이프 제거,
  # (3) 길이 상한을 넘거나 표/머리말 흔적이 있으면 초안을 폐기해 원문 설명을 유지한다(보수 폴백).
  DESC=$(printf '%s' "$DESC" | sed 's/\r$//' | grep -v '^[[:space:]]*$' | head -1 |
    tr '|' ' ' | sed 's/^[[:space:]]*[-*#>][[:space:]]*//; s/  */ /g; s/^ *//; s/ *$//')
  if [ ${#DESC} -gt "${COMPAT_DESC_MAX:-200}" ]; then
    ui_warn "README 설명 초안이 상한(${COMPAT_DESC_MAX:-200}자)을 초과 (${#DESC}자) — 폐기하고 원문 유지"
    DESC=""
  fi
  [ -n "$DESC" ] && printf '%s' "$DESC" >"$COMPAT_DRAFT"
  if [ -s "$COMPAT_DRAFT" ]; then ui_info "README 설명 셀 갱신 초안 준비됨"; else ui_info "README 설명 갱신 없음 — 원문 유지"; fi
fi

if [ "$DRY_RUN" = "1" ]; then
  write_release_json dry-run "$OLD" "$NEW" "$BUMP" "DRY_RUN=1 — 파일 미수정, 커밋/태그/push 생략"
  ui_ok "[DRY_RUN] v$NEW 릴리스 예정이었음 (초안: $DRAFT)"
  exit 0
fi

# ── 4파일 범프 ──────────────────────────────────────────────────
python3 - "$REPO" "$OLD" "$NEW" "$DALI_UI_TAG" "$CORE_ADAPTOR_TAG" "$DRAFT" "$ROOT/tools" "$COMPAT_DRAFT" <<'PY'
import os, re, sys
repo, old, new, ui_tag, core_tag, draft, tools_dir, compat_draft = sys.argv[1:9]
sys.path.insert(0, tools_dir)
import readme_bump

def sub_file(path, fn):
    with open(path) as f:
        text = f.read()
    text = fn(text)
    with open(path, "w") as f:
        f.write(text)

# CMakeLists.txt: VERSION x.y.z (첫 등장만)
sub_file(f"{repo}/CMakeLists.txt",
         lambda t: t.replace(f"VERSION {old}", f"VERSION {new}", 1))

# spec: Version: 줄
sub_file(f"{repo}/packaging/a2ui-dali.spec",
         lambda t: re.sub(r"(?m)^Version:\s*\S+", f"Version:    {new}", t, count=1))

# README 호환표: 버전 범프(항상) + 코드 적응 시 설명 셀 재작성(초안 있을 때만).
# 순수 변환은 tools/readme_bump.py 로 이관 — selftest 가 동일 함수로 회귀 검증한다.
# (버전 '숫자'뿐 아니라, 코드가 바뀐 릴리스에선 dali-ui API 구조 '설명'도 새 태그에 맞춰 갱신.)
readme_desc = ""
if os.path.exists(compat_draft):
    readme_desc = open(compat_draft).read().strip()
def edit_readme(t):
    t = readme_bump.bump_versions(t, ui_tag, core_tag)
    return readme_bump.replace_compat_desc(t, ui_tag, readme_desc)
sub_file(f"{repo}/README.md", edit_readme)

# CHANGELOG: 첫 '## [' 섹션 앞에 초안 삽입
entry = open(draft).read().rstrip() + "\n\n"
def fix_changelog(t):
    m = re.search(r"(?m)^## \[", t)
    pos = m.start() if m else len(t)
    return t[:pos] + entry + t[pos:]
sub_file(f"{repo}/CHANGELOG.md", fix_changelog)
PY
[ $? -eq 0 ] || { ui_err "릴리스 파일 편집 실패"; exit 1; }

# ── 커밋 / 태그 / push ─────────────────────────────────────────
cd "$REPO"
if [ "$CODE_CHANGED" = 1 ]; then
  git add src
  git commit -q -m "Adapt renderer to dali-ui $DALI_UI_TAG" || { ui_err "적응 커밋 실패"; exit 1; }
  ui_ok "적응 커밋: $(git log -1 --format=%h)"
fi
git add CMakeLists.txt packaging/a2ui-dali.spec README.md CHANGELOG.md
git commit -q -m "Release $NEW" || { ui_err "릴리스 커밋 실패"; exit 1; }
# 이전 실패로 남은 로컬 태그가 orphan 커밋을 가리킬 수 있음 → 새 커밋에 다시 달기 전 제거.
git tag -d "v$NEW" >/dev/null 2>&1 || true
git tag -a "v$NEW" -m "a2ui-dali $NEW — dali-ui $DALI_UI_TAG rebuild (automated release)" \
  || { ui_err "태그 생성 실패: v$NEW"; exit 1; }
ui_ok "릴리스 커밋+태그: v$NEW"

ui_step "[release] push → $A2UI_GIT_REMOTE"
# 원자적 push — main 과 태그가 함께 반영되거나 함께 실패(태그없는/부분 릴리스 방지).
if ! net_retry git push --atomic origin main "v$NEW"; then
  ui_err "push 실패 — ledger 미기록, 다음 주기 재시도"
  write_release_json push-failed "$OLD" "$NEW" "$BUMP" "커밋/태그는 로컬 생성됨, push 실패"
  exit 1
fi

write_release_json released "$OLD" "$NEW" "$BUMP" "커밋+태그 v$NEW push 완료"
ui_ok "릴리스 완료: v$NEW"
