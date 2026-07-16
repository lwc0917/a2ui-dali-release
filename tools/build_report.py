#!/usr/bin/env python3
"""build_report.py — hub 표시용 최종 리포트(last_report.md) + artifacts 갤러리 생성.

- 리포트는 한국어, 최상단 TL;DR (사용자 표준 규칙).
- 이미지는 $AGENTHUB_RUN_DIR/artifacts/ 로 복사 + index.json (hub 확장이 렌더).
  index.json: {"sections":[{"title":str,"items":[{"file":basename,"caption":str}]}]}
"""
import argparse
import glob
import json
import os
import shutil
import sys
from datetime import date

TITLES = {
    "success":      ("a2ui-dali 자동 릴리스 — 성공 ✅", 0),
    "dry-run":      ("a2ui-dali 자동 릴리스 — DRY RUN ☑️", 0),
    "skipped":      ("a2ui-dali 자동 릴리스 — 생략(멱등) ✅", 0),
    "bootstrap":    ("a2ui-dali-release — baseline 구축 완료 ✅", 0),
    "no-op":        ("a2ui-dali 자동 릴리스 — 변경 없음 (no-op)", 0),
    "gate-damage":  ("a2ui-dali 자동 릴리스 — 게이트 RED, 릴리스 보류 ⛔", 1),
    "build-break":  ("a2ui-dali 자동 릴리스 — 빌드 적응 실패 ⛔", 1),
    "conformance":  ("a2ui-dali 자동 릴리스 — conformance 실패 ⛔", 1),
    "render":       ("a2ui-dali 자동 릴리스 — 렌더 실패 ⛔", 1),
    "infra":        ("a2ui-dali 자동 릴리스 — 인프라 오류 ⛔", 1),
    "release-push": ("a2ui-dali 자동 릴리스 — push 실패 ⛔", 1),
}


def read_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return default


def read_text(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except FileNotFoundError:
        return ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--outcome", required=True)
    ap.add_argument("--detail", default="")
    ap.add_argument("--rundir", required=True)
    ap.add_argument("--artifacts", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--diagnosis", default="")
    args = ap.parse_args()

    rd = args.rundir
    title, _ = TITLES.get(args.outcome, (f"a2ui-dali 자동 릴리스 — {args.outcome}", 1))

    target = {}
    for line in read_text(os.path.join(rd, ".target")).splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            target[k] = v
    compare = read_json(os.path.join(rd, "compare", "compare.json"), [])
    verdicts = {v["name"]: v for v in read_json(os.path.join(rd, "compare", "verdicts.json"), [])}
    release = read_json(os.path.join(rd, "release.json"), {})
    conf = read_text(os.path.join(rd, "conformance.txt")) or "n/a"
    fix_n = read_text(os.path.join(rd, ".fix_attempts")) or "0"
    diagnosis = read_text(args.diagnosis) if args.diagnosis else ""

    n_pass = sum(1 for e in compare if e["status"] == "PASS")
    reviews = [e for e in compare if e["status"] != "PASS"]
    damaged = [e for e in reviews if verdicts.get(e["name"], {}).get("verdict") == "DAMAGED"]
    accepted = [e for e in reviews if verdicts.get(e["name"], {}).get("verdict") == "ACCEPTABLE"]

    ui_tag = target.get("DALI_UI_TAG", "?")
    core_tag = target.get("CORE_ADAPTOR_TAG", "?")

    # ── TL;DR ──
    if args.outcome == "success":
        tldr = (f"dali-ui **{ui_tag}** 대응 재빌드·검증 후 a2ui-dali "
                f"**v{release.get('old_version','?')} → v{release.get('new_version','?')}** "
                f"({release.get('bump','?')}) 자동 릴리스 완료. "
                f"게이트: PASS {n_pass}/{len(compare)}"
                + (f", 허용 드리프트 {len(accepted)}건" if accepted else "") + ".")
    elif args.outcome == "dry-run":
        tldr = (f"DRY RUN — dali-ui **{ui_tag}** 기준 전 파이프라인 GREEN. "
                f"실제였다면 v{release.get('new_version','?')} ({release.get('bump','?')}) 릴리스.")
    elif args.outcome == "skipped":
        tldr = f"dali-ui **{ui_tag}** 은 이미 릴리스에 반영됨 — 멱등 생략. ({release.get('note','')})"
    elif args.outcome == "bootstrap":
        tldr = f"최초 baseline 구축 완료 — {args.detail}"
    elif args.outcome == "no-op":
        tldr = "새 dali-ui 릴리스 태그 없음 — 할 일 없음."
    elif args.outcome == "gate-damage":
        names = ", ".join(e["name"] for e in damaged) or "?"
        tldr = (f"dali-ui **{ui_tag}** 빌드는 성공했으나 시각 게이트 RED — "
                f"**{names}** 손상 판정으로 릴리스 보류. 사람 확인 필요.")
        # Golden-candidate markers (hub golden review): the run page surfaces each damaged
        # sample's baseline|new|diff card (<name>.side.png, staged into artifacts/ below) so a
        # human can approve the candidate as the new golden — a force_accept re-run then releases
        # and rotates the baseline. One marker per damaged sample; the hub greps these from the log.
        for e in damaged:
            print(f"[golden-candidate] {e['name']}")
    else:
        tldr = f"dali-ui **{ui_tag}** 처리 중 실패({args.outcome}) — {args.detail}"

    lines = [f"## {title}", "", f"**한 줄 요약:** {tldr}", ""]

    # ── 좌표 ──
    if args.outcome != "no-op":
        lines += ["### 좌표", "",
                  f"- dali-core/adaptor: `{core_tag}` · dali-ui: `{ui_tag}`"]
        if release.get("new_version"):
            lines.append(f"- a2ui-dali: v{release.get('old_version','?')} → "
                         f"**v{release['new_version']}** ({release.get('bump','?')}) · "
                         f"상태: {release.get('status','?')}")
        lines.append(f"- Conformance: {conf} · Claude 코드수정 시도: {fix_n}회")
        gate_env = {}
        for line in read_text(os.path.join(rd, "gate.env")).splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                gate_env[k] = v
        if gate_env:
            lines.append(f"- 게이트 강도: **{gate_env.get('GATE_LEVEL', 'normal')}** "
                         f"(픽셀 임계 {gate_env.get('DIFF_THRESHOLD', '?')})")
        lines.append("")

    # ── 게이트 ──
    if compare:
        lines += ["### 게이트 (baseline 대비 픽셀 회귀 + 시각 판정)", "",
                  f"- PASS {n_pass} · REVIEW {len(reviews)} "
                  f"(허용 {len(accepted)} / 손상 {len(damaged)})", ""]
        for e in reviews:
            v = verdicts.get(e["name"], {})
            lines.append(f"  - `{e['name']}` — {e['reason']} → "
                         f"**{v.get('verdict','미판정')}** {v.get('rationale','')}")
        if reviews:
            lines.append("")

    # ── 진단 ──
    if diagnosis:
        lines += ["### 진단 (Claude)", "", diagnosis, ""]

    if args.outcome not in ("no-op",):
        lines += ["", "_결과 이미지: 아래 갤러리 (요약 시트 + 변경/손상 샘플 side-by-side)._"]

    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    with open(args.out, "w") as f:
        f.write("\n".join(lines) + "\n")

    # ── artifacts 복사 + index.json ──
    os.makedirs(args.artifacts, exist_ok=True)
    sections = []
    sheet = os.path.join(rd, "compare", "gallery_sheet.png")
    if os.path.exists(sheet):
        shutil.copy(sheet, os.path.join(args.artifacts, "gallery_sheet.png"))
        sections.append({"title": "갤러리 요약 시트",
                         "items": [{"file": "gallery_sheet.png",
                                    "caption": f"전체 {len(compare)}종 렌더 (new 기준)"}]})
    items = []
    for e in reviews:
        if not e.get("card"):
            continue
        src = os.path.join(rd, "compare", e["card"])
        if not os.path.exists(src):
            continue
        fn = os.path.basename(e["card"])
        shutil.copy(src, os.path.join(args.artifacts, fn))
        v = verdicts.get(e["name"], {})
        items.append({"file": fn,
                      "caption": f"{e['name']} · {e['reason']} · "
                                 f"판정 {v.get('verdict','미판정')}"})
    if items:
        sections.append({"title": "변경/손상 샘플 (baseline | new | diff)", "items": items})

    # 성공 계열: 개별 렌더 전수 — 사람이 hub 에서 샘플별로 '잘 그려졌는지' 직접 확인
    if args.outcome in ("success", "dry-run", "skipped", "bootstrap"):
        singles = []
        for p in sorted(glob.glob(os.path.join(rd, "new", "*.png"))):
            name = os.path.splitext(os.path.basename(p))[0]
            fn = "render_" + os.path.basename(p)
            shutil.copy(p, os.path.join(args.artifacts, fn))
            e = next((x for x in compare if x["name"] == name), None)
            cap = name
            if e and e.get("diff") is not None:
                cap += f" · diff={e['diff']:.3f}"
            if e and e["status"] != "PASS":
                cap += f" · {verdicts.get(name, {}).get('verdict', 'REVIEW')}"
            singles.append({"file": fn, "caption": cap})
        if singles:
            sections.append({"title": f"전체 샘플 개별 렌더 ({len(singles)}종)",
                             "items": singles})

    if sections:
        with open(os.path.join(args.artifacts, "index.json"), "w") as f:
            json.dump({"sections": sections}, f, indent=1, ensure_ascii=False)

    print(f"report: {args.out} + {len(sections)} artifact section(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
