#!/usr/bin/env python3
"""compare.py — baseline vs new 렌더 비교 게이트 (a2ui-dali-release).

동일 데스크톱 백엔드(prev vs new) 회귀 비교 — web-parity 판정이 아님.
diff 스케일은 a2ui-dali-publish/tools/regress.sh 와 동일: RGB float(0..255)의
mean-abs-diff, 임계 0.05(서브 AA 노이즈 허용).

Usage:
  compare.py --baseline DIR --new DIR --out DIR [--threshold 0.05]

산출물 (OUT 밑):
  compare.json          [{name, diff, status, reason, card}]  status=PASS|REVIEW
  side/<name>.side.png  REVIEW 샘플별 side-by-side 카드 (baseline | new | diff-heatmap,
                        동일 크기, 절대 겹침 없음)
  gallery_sheet.png     전체 샘플 타일 시트 (new 기준, 누락 시 baseline)
Exit: 0 (게이트 판정은 judge 단계 몫), 하드 에러만 비-0.
"""
import argparse
import json
import os
import sys
import glob

from PIL import Image, ImageDraw, ImageFont
import numpy as np

LABEL_H = 28
GAP = 12
BG = (255, 255, 255)
FG = (26, 34, 56)


def load_font(size=16):
    for p in (
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/dejavu/DejaVuSans.ttf",
    ):
        if os.path.exists(p):
            return ImageFont.truetype(p, size)
    return ImageFont.load_default()


FONT = load_font()


def heatmap(a, b):
    """per-pixel diff → 흰 배경에 빨강 강조 이미지 (같은 크기 전제)."""
    d = np.abs(a - b).mean(axis=2)  # HxW, 0..255
    amp = np.clip(d * 4.0, 0, 255).astype(np.uint8)
    h, w = amp.shape
    out = np.full((h, w, 3), 255, dtype=np.uint8)
    out[:, :, 1] = 255 - amp
    out[:, :, 2] = 255 - amp
    return Image.fromarray(out)


def labeled_panel(img, label, panel_size):
    """이미지를 panel_size 에 맞춰(비율 유지, 여백 흰색) 라벨 위에 얹은 패널."""
    pw, ph = panel_size
    panel = Image.new("RGB", (pw, ph + LABEL_H), BG)
    draw = ImageDraw.Draw(panel)
    draw.text((4, 6), label, fill=FG, font=FONT)
    if img is not None:
        scale = min(pw / img.width, ph / img.height, 1.0)
        r = img.resize((max(1, int(img.width * scale)), max(1, int(img.height * scale))))
        panel.paste(r, ((pw - r.width) // 2, LABEL_H + (ph - r.height) // 2))
    else:
        draw.text((4, LABEL_H + 10), "(없음)", fill=(180, 40, 40), font=FONT)
    return panel


def side_card(base_img, new_img, name, diff_txt, out_path):
    """baseline | new | diff 를 동일 크기로 나란히(겹침 없음) 배치한 카드."""
    ref = new_img or base_img
    pw, ph = ref.width, ref.height
    panels = [
        labeled_panel(base_img, "baseline", (pw, ph)),
        labeled_panel(new_img, f"new  ({diff_txt})", (pw, ph)),
    ]
    if base_img is not None and new_img is not None and base_img.size == new_img.size:
        a = np.asarray(base_img.convert("RGB"), dtype=float)
        b = np.asarray(new_img.convert("RGB"), dtype=float)
        panels.append(labeled_panel(heatmap(a, b), "diff ×4", (pw, ph)))
    W = sum(p.width for p in panels) + GAP * (len(panels) + 1)
    H = panels[0].height + GAP * 2 + LABEL_H
    card = Image.new("RGB", (W, H), BG)
    draw = ImageDraw.Draw(card)
    draw.text((GAP, GAP), name, fill=FG, font=FONT)
    x = GAP
    for p in panels:
        card.paste(p, (x, GAP + LABEL_H))
        x += p.width + GAP
    card.save(out_path)


def gallery_sheet(entries, new_dir, base_dir, out_path, cols=6, tile_w=240):
    tiles = []
    for e in entries:
        p = os.path.join(new_dir, e["name"] + ".png")
        if not os.path.exists(p):
            p = os.path.join(base_dir, e["name"] + ".png")
        img = Image.open(p).convert("RGB") if os.path.exists(p) else None
        if img is not None:
            scale = tile_w / img.width
            img = img.resize((tile_w, max(1, int(img.height * scale))))
        tiles.append((e, img))
    tile_h = max((im.height for _, im in tiles if im is not None), default=200)
    cell_h = tile_h + LABEL_H + GAP
    cell_w = tile_w + GAP
    rows = (len(tiles) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * cell_w + GAP, rows * cell_h + GAP), BG)
    draw = ImageDraw.Draw(sheet)
    for i, (e, im) in enumerate(tiles):
        x = GAP + (i % cols) * cell_w
        y = GAP + (i // cols) * cell_h
        mark = "" if e["status"] == "PASS" else "  ⚠"
        draw.text((x, y), e["name"] + mark, fill=FG, font=FONT)
        if im is not None:
            sheet.paste(im, (x, y + LABEL_H))
    sheet.save(out_path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--baseline", required=True)
    ap.add_argument("--new", dest="new_dir", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--threshold", type=float, default=0.05)
    args = ap.parse_args()

    os.makedirs(os.path.join(args.out, "side"), exist_ok=True)
    names = sorted(
        {os.path.splitext(os.path.basename(p))[0]
         for d in (args.baseline, args.new_dir)
         for p in glob.glob(os.path.join(d, "*.png"))}
    )
    if not names:
        print("compare: no renders found", file=sys.stderr)
        return 1

    entries = []
    for name in names:
        bp = os.path.join(args.baseline, name + ".png")
        np_ = os.path.join(args.new_dir, name + ".png")
        base_img = Image.open(bp).convert("RGB") if os.path.exists(bp) else None
        new_img = Image.open(np_).convert("RGB") if os.path.exists(np_) else None
        diff = None
        if base_img is None:
            status, reason = "REVIEW", "baseline 없음(신규 샘플?)"
        elif new_img is None:
            status, reason = "REVIEW", "새 렌더 없음(렌더 실패)"
        elif base_img.size != new_img.size:
            status, reason = "REVIEW", f"크기 불일치 {base_img.size}→{new_img.size}"
        else:
            a = np.asarray(base_img, dtype=float)
            b = np.asarray(new_img, dtype=float)
            diff = float(np.abs(a - b).mean())
            if diff <= args.threshold:
                status, reason = "PASS", ""
            else:
                status, reason = "REVIEW", f"diff={diff:.3f}"
        card = None
        if status != "PASS":
            card = os.path.join("side", name + ".side.png")
            diff_txt = f"diff={diff:.3f}" if diff is not None else reason
            side_card(base_img, new_img, name, diff_txt, os.path.join(args.out, card))
        entries.append({"name": name, "diff": diff, "status": status,
                        "reason": reason, "card": card})

    gallery_sheet(entries, args.new_dir, args.baseline,
                  os.path.join(args.out, "gallery_sheet.png"))
    with open(os.path.join(args.out, "compare.json"), "w") as f:
        json.dump(entries, f, indent=1, ensure_ascii=False)

    n_pass = sum(1 for e in entries if e["status"] == "PASS")
    print(f"compare: PASS {n_pass}/{len(entries)}, REVIEW {len(entries) - n_pass}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
