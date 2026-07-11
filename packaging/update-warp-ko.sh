#!/bin/bash
# Warp 한글판 업데이트: 업스트림 최신 병합 → 검사 → release 빌드 → 설치 → 정리.
# 충돌이나 신규 번역 키가 나오면 멈추고 알려준다 → Claude Code에서 /warp-ko-update 실행.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

step() { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
fail() { printf '\n\033[1;31m✖ %s\033[0m\n' "$*"; exit 1; }

cd "$REPO" || fail "저장소가 없습니다: $REPO"
[ -z "$(git status --porcelain --untracked-files=no)" ] || fail "작업 트리가 깨끗하지 않습니다. 커밋/정리 후 다시 실행하세요."

step "업스트림 가져오기"
git fetch origin master || fail "fetch 실패 (네트워크 확인)"
git checkout korean-ui || fail "korean-ui 브랜치 없음"

BEHIND=$(git rev-list --count HEAD..origin/master)
step "master 대비 뒤처진 커밋: ${BEHIND}개"
if [ "$BEHIND" -eq 0 ]; then
  echo "이미 최신입니다. 빌드만 다시 하려면 --rebuild 옵션을 쓰세요."
  [ "${1:-}" = "--rebuild" ] || exit 0
else
  step "master 병합"
  if ! git merge origin/master --no-edit; then
    git merge --abort
    fail "병합 충돌 발생 — Claude Code에서 /warp-ko-update 를 실행하면 충돌 해결부터 번역까지 처리합니다."
  fi
fi

step "누락 번역 키 검사"
python3 "$SETTING_DIR/scan_missing_keys.py"
SCAN=$?
if [ "$SCAN" -eq 3 ]; then
  fail "새 번역 키 발견 (missing_keys.json) — Claude Code에서 /warp-ko-update 를 실행해 번역을 채우세요."
elif [ "$SCAN" -ne 0 ]; then
  fail "키 스캔 실패"
fi

step "i18n 테스트"
cargo test -p i18n || fail "i18n 테스트 실패"

step "release 빌드 + .app 번들 (수십 분 걸릴 수 있음)"
WARP_SKIP_COMMON_SKILLS_INSTALL=1 ./script/run --release --dont-open || fail "빌드 실패"

step "설치 (/Applications/WarpOss.app 교체)"
pkill -f "WarpOss.app" 2>/dev/null; sleep 1
rm -rf /Applications/WarpOss.app
cp -R target/release/bundle/osx/WarpOss.app /Applications/WarpOss.app || fail "복사 실패"
"$LSREG" -f /Applications/WarpOss.app

step "Developer ID 공증 (Gatekeeper 경고 없이 배포 가능)"
# 인증서/공증 프로파일이 있으면 재서명·공증·스테이플. 없으면 건너뛴다(로컬 실행은 문제없음).
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application: YONG BEOM GWON"; then
  MAKE_DMG=1 "$SETTING_DIR/notarize-warposs.sh" /Applications/WarpOss.app \
    || echo "⚠ 공증 단계 실패 — 앱은 설치됐으나 미공증 상태(로컬 실행은 가능). 로그: /tmp/notary.log"
else
  echo "ℹ Developer ID 인증서 없음 → 공증 건너뜀 (로컬 실행은 정상)"
fi

step "정리 (Launchpad 중복 아이콘 방지 + 디스크)"
"$LSREG" -u "$REPO/target/release/bundle/osx/WarpOss.app" 2>/dev/null
rm -rf "$REPO/target/release/bundle" "$REPO/target/debug/bundle"

printf '\n\033[1;32m✅ 완료! 한국어 Warp 최신판이 설치되었습니다. 실행: open -a WarpOss\033[0m\n'
