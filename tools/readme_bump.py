#!/usr/bin/env python3
"""README 'DALi compatibility' 블록 갱신기 — release.sh 와 selftest.sh 가 공유.

세 개의 순수 함수(부작용은 CLI 진입점에서만):
  - bump_versions(text, ui_tag, core_tag)
      '## Highlights' 이전 블록에서 옛 dali-ui 태그(vX.Y.Z.B)/core 태그(dali_X.Y.Z)와
      그 minor 문자열 쌍을 새 값으로 치환. (기존 release.sh 인라인 fix_readme 를 이관.)
      ※ 2단계 토큰 치환 — 새로 넣은 값이 다른 old 문자열(minor)과 겹쳐 연쇄 치환되는
        사고를 막는다 (실측 버그).
  - get_compat_desc(text)
      dali-ui 호환표 행의 em-dash(—) 뒤 '설명 셀'을 그대로 반환 (Claude 재작성 참고용).
  - replace_compat_desc(text, ui_tag, new_desc)
      ui_tag 를 담은 호환표 행의 설명 셀을 new_desc 로 교체 (코드 적응 릴리스에서만).
      new_desc 가 비었거나 대상 행/구분자가 없으면 원문 그대로 반환(보수적 폴백).

버전 '숫자'만 바꾸던 기존 동작이, 코드 적응(minor) 릴리스에서는 설명 '내용'도
새 dali-ui API 구조에 맞게 갱신되도록 확장한다 (호환표가 새 태그와 어긋나는 것 방지).
"""
import re
import sys

_HL = "## Highlights"
# '**`...tag...`** — <설명> |' 형태의 표 셀에서 설명 부분을 잡는다 (구분자는 EM DASH U+2014).
_DESC_RE = re.compile(r"^(.*?—\s)(.*?)(\s*\|\s*)$")


def _split_head(text):
    cut = text.find(_HL)
    return (text[:cut], text[cut:]) if cut > 0 else (text, "")


def bump_versions(text, ui_tag, core_tag):
    """옛 dali-ui/core 태그 + 그 minor 문자열을 새 값으로 치환 (Highlights 이전 블록만)."""
    head, tail = _split_head(text)
    old_core = re.search(r"dali_\d+\.\d+\.\d+", head)
    old_ui = re.search(r"v\d+\.\d+\.\d+\.\d+", head)
    pairs = []
    if old_ui:
        out = old_ui.group(0)
        pairs.append((out, ui_tag))
        pairs.append((".".join(out[1:].split(".")[:3]), ".".join(ui_tag[1:].split(".")[:3])))
    if old_core:
        oct_ = old_core.group(0)
        pairs.append((oct_, core_tag))
        pairs.append((oct_[len("dali_"):], core_tag[len("dali_"):]))
    pairs.sort(key=lambda p: -len(p[0]))  # 긴 문자열(태그) 먼저 — minor 는 태그의 부분문자열
    for i, (old_s, _) in enumerate(pairs):
        head = head.replace(old_s, f"\x00SUB{i}\x00")
    for i, (_, new_s) in enumerate(pairs):
        head = head.replace(f"\x00SUB{i}\x00", new_s)
    return head + tail


def _desc_row_index(lines, ui_tag):
    """ui_tag 와 em-dash 를 함께 담은 blockquote 표 행의 인덱스 (없으면 -1)."""
    for i, ln in enumerate(lines):
        if ui_tag in ln and ln.lstrip().startswith(">") and "—" in ln and "|" in ln:
            return i
    return -1


def get_compat_desc(text):
    """호환표(Highlights 이전)에서 dali-ui 행의 설명 셀 텍스트를 반환 (없으면 빈 문자열)."""
    head, _ = _split_head(text)
    m = re.search(r"v\d+\.\d+\.\d+\.\d+", head)
    if not m:
        return ""
    lines = head.splitlines()
    i = _desc_row_index(lines, m.group(0))
    if i < 0:
        return ""
    mm = _DESC_RE.match(lines[i])
    return mm.group(2).strip() if mm else ""


def replace_compat_desc(text, ui_tag, new_desc):
    """ui_tag 행의 '— ' 뒤 설명 셀을 new_desc 로 교체. 빈 초안/미발견 시 원문 유지."""
    new_desc = (new_desc or "").strip()
    if not new_desc:
        return text
    lines = text.splitlines(keepends=True)
    i = _desc_row_index(lines, ui_tag)
    if i < 0:
        return text
    ln = lines[i]
    nl = "\n" if ln.endswith("\n") else ""
    m = _DESC_RE.match(ln[: -len(nl)] if nl else ln)
    if not m:
        return text
    lines[i] = m.group(1) + new_desc + " |" + nl
    return "".join(lines)


if __name__ == "__main__":
    # CLI: get-desc <readme>  — release.sh 가 Claude 재작성 프롬프트의 참고 설명으로 사용.
    if len(sys.argv) >= 3 and sys.argv[1] == "get-desc":
        sys.stdout.write(get_compat_desc(open(sys.argv[2]).read()))
        sys.exit(0)
    sys.stderr.write("usage: readme_bump.py get-desc <readme_path>\n")
    sys.exit(2)
