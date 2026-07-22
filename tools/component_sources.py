#!/usr/bin/env python3
"""증상(어느 샘플이 시각 회귀) → 고쳐야 할 렌더러 소스 파일을 결정적으로 안내한다.

왜 (실측 2026-07-22): 시각 회귀 수정에서 모델은 "무엇이 깨졌나"(픽셀 diff·비전 판정·이미지)는
정확히 진단하는데, "어느 소스가 그걸 그리나"는 아무도 안 알려줘서 엉뚱한 파일을 고쳤다
(podcast 정렬 회귀에서 view-pool.cpp/tabs.cpp 를 건드려 렌더가 소수점까지 안 바뀌었다). 컴파일
에러와 달리 시각 회귀는 위치 단서가 없다. 그런데 a2ui 는 그 매핑이 결정적이다:

  1) 샘플의 컴포넌트 타입은 코퍼스 JSONL 의 "component" 키에 그대로 있다.
  2) 타입 → 렌더 함수 → 소스 파일은 a2ui-renderer.cpp 의 RegisterStandardCatalog() 한 곳에서
     등록된다(레지스트리 = 단일 진실).

그래서 추측 없이: 샘플의 component 타입을 모으고, 레지스트리에서 타입→파일을 파싱해 교집합을
낸다. 정렬/아이콘처럼 '증상별로 늘 봐야 하는' 핵심 파일은 소량의 힌트로 앞에 세운다.

stdlib 만 사용, 예외를 던지지 않는다(정보 조립 실패가 수정 실행을 막으면 안 된다).
"""

from __future__ import annotations

import json
import os
import re
import sys

# 컴포넌트 타입 문자열의 렌더러 소스에 특별히 관계되는 '레이아웃/공통' 파일.
# (타입 매핑으로는 안 잡히지만 시각 회귀의 단골 원인 — 정렬·간격은 컨테이너가 결정한다.)
LAYOUT_SOURCES = [
    "src/renderer/components/flex-container.cpp",  # Row/Column 의 교차축·주축 정렬, AlignSelf
    "src/renderer/render-internal.h",              # 아이템 간격/여백 공통 로직
]


def _catalog(repo: str) -> dict[str, str]:
    """RegisterStandardCatalog() 에서 컴포넌트 타입 → 핸들러 함수명을 파싱한다.

    등록 라인 형태: mRegistry["Image"] = ... RenderImage ... 을 어휘 수준으로 읽는다(정밀 C++
    파서가 아니라, '타입 문자열' 과 '같은 줄에 등장하는 Render<X>' 를 이어붙이는 수준).
    """
    path = os.path.join(repo, "src/renderer/a2ui-renderer.cpp")
    out: dict[str, str] = {}
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return out
    # 등록 라인: mRegistry.Register("Type", [..]{ .. RenderType(..) }); — 한 줄에 타입과 렌더
    # 함수가 함께 있다. Register( 로 시작하는 라인만 보고, 그 안의 "타입" 과 Render<X> 를 잇는다.
    for line in text.splitlines():
        if "Register(" not in line:
            continue
        mt = re.search(r'Register\(\s*"([A-Za-z][A-Za-z0-9]*)"', line)
        mf = re.search(r'\b(Render[A-Za-z0-9]+)\s*\(', line)
        if mt and mf:
            out.setdefault(mt.group(1), mf.group(1))
    return out


def _render_fn_to_file(repo: str, fn: str) -> str | None:
    """핸들러 함수 정의가 있는 components/*.cpp 파일을 찾는다(선언이 아니라 정의)."""
    comp_dir = os.path.join(repo, "src/renderer/components")
    try:
        names = sorted(os.listdir(comp_dir))
    except OSError:
        return None
    pat = re.compile(r'\b' + re.escape(fn) + r'\s*\(')
    for name in names:
        if not name.endswith(".cpp"):
            continue
        p = os.path.join(comp_dir, name)
        try:
            if pat.search(open(p, encoding="utf-8", errors="replace").read()):
                return f"src/renderer/components/{name}"
        except OSError:
            continue
    return None


def sample_component_types(corpus_jsonl: str) -> list[str]:
    """코퍼스 JSONL 에서 이 샘플이 쓰는 컴포넌트 타입 집합(등장 순서 보존)."""
    types: list[str] = []
    seen: set[str] = set()
    try:
        lines = open(corpus_jsonl, encoding="utf-8", errors="replace").read().splitlines()
    except OSError:
        return types

    def walk(node):
        if isinstance(node, dict):
            t = node.get("component") or node.get("type")
            if isinstance(t, str) and t[:1].isupper() and t not in seen:
                seen.add(t)
                types.append(t)
            for v in node.values():
                walk(v)
        elif isinstance(node, list):
            for v in node:
                walk(v)

    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            walk(json.loads(line))
        except json.JSONDecodeError:
            continue
    return types


def sources_for_sample(repo: str, corpus_dir: str, sample: str) -> list[str]:
    """이 샘플의 시각 회귀를 고칠 때 읽어야 할 소스 파일(중요도 순, 중복 제거)."""
    jsonl = os.path.join(corpus_dir, f"{sample}.jsonl")
    types = sample_component_types(jsonl)
    catalog = _catalog(repo)
    files: list[str] = []

    def add(f):
        if f and f not in files and os.path.exists(os.path.join(repo, f)):
            files.append(f)

    # 1) 이 샘플이 쓰는 컴포넌트의 핸들러 파일
    for t in types:
        fn = catalog.get(t)
        if fn:
            add(_render_fn_to_file(repo, fn))
    # 2) 레이아웃/공통 (정렬·간격은 컨테이너가 결정 — 시각 회귀의 단골)
    for f in LAYOUT_SOURCES:
        add(f)
    return files


def render_hint(repo: str, corpus_dir: str, samples: list[str]) -> str:
    """수정 프롬프트에 실을 '어디를 볼지' 블록. 샘플별로 후보 소스를 나열한다."""
    lines: list[str] = []
    for s in samples:
        files = sources_for_sample(repo, corpus_dir, s)
        types = sample_component_types(os.path.join(corpus_dir, f"{s}.jsonl"))
        lines.append(f"- `{s}` 이 쓰는 컴포넌트: {', '.join(types) or '(파싱 실패)'}")
        if files:
            lines.append("  이 증상을 그리는 렌더러 소스(여기부터 Read/Grep 으로 원인을 찾으세요):")
            for f in files:
                lines.append(f"    - {f}")
    return "\n".join(lines)


if __name__ == "__main__":
    if len(sys.argv) < 4:
        print("usage: component_sources.py <repo> <corpus_dir> <sample>...", file=sys.stderr)
        sys.exit(2)
    print(render_hint(sys.argv[1], sys.argv[2], sys.argv[3:]))
