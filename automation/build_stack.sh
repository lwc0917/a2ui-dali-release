#!/bin/bash
# build_stack.sh <CORE_ADAPTOR_TAG> <DALI_UI_TAG>
# 격리 DALi 스택(core→adaptor→ui)을 $PREFIX 로 빌드. 사용자의 dali-env 는 불변.
# 같은 스탬프면 스킵(FORCE_REBUILD=1 로 강제). 스택 교체 시 $PREFIX 를 비워
# stale 헤더를 제거한다(과거 실제 사고: make install 이 옛 헤더를 안 지움).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/automation/lib/load_env.sh"
source "$ROOT/automation/lib/ui.sh"
source "$ROOT/automation/lib/net.sh"

CORE_TAG="${1:?core/adaptor tag}"
UI_TAG="${2:?dali-ui tag}"
STAMP="$CORE_TAG+$UI_TAG"
LOG="${RUNDIR:-$WORKSPACE}/stack_build.log"

if [ "$FORCE_REBUILD" != "1" ] && [ -f "$PREFIX/.stack" ] && [ "$(cat "$PREFIX/.stack")" = "$STAMP" ]; then
  ui_ok "스택 이미 빌드됨: $STAMP"
  exit 0
fi

ui_step "[stack] 격리 DALi 스택 빌드: $STAMP (log: $LOG)"
rm -rf "$PREFIX"
mkdir -p "$PREFIX"

# 격리 setenv 생성 (dali_env -s 형식, prefix 만 다름)
cat >"$SETENV" <<EOF
export DESKTOP_PREFIX=$PREFIX
export PATH=$PREFIX/bin:\$PATH
export LD_LIBRARY_PATH=$PREFIX/lib:\${LD_LIBRARY_PATH:-}
export INCLUDEDIR=$PREFIX/include
export PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig
export DALI_MULTI_SAMPLING_LEVEL=4
EOF

clone_or_fetch() { # $1=url $2=dir [$3=fallback url] — 손상/부분 클론은 재클론으로 자가복구(무인 운영)
  local url=$1 dir=$2 fallback=${3:-} name
  name=$(basename "$dir")
  if [ -d "$dir/.git" ]; then
    if git -C "$dir" rev-parse --verify -q HEAD >/dev/null 2>&1; then
      git -C "$dir" remote set-url origin "$url" # .env 의 repo URL 변경이 기존 클론에도 반영되게
      net_retry git -C "$dir" fetch --tags --force origin && return 0
      ui_warn "$name: fetch 실패 — 재클론으로 자가복구"
    else
      ui_warn "$name: 손상/부분 클론 감지(HEAD 없음) — 재클론"
    fi
    rm -rf "$dir"
  fi
  net_retry git clone "$url" "$dir" && return 0
  # 미러 폴백: 1순위가 망에서 막히는 경우가 실재한다(사내 프록시 = github 대형 클론 불가,
  # 다른 망 = git:// 차단 가능). 어느 한쪽이 되면 실행을 계속한다 — 클론 실패 하나로
  # 주간 무인 실행이 통째로 죽지 않게.
  [ -n "$fallback" ] || return 1
  ui_warn "$name: 1순위($url) 실패 — 폴백 미러로 재시도: $fallback"
  rm -rf "$dir"
  net_retry git clone "$fallback" "$dir"
}

build_one() { # $1=dir $2=tag
  local dir=$1 tag=$2 name
  name=$(basename "$dir")
  ui_info "$name @ $tag 빌드 중..."
  git -C "$dir" checkout -f "$tag" >>"$LOG" 2>&1 || { ui_err "$name: checkout $tag 실패"; return 1; }
  git -C "$dir" clean -fdx >>"$LOG" 2>&1 || true # 옛 태그의 CMakeCache/빌드산출물 제거
  # DALi 컨벤션: 프로젝트 루트 = build/tizen (in-source), UBUNTU 프로파일 자동 선택
  ( . "$SETENV" && cd "$dir/build/tizen" \
      && cmake -DCMAKE_INSTALL_PREFIX="$PREFIX" . \
      && make install -j"$JOBS" ) >>"$LOG" 2>&1 \
    || { ui_err "$name 빌드 실패 (tail: $(tail -3 "$LOG" | tr '\n' ' '))"; return 1; }
  ui_ok "$name 설치 완료"
}

clone_or_fetch "$DALI_CORE_REPO" "$SRC/dali-core" "${DALI_CORE_REPO_FALLBACK:-}" \
  || { ui_err "dali-core clone/fetch 실패"; exit 1; }
clone_or_fetch "$DALI_ADAPTOR_REPO" "$SRC/dali-adaptor" "${DALI_ADAPTOR_REPO_FALLBACK:-}" \
  || { ui_err "dali-adaptor clone/fetch 실패"; exit 1; }
clone_or_fetch "$DALI_UI_REPO" "$SRC/dali-ui" "${DALI_UI_REPO_FALLBACK:-}" \
  || { ui_err "dali-ui clone/fetch 실패"; exit 1; }

build_one "$SRC/dali-core" "$CORE_TAG"    || exit 1
build_one "$SRC/dali-adaptor" "$CORE_TAG" || exit 1
build_one "$SRC/dali-ui" "$UI_TAG"        || exit 1

echo "$STAMP" >"$PREFIX/.stack"
ui_ok "스택 완료: $STAMP"
