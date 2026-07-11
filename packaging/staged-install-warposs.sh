#!/bin/bash
# 대기형 WarpOss 설치: WarpOss가 종료되기를 기다렸다가 교체→등록→재실행.
# (실행 중인 앱을 건드리지 않도록 update-warp-ko.sh의 설치 단계를 분리한 버전)
# 사용: nohup 등으로 분리 실행해두고, WarpOss를 Cmd+Q로 종료하면 나머지가 자동 진행.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETTING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
BUNDLE="$REPO/target/release/bundle/osx/WarpOss.app"
LOG=/tmp/staged-install-warposs.log

exec >>"$LOG" 2>&1
echo "=== $(date '+%F %T') staged install 시작 ==="

[ -d "$BUNDLE" ] || { echo "✖ 번들 없음: $BUNDLE"; exit 1; }

echo "WarpOss 종료 대기 중... (pgrep -f MacOS/warp-oss)"
while pgrep -f "MacOS/warp-oss" >/dev/null; do sleep 2; done
echo "$(date '+%T') WarpOss 종료 감지 — 3초 후 교체"
sleep 3

rm -rf /Applications/WarpOss.app
cp -R "$BUNDLE" /Applications/WarpOss.app || { echo "✖ 복사 실패"; exit 1; }
"$LSREG" -f /Applications/WarpOss.app

# 공증(있으면). 로컬 실행엔 필수 아님 — 실패해도 계속.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application: YONG BEOM GWON"; then
  "$SETTING_DIR/notarize-warposs.sh" /Applications/WarpOss.app || echo "⚠ 공증 실패(로컬 실행은 정상)"
fi

# 정리: Launchpad 중복 방지 + 빌드 번들 삭제
"$LSREG" -u "$REPO/target/release/bundle/osx/WarpOss.app" 2>/dev/null || true
rm -rf "$REPO/target/release/bundle" "$REPO/target/debug/bundle"

open -a WarpOss
echo "✅ $(date '+%T') 설치 완료 — WarpOss 재실행됨"
