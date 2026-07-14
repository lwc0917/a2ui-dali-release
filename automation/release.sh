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

if [ "$DRY_RUN" = "1" ]; then
  write_release_json dry-run "$OLD" "$NEW" "$BUMP" "DRY_RUN=1 — 파일 미수정, 커밋/태그/push 생략"
  ui_ok "[DRY_RUN] v$NEW 릴리스 예정이었음 (초안: $DRAFT)"
  exit 0
fi

# ── 4파일 범프 ──────────────────────────────────────────────────
python3 - "$REPO" "$OLD" "$NEW" "$DALI_UI_TAG" "$CORE_ADAPTOR_TAG" "$DRAFT" <<'PY'
import re, sys
repo, old, new, ui_tag, core_tag, draft = sys.argv[1:7]

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

# README 호환표: '## Highlights' 이전 블록에서 옛 core 태그(dali_X.Y.Z)와
# 옛 dali-ui 태그(vX.Y.Z.B), 그 minor 문자열 쌍을 새 값으로 치환
def fix_readme(t):
    cut = t.find("## Highlights")
    head, tail = (t[:cut], t[cut:]) if cut > 0 else (t, "")
    old_core = re.search(r"dali_\d+\.\d+\.\d+", head)
    old_ui = re.search(r"v\d+\.\d+\.\d+\.\d+", head)
    if old_core:
        head = head.replace(old_core.group(0), core_tag)
    if old_ui:
        head = head.replace(old_ui.group(0), ui_tag)
        # 산문 속 minor 쌍: "pair dali-ui 2.5.28 with core/adaptor 2.5.29"
        old_ui_minor = ".".join(old_ui.group(0)[1:].split(".")[:3])
        new_ui_minor = ".".join(ui_tag[1:].split(".")[:3])
        head = head.replace(old_ui_minor, new_ui_minor)
    if old_core:
        old_core_minor = old_core.group(0)[len("dali_"):]
        new_core_minor = core_tag[len("dali_"):]
        head = head.replace(old_core_minor, new_core_minor)
    return head + tail
sub_file(f"{repo}/README.md", fix_readme)

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
git tag -a "v$NEW" -m "a2ui-dali $NEW — dali-ui $DALI_UI_TAG rebuild (automated release)"
ui_ok "릴리스 커밋+태그: v$NEW"

ui_step "[release] push → $A2UI_GIT_REMOTE"
if ! net_retry git push origin main || ! net_retry git push origin "v$NEW"; then
  ui_err "push 실패 — ledger 미기록, 다음 주기 재시도"
  write_release_json push-failed "$OLD" "$NEW" "$BUMP" "커밋/태그는 로컬 생성됨, push 실패"
  exit 1
fi

write_release_json released "$OLD" "$NEW" "$BUMP" "커밋+태그 v$NEW push 완료"
ui_ok "릴리스 완료: v$NEW"
