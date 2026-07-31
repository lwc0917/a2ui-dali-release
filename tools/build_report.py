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
    # 우리 코드 문제가 아니라 업스트림 태그끼리 안 맞는 경우 — 사람이 고칠 게 없고
    # 새 core/adaptor 태그를 기다리면 된다는 걸 제목에서 바로 구분되게 한다.
    "upstream-mismatch": ("a2ui-dali 자동 릴리스 — 업스트림 태그 비호환 ⏸", 1),
    "llm-unavailable": ("a2ui-dali 자동 릴리스 — LLM 호출 불가로 중단 ⏸", 1),
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
    # 원인 분류(triage.sh): 훼손 샘플이 '코드 버그'인지 '업스트림 렌더링 변화'인지.
    triage = {t["name"]: t for t in read_json(os.path.join(rd, "compare", "triage.json"), [])
              if isinstance(t, dict) and "name" in t}
    # AI 가 시각 회귀를 고친 run 은 재검증이 compare/ 를 전부 PASS 로 덮어쓴다. 수정 전
    # 스냅샷(fix.sh visual 이 남김)이 있으면 '무엇이 깨져 있었고 무엇을 고쳤는지'를 보고한다 —
    # 없으면 리포트가 '손상 0'만 보여서 깨끗한 재빌드와 구분되지 않는다.
    pre_dir = os.path.join(rd, "compare_pre_fix")
    pre_compare = read_json(os.path.join(pre_dir, "compare.json"), [])
    pre_verdicts = {v["name"]: v for v in read_json(os.path.join(pre_dir, "verdicts.json"), [])
                    if isinstance(v, dict) and "name" in v}
    pre_triage = {t["name"]: t for t in read_json(os.path.join(pre_dir, "triage.json"), [])
                  if isinstance(t, dict) and "name" in t}
    pre_damaged = [e for e in pre_compare
                   if pre_verdicts.get(e.get("name"), {}).get("verdict") == "DAMAGED"]
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
    ai_fixed = (f" 시각 회귀 {len(pre_damaged)}건(" +
                ", ".join(e["name"] for e in pre_damaged) +
                f")은 AI 가 코드로 수정 후 게이트 재통과(시도 {fix_n}회)." ) if pre_damaged else ""
    if args.outcome == "success":
        tldr = (f"dali-ui **{ui_tag}** 대응 재빌드·검증 후 a2ui-dali "
                f"**v{release.get('old_version','?')} → v{release.get('new_version','?')}** "
                f"({release.get('bump','?')}) 자동 릴리스 완료. "
                f"게이트: PASS {n_pass}/{len(compare)}"
                + (f", 허용 드리프트 {len(accepted)}건" if accepted else "") + "." + ai_fixed)
    elif args.outcome == "dry-run":
        tldr = (f"DRY RUN — dali-ui **{ui_tag}** 기준 전 파이프라인 GREEN. "
                f"실제였다면 v{release.get('new_version','?')} ({release.get('bump','?')}) 릴리스."
                + ai_fixed)
    elif args.outcome == "skipped":
        tldr = f"dali-ui **{ui_tag}** 은 이미 릴리스에 반영됨 — 멱등 생략. ({release.get('note','')})"
    elif args.outcome == "bootstrap":
        tldr = f"최초 baseline 구축 완료 — {args.detail}"
    elif args.outcome == "no-op":
        tldr = "새 dali-ui 릴리스 태그 없음 — 할 일 없음."
    elif args.outcome == "gate-damage":
        names = ", ".join(e["name"] for e in damaged) or "?"
        # AI 가 수정한 회귀와 '최종 남은' 손상을 분리한다. 예전엔 수정 전 DAMAGED 였다가 고쳐진
        # 샘플(예: 26_podcast-episode diff 0.0)까지 code_bugs 로 잡혀 "AI 가 해결하지 못했습니다"
        # 라고 오보했다(실측 2026-07-22). 사람이 취할 행동이 정반대이므로 반드시 구분한다.
        pre_names = {e.get("name") for e in pre_damaged}
        now_names = {e.get("name") for e in damaged}
        fixed = sorted(pre_names - now_names)          # AI 가 실제로 고친 것
        # 골든 후보로 '승인'을 권할 수 있는 것은 업스트림 렌더링 변화로 분류된 샘플뿐이다.
        upstream = [e for e in damaged if triage.get(e["name"], {}).get("class") == "UPSTREAM"]
        code_bugs = [e for e in damaged if triage.get(e["name"], {}).get("class") == "CODE"]
        fixed_note = (f" 이번에 AI 가 {len(fixed)}건({', '.join(fixed)})은 코드로 고쳐 통과시켰습니다." if fixed else "")
        if code_bugs:
            tldr = (f"dali-ui **{ui_tag}** 빌드는 성공했으나 시각 게이트 RED — "
                    f"**{', '.join(e['name'] for e in code_bugs)}** 은 렌더러 코드 문제로 분류되어 "
                    f"AI 수정을 시도했으나 해결하지 못했습니다(시도 {fix_n}회). 골든 승인 대상이 아니라 "
                    f"코드 수정이 필요합니다.{fixed_note}")
        elif upstream:
            tldr = (f"dali-ui **{ui_tag}** 시각 게이트 RED — **{', '.join(e['name'] for e in upstream)}** 은 "
                    f"업스트림 렌더링 변화로 분류됨(코드 버그 아님). 이미지를 확인하고 기준선 갱신을 "
                    f"승인하면 릴리스됩니다.{fixed_note}")
        else:
            tldr = (f"dali-ui **{ui_tag}** 빌드는 성공했으나 시각 게이트 RED — "
                    f"**{names}** 손상 판정으로 릴리스 보류. 사람 확인 필요.{fixed_note}")
        # Golden-candidate markers (hub golden review): the run page surfaces each damaged
        # sample's baseline|new|diff card (<name>.side.png, staged into artifacts/ below) so a
        # human can approve the candidate as the new golden — a force_accept re-run then releases
        # and rotates the baseline. One marker per damaged sample; the hub greps these from the log.
        # 골든 승인 버튼은 '골든 결정이 유일한 잔여 차단 요인' 일 때만 띄운다(thorvg 의
        # other_blocking_failures 와 같은 정책; 실측 2026-07-22 교차감사). 코드 버그가 남아 있으면
        # 승인해도 릴리스가 안 되고 — FORCE_ACCEPT 는 all-or-nothing 이라 아직 안 고쳐진 코드
        # 샘플까지 함께 내보낸다 — 사람은 '이것만 승인하면 끝' 이라 오해한다. 그 경우엔 위 TLDR 의
        # 코드-수정 실패 사유로 보고하고 후보 마커를 찍지 않는다(승인 버튼 미노출). code_bugs 가
        # 없을 때만: triage 있으면 UPSTREAM 만, 없으면(분류 미수행) 기존대로 전부 후보로 노출.
        if not code_bugs:
            for e in (upstream if triage else damaged):
                print(f"[golden-candidate] {e['name']}")
    elif args.outcome == "llm-unavailable":
        # '시도했지만 못 고쳤다' 와 '아예 시도하지 못했다' 는 사람이 취할 행동이 다르다.
        tldr = (f"dali-ui **{ui_tag}** — AI 코드 적응을 **시도하지 못했습니다**(LLM 호출 불가: "
                f"{args.detail}). 코드 문제로 판명된 것이 아니므로, 한도/네트워크 회복 후 재실행하면 됩니다.")
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
    # bootstrap 은 비교 대상(이전 릴리스 렌더)이 아직 없어서 게이트를 돌 수 없다. 리포트용
    # 갤러리 시트를 만들려고 baseline 을 자기 자신과 비교하므로 compare.json 은 존재하고
    # 전부 diff=0(PASS)로 채워진다 — 그걸 그대로 "게이트 PASS 36" 으로 찍으면 검증을 통과한
    # 것처럼 읽힌다(실제로는 아무것도 검증하지 않았다). 그래서 명시적으로 구분해 적는다.
    if args.outcome == "bootstrap":
        lines += ["### 게이트", "",
                  f"- **미수행** — 최초 기준선이라 비교 대상(이전 릴리스 렌더)이 없음. "
                  f"렌더 {len(compare)}종은 아래 갤러리에서 육안 확인.", ""]
    elif compare:
        lines += ["### 게이트 (baseline 대비 픽셀 회귀 + 시각 판정)", "",
                  f"- PASS {n_pass} · REVIEW {len(reviews)} "
                  f"(허용 {len(accepted)} / 손상 {len(damaged)})", ""]
        for e in reviews:
            v = verdicts.get(e["name"], {})
            t = triage.get(e["name"], {})
            cls = ""
            if t.get("class") == "CODE":
                cls = f" · 원인: **코드 버그**({t.get('source','')}) — {t.get('rationale','')}"
            elif t.get("class") == "UPSTREAM":
                cls = f" · 원인: **업스트림 렌더링 변화**({t.get('source','')}) — {t.get('rationale','')}"
            lines.append(f"  - `{e['name']}` — {e['reason']} → "
                         f"**{v.get('verdict','미판정')}** {v.get('rationale','')}{cls}")
        if reviews:
            lines.append("")

    # ── AI 가 고친 시각 회귀 (수정 전 스냅샷 기준) ──
    # 재검증이 compare/ 를 전부 PASS 로 덮어쓰므로, 이 섹션이 없으면 "AI 가 렌더링 버그를
    # 조용히 고쳐서 그 렌더를 릴리스했다" 와 "그냥 깨끗한 재빌드였다" 가 리포트에서 구분되지 않는다.
    if pre_damaged:
        lines += ["### AI 가 고친 시각 회귀", "",
                  f"- 수정 전 손상 {len(pre_damaged)}건 → 코드 수정 후 게이트 재통과 "
                  f"(Claude 코드수정 시도 {fix_n}회). 아래는 **수정 전** 상태이며, "
                  f"수정 후 렌더는 갤러리에서 확인.", ""]
        for e in pre_damaged:
            v = pre_verdicts.get(e["name"], {})
            t = pre_triage.get(e["name"], {})
            lines.append(f"  - `{e['name']}` — {e.get('reason','')} → **{v.get('verdict','')}** "
                         f"{v.get('rationale','')} · 원인 분류: {t.get('class','?')}"
                         f"({t.get('source','')}) — {t.get('rationale','')}")
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
    # success 인데 손상(DAMAGED) 샘플이 있으면 = 그 손상은 전부 UPSTREAM 으로 분류돼 '사람 승인
    # 없이 자동 골든 승격' 된 것이다(코드 버그가 하나라도 있었으면 triage 가 CODE 를 출력해 릴리스
    # 자체가 안 된다). 이걸 승인 버튼이 아니라 '감사용 갤러리' 로 명확히 라벨링해, 사람이 리포트를
    # 훑다가 오분류(실제 코드 회귀인데 UPSTREAM)를 눈으로 잡을 수 있게 한다(정책 2026-07-23).
    auto_promoted = args.outcome == "success" and any(
        verdicts.get(e["name"], {}).get("verdict") == "DAMAGED" for e in reviews)
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
        cap = f"{e['name']} · {e['reason']} · 판정 {v.get('verdict','미판정')}"
        if auto_promoted and v.get("verdict") == "DAMAGED":
            t = triage.get(e["name"], {})
            cap += f" · ⚠️ 사람 승인 없이 자동 골든 승격({t.get('class','?')}): {t.get('rationale','')}"
        items.append({"file": fn, "caption": cap})
    if items:
        title = ("⚠️ 자동 골든 승격됨 — 감사용 (사람 승인 없이 이번 렌더가 새 기준선이 됨; "
                 "실제로는 코드 회귀인데 UPSTREAM 으로 오분류됐다면 여기서 잡아 baseline 재부트스트랩)"
                 if auto_promoted else "변경/손상 샘플 (baseline | new | diff)")
        sections.append({"title": title, "items": items})

    # AI 가 고친 회귀의 '수정 전' 카드 — 사람이 무엇이 깨졌었는지 눈으로 확인할 수 있어야 한다.
    pre_items = []
    for e in pre_damaged:
        card = e.get("card")
        if not card:
            continue
        src = os.path.join(pre_dir, card)
        if not os.path.exists(src):
            continue
        fn = "prefix_" + os.path.basename(card)
        shutil.copy(src, os.path.join(args.artifacts, fn))
        v = pre_verdicts.get(e["name"], {})
        pre_items.append({"file": fn,
                          "caption": f"[수정 전] {e['name']} · {e.get('reason','')} · "
                                     f"판정 {v.get('verdict','')}"})
    if pre_items:
        sections.append({"title": "AI 가 고친 시각 회귀 — 수정 전 (baseline | new | diff)",
                         "items": pre_items})

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
