#!/usr/bin/env python3
"""코퍼스가 '결정적으로 렌더 가능한' 상태인지 렌더 전에 검증한다.

왜 (실측 2026-07-22): 코퍼스 36종 중 35종은 이미지 URL 이 로컬(`sample-images/…`)로 고정돼
있는데 `30_live-invitation-builder` 하나만 원격 `https://images.unsplash.com/…` 이 남아 있었다.
DALi ImageView 는 http URL 을 안 받아 회색 플레이스홀더로 렌더되고, 네트워크 상태에 따라
결과가 흔들린다. 그러면 AI 가 무엇을 고쳐도 이 샘플 하나 때문에 게이트가 비결정적으로 RED 가
되어(실측: 26 을 diff 0.0 으로 고쳐도 30 이 남아 릴리스 보류), 릴리스 판정이 신뢰를 잃는다.

정책: 게이트는 결정적이어야 한다. 코퍼스에 로컬화되지 않은 원격 '이미지' URL 이 있으면 렌더
전에 실패시킨다(카탈로그 스펙 URL 은 이미지가 아니므로 제외). 로컬화는 tools/localize_images.py
로 하되, 그건 네트워크가 필요하므로 여기서는 '검출' 만 하고 무엇을 고쳐야 하는지 알린다.

exit 0 = 모든 이미지가 로컬(결정적) / 1 = 원격 이미지 URL 잔존(어느 샘플·URL 인지 출력).
stdlib 만 사용.
"""

from __future__ import annotations

import glob
import os
import re
import sys

# 이미지로 볼 URL: 흔한 이미지 확장자 또는 이미지 CDN 호스트. 카탈로그/스펙 JSON URL 은 제외.
_IMG_EXT = re.compile(r"\.(png|jpe?g|gif|webp|bmp|svg)(\?|$)", re.I)
_IMG_HOST = re.compile(r"(images\.unsplash\.com|\.githubusercontent\.com|imgur\.com|/image[s]?/)", re.I)
_URL = re.compile(r"https?://[^\s\"']+")


def _is_image_url(u: str) -> bool:
    if u.endswith(".json") or "/catalog" in u or "/specification/" in u:
        return False
    return bool(_IMG_EXT.search(u) or _IMG_HOST.search(u))


def remote_image_urls(jsonl_path: str) -> list[str]:
    """이 코퍼스 파일에 남은 로컬화되지 않은 원격 이미지 URL(중복 제거, 등장 순서)."""
    out: list[str] = []
    seen: set[str] = set()
    try:
        text = open(jsonl_path, encoding="utf-8", errors="replace").read()
    except OSError:
        return out
    for m in _URL.finditer(text):
        u = m.group(0).rstrip('",')
        if _is_image_url(u) and u not in seen:
            seen.add(u)
            out.append(u)
    return out


def scan(corpus_dir: str) -> dict[str, list[str]]:
    bad: dict[str, list[str]] = {}
    for p in sorted(glob.glob(os.path.join(corpus_dir, "*.jsonl"))):
        urls = remote_image_urls(p)
        if urls:
            bad[os.path.basename(p)] = urls
    return bad


if __name__ == "__main__":
    corpus = sys.argv[1] if len(sys.argv) > 1 else "corpus/jsonl"
    bad = scan(corpus)
    if not bad:
        print("[corpus] 모든 이미지가 로컬 — 결정적 렌더 가능")
        sys.exit(0)
    print("[corpus] 로컬화되지 않은 원격 이미지 URL 잔존 — 게이트가 비결정적이 된다:", file=sys.stderr)
    for name, urls in bad.items():
        for u in urls:
            print(f"  {name}: {u}", file=sys.stderr)
    print("  → tools/localize_images.py <src_corpus> <dst_corpus> 로 로컬화 후 커밋하세요.", file=sys.stderr)
    sys.exit(1)
