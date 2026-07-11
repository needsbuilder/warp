#!/bin/bash
# 번역·아이콘 변경 반영: release 빌드 → 설치 → 재서명·공증·스테이플 → 배포 DMG → 정리.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
cd "$REPO" || { echo "레포 없음"; exit 1; }

echo "=== $(date '+%H:%M:%S') release 빌드 시작 ==="
WARP_SKIP_COMMON_SKILLS_INSTALL=1 ./script/run --release --dont-open || { echo "✖ 빌드 실패"; exit 1; }

echo "=== $(date '+%H:%M:%S') 설치 (/Applications/WarpOss.app 교체) ==="
pkill -f "WarpOss.app" 2>/dev/null; sleep 2
rm -rf /Applications/WarpOss.app
cp -R target/release/bundle/osx/WarpOss.app /Applications/WarpOss.app || { echo "✖ 복사 실패"; exit 1; }
"$LSREG" -f /Applications/WarpOss.app

echo "=== $(date '+%H:%M:%S') 재서명·공증·스테이플 + 배포 DMG ==="
MAKE_DMG=1 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/notarize-warposs.sh" /Applications/WarpOss.app || { echo "✖ 공증 실패"; exit 1; }

echo "=== $(date '+%H:%M:%S') 정리 ==="
"$LSREG" -u "$REPO/target/release/bundle/osx/WarpOss.app" 2>/dev/null
rm -rf "$REPO/target/release/bundle"

echo "=== $(date '+%H:%M:%S') ✅ 전체 완료 — 번역·아이콘 반영된 공증본 설치됨 ==="
