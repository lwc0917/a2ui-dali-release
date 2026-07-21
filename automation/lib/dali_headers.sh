# dali_headers.sh — dali-ui 의 '진짜 헤더' + 버전 델타를 AI 에게 쥐어주는 조달기.
#   (dali-preview-runtime-release/automation/lib/headers.sh 와 동일 로직 — 세 에이전트 공통 패턴)
#
# 왜 필요한가 (실측 2026-07-21):
#   ai_fix_baked 의 프롬프트는 "헤더에서 확인하라, 없는 심볼을 지어내지 말라" 고 지시하는데,
#   정작 헤더는 docker 이미지 안(/opt/dali/include)에 있고 모델에게 준 도구는 Edit,Read 뿐이라
#   검색도 열람도 불가능했다. 그 상태에서 dali-ui 2.5.30 이 Label::SetMarkupEnabled 를 없애자
#   모델은 Property::MARKUP_ENABLED 를 찍어보다 실패하고 결국 마크업 처리를 통째로 삭제했다.
#   그런데 실제로는 대체 API 가 멀쩡히 존재했다 — StyledText::FromMarkup() + Label::SetStyledText().
#   즉 모델의 판단력 문제가 아니라 하네스가 증거를 주지 않은 문제였다.
#
# 출처는 격리 스택이 빌드에 쓰는 것과 '동일한' 소스 tarball 이다(같은 태그) — 이미지에서
# 헤더를 꺼내오는 것보다 단순하고, 빌드 실패로 이미지가 없어도 동작하며, 버전이 정확히 일치한다.
# 네트워크가 없으면 조용히 빈 손으로 돌아간다(호출부가 '헤더 없음'으로 처리 — 실패시키지 않는다).

# dali_ui_headers_fetch <tag> <destdir> → rc0 이면 destdir 에 헤더 트리 존재
#   캐시: destdir 에 이미 .h 가 있으면 재다운로드하지 않는다.
dali_ui_headers_fetch() {
  local tag="${1:?tag}" dest="${2:?dest}" tgz rc
  if [ -d "$dest" ] && [ -n "$(find "$dest" -name '*.h' -print -quit 2>/dev/null)" ]; then
    return 0   # 캐시 히트
  fi
  mkdir -p "$dest" || return 1
  tgz="$(mktemp "${TMPDIR:-/tmp}/dali-ui-hdr.XXXXXX.tgz")"
  curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 180 \
    "https://github.com/dalihub/dali-ui/archive/${tag}.tar.gz" -o "$tgz" 2>/dev/null
  rc=$?
  if [ $rc -ne 0 ] || [ ! -s "$tgz" ]; then
    rm -f "$tgz"
    return 1
  fi
  # 공개 API 표면만 — 헤더와, 시그니처 확인에 도움이 되는 public-api 구현부까지.
  tar xzf "$tgz" -C "$dest" --strip-components=1 \
      --wildcards '*/dali-ui-foundation/public-api/*' '*/dali-ui-components/public-api/*' 2>/dev/null \
    || tar xzf "$tgz" -C "$dest" --strip-components=1 2>/dev/null
  rc=$?
  rm -f "$tgz"
  [ $rc -eq 0 ] && [ -n "$(find "$dest" -name '*.h' -print -quit 2>/dev/null)" ]
}

# dali_ui_headers_symbol_blob <headers_dir> <out_file> → 환각 pre-filter 용 심볼 덩어리
#   _symbols_missing_against 는 "이 파일에 해당 심볼 단어가 있는가" 로만 검사하므로,
#   헤더 전문을 한 파일로 이어붙이면 그대로 쓸 수 있다.
dali_ui_headers_symbol_blob() {
  local dir="${1:?dir}" out="${2:?out}"
  : >"$out" || return 1
  find "$dir" -name '*.h' -print0 2>/dev/null | xargs -0 -r cat >>"$out" 2>/dev/null
  [ -s "$out" ]
}

# ── 업스트림 델타 (구버전 → 신버전) ───────────────────────────────────────────
# "무엇이 사라졌나" 보다 "무엇으로 바뀌었나" 가 마이그레이션의 핵심 증거다. 실측(thorvg):
# 업스트림이 offTween() 을 지우면서 자기 호출부를 tween.off() 로 전부 고쳐놨고, 그 코드가
# 바로 옆에 있었기 때문에 모델이 44초 만에 정답을 냈다. 반대로 dali-preview 는 '사라졌다'만
# 알 수 있었고 대체 API 를 못 찾아 기능을 삭제했다. 그래서 두 버전의 공개 헤더 diff 와
# 사라진/새로 생긴 심볼 목록을 결정적으로 만들어 프롬프트에 함께 준다.
#
# dali_ui_headers_delta <old_tag> <new_tag> <destdir> → rc0 이면 destdir 에 산출물
#   headers.diff        : 공개 헤더 unified diff (old → new)
#   removed-symbols.txt : old 에만 있던 심볼 (= 마이그레이션 대상)
#   added-symbols.txt   : new 에만 있는 심볼 (= 대체 후보가 여기 있다)
dali_ui_headers_delta() {
  local old="${1:?old tag}" new="${2:?new tag}" dest="${3:?dest}" base
  base="$(dirname "$dest")"
  local odir="$base/$old" ndir="$base/$new"
  dali_ui_headers_fetch "$old" "$odir" || return 1
  dali_ui_headers_fetch "$new" "$ndir" || return 1
  mkdir -p "$dest" || return 1
  ( cd "$base" && diff -ruN --label "$old" --label "$new" "$old" "$new" ) >"$dest/headers.diff" 2>/dev/null
  OLD_DIR="$odir" NEW_DIR="$ndir" DEST="$dest" python3 <<'PY'
import os, re, pathlib
# 헤더에서 '호출 가능한 이름' 을 뽑는다. 정밀 파서가 아니라 의도적으로 단순한 어휘 수준 —
# 목적은 "이 이름이 신버전에 남아있나" 를 사람이 한눈에 보게 하는 것이지 C++ 파싱이 아니다.
DECL = re.compile(r'\b([A-Z][A-Za-z0-9_]*)\s*\(')          # 메서드/타입 호출 형태
ENUMC = re.compile(r'^\s*([A-Z][A-Z0-9_]{2,})\s*[,=]')      # 열거형/상수 (MARKUP_ENABLED 류)
def syms(root):
    out = set()
    for p in pathlib.Path(root).rglob("*.h"):
        try:
            txt = p.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for line in txt.splitlines():
            s = line.split("//")[0]
            out.update(DECL.findall(s))
            m = ENUMC.match(s)
            if m:
                out.add(m.group(1))
    return out
old, new, dest = syms(os.environ["OLD_DIR"]), syms(os.environ["NEW_DIR"]), os.environ["DEST"]
open(os.path.join(dest, "removed-symbols.txt"), "w").write("\n".join(sorted(old - new)) + "\n")
open(os.path.join(dest, "added-symbols.txt"), "w").write("\n".join(sorted(new - old)) + "\n")
PY
  [ -s "$dest/headers.diff" ] || [ -s "$dest/removed-symbols.txt" ]
}
