#!/bin/bash
# 로컬 테스트용 재빌드: release 빌드 → 설치 → Developer ID 재서명(공증 생략).
# 형 맥에서 바로 실행 가능. 배포는 테스트 후 공증하여 별도로.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
SIGN_ID="Developer ID Application: YONG BEOM GWON (RB6FTGW2DK)"
ENT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/WarpOss-Entitlements.plist"
cd "$REPO" || { echo "레포 없음"; exit 1; }

echo "=== $(date '+%H:%M:%S') release 빌드 시작 ==="
WARP_SKIP_COMMON_SKILLS_INSTALL=1 ./script/run --release --dont-open || { echo "✖ 빌드 실패"; exit 1; }

echo "=== $(date '+%H:%M:%S') 설치 ==="
pkill -f "WarpOss.app" 2>/dev/null; sleep 2
rm -rf /Applications/WarpOss.app
cp -R target/release/bundle/osx/WarpOss.app /Applications/WarpOss.app || { echo "✖ 복사 실패"; exit 1; }
"$LSREG" -f /Applications/WarpOss.app

echo "=== $(date '+%H:%M:%S') Developer ID 재서명 (공증 생략) ==="
codesign --force --options runtime --timestamp --sign "$SIGN_ID" --entitlements "$ENT" /Applications/WarpOss.app || { echo "✖ 서명 실패"; exit 1; }
codesign --verify --deep --strict /Applications/WarpOss.app && echo "서명 검증 OK"

echo "=== $(date '+%H:%M:%S') 정리 ==="
"$LSREG" -u "$REPO/target/release/bundle/osx/WarpOss.app" 2>/dev/null
rm -rf "$REPO/target/release/bundle"
echo "=== $(date '+%H:%M:%S') ✅ 테스트 빌드 완료 — 미리보기 플래그 강제 활성화됨 ==="
