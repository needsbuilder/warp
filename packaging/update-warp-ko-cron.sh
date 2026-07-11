#!/bin/bash
# launchd가 매달 호출하는 래퍼: 환경 설정 → 본 스크립트 실행 → 결과를 맥 알림으로.
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/opt/homebrew/opt/node@24/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export WARP_SKIP_COMMON_SKILLS_INSTALL=1

LOG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/update.log"
{
  echo "════════ $(date '+%Y-%m-%d %H:%M:%S') 월간 자동 업데이트 시작 ════════"
  # caffeinate: 빌드 중 맥이 잠들지 않게
  caffeinate -i bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/update-warp-ko.sh"
  RC=$?
  echo "종료 코드: $RC ($(date '+%H:%M:%S'))"
} >> "$LOG" 2>&1

if [ "$RC" -eq 0 ]; then
  osascript -e 'display notification "한국어 Warp가 최신 상태입니다." with title "WarpOss 월간 업데이트 ✅"' 2>/dev/null
else
  osascript -e 'display notification "충돌 또는 새 번역 필요 — Claude Code에서 /warp-ko-update 를 실행하세요. (로그: update.log)" with title "WarpOss 업데이트 중단 ⚠️"' 2>/dev/null
fi
exit "$RC"
