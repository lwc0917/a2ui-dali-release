#!/usr/bin/env python3
"""시각 회귀 수정 프롬프트에 실을 '증거' 블록을 조립한다 (fix.sh visual 전용).

하네스의 핵심 역할: 모델에게 스스로 찾아보라고 시키지 않고, 에이전트가 이미 확보한 근거를
정리해서 먹여준다 — 어떤 샘플이 픽셀상 얼마나 달라졌는지, 비전 판정이 무엇을 훼손으로 봤는지,
원인 분류가 왜 '코드 문제'라고 했는지, 그리고 사람이 보는 것과 똑같은 side-by-side 카드의
경로(모델이 Read 로 직접 이미지를 연다)와 그 샘플의 입력 JSONL.

대상은 triage.json 에서 ``class == "CODE"`` 인 샘플뿐이다. 업스트림 렌더링 변화로 분류된
샘플은 코드로 고칠 대상이 아니라 사람이 골든 갱신을 결정할 대상이므로 프롬프트에 넣지 않는다
(넣으면 모델이 정상 동작을 '고치려' 든다). triage.json 이 없거나 깨졌으면 DAMAGED 전부를
대상으로 되돌아간다 — 근거 없이 조용히 빈 목록을 넘기지 않기 위해서다.

순수 stdlib · 표준출력 전용 · 예외 없음(읽기 실패는 빈 값으로 흡수).
"""

from __future__ import annotations

import json
import os
import sys


def _load(cdir: str, name: str, default):
    try:
        with open(os.path.join(cdir, name), encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, json.JSONDecodeError):
        return default


def build(cdir: str, corpus_dir: str) -> str:
    triage = {t["name"]: t for t in _load(cdir, "triage.json", []) if isinstance(t, dict) and "name" in t}
    verdicts = {v["name"]: v for v in _load(cdir, "verdicts.json", []) if isinstance(v, dict) and "name" in v}
    entries = {e["name"]: e for e in _load(cdir, "compare.json", []) if isinstance(e, dict) and "name" in e}

    targets = sorted(n for n, t in triage.items() if t.get("class") == "CODE")
    if not targets:  # triage 미수행/파싱 불가 → DAMAGED 전체 (조용한 빈 프롬프트 방지)
        targets = sorted(n for n, v in verdicts.items() if v.get("verdict") == "DAMAGED")

    lines: list[str] = []
    for name in targets:
        e, v, t = entries.get(name, {}), verdicts.get(name, {}), triage.get(name, {})
        lines.append(f"- 샘플 `{name}`")
        lines.append(f"  - 픽셀 비교: {e.get('reason', '')} (전역 diff={e.get('diff')})")
        lines.append(f"  - 비전 판정: {v.get('rationale', '')}")
        if t.get("rationale"):
            lines.append(f"  - 원인 분류: {t.get('class')} ({t.get('source')}) — {t['rationale']}")
        card = os.path.join(cdir, "side", f"{name}.side.png")
        if os.path.exists(card):
            lines.append(
                "  - 비교 이미지(Read 로 열어볼 것, 왼=이전 릴리스 / 가운데=새 빌드 / 오른=diff): " + card
            )
        src = os.path.join(corpus_dir, f"{name}.jsonl")
        if os.path.exists(src):
            lines.append(f"  - 이 샘플의 입력 JSONL: {src}")
    return "\n".join(lines)


if __name__ == "__main__":
    print(build(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else ""))
