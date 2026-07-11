#!/bin/bash
# WarpOss.app을 Developer ID로 재서명 → Apple 공증 → 티켓 스테이플 → (선택) 배포용 DMG 생성.
# 인자로 넘긴 .app 경로를 대상으로 삼는다. 기본값은 /Applications/WarpOss.app.
# 필요: Developer ID 인증서(키체인), notarytool 키체인 프로파일 "WarpOssNotary".
#   프로파일 재생성:  xcrun notarytool store-credentials "WarpOssNotary" \
#     --apple-id <Apple ID 이메일> --team-id RB6FTGW2DK --password <앱전용비밀번호>
set -uo pipefail

APP="${1:-/Applications/WarpOss.app}"
SETTING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTITLEMENTS="$SETTING_DIR/WarpOss-Entitlements.plist"
SIGN_ID="Developer ID Application: YONG BEOM GWON (RB6FTGW2DK)"
PROFILE="WarpOssNotary"
MAKE_DMG="${MAKE_DMG:-0}"     # MAKE_DMG=1 이면 배포용 DMG도 만든다
DMG_OUT="${DMG_OUT:-$HOME/Desktop/WarpOss-한글판.dmg}"

step() { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
fail() { printf '\n\033[1;31m✖ %s\033[0m\n' "$*"; exit 1; }

[ -d "$APP" ] || fail "앱을 찾을 수 없음: $APP"
[ -f "$ENTITLEMENTS" ] || fail "entitlements 파일 없음: $ENTITLEMENTS"
security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID" \
  || fail "Developer ID 인증서가 키체인에 없음: $SIGN_ID"

step "Developer ID 재서명 (hardened runtime + entitlements)"
codesign --force --options runtime --timestamp \
  --sign "$SIGN_ID" --entitlements "$ENTITLEMENTS" "$APP" \
  || fail "코드 서명 실패"
codesign --verify --deep --strict "$APP" || fail "서명 검증 실패"

step "공증 제출 (Apple 서버 왕복 — 수 분 소요)"
TMPZIP="$(mktemp -d)/WarpOss.zip"
ditto -c -k --keepParent "$APP" "$TMPZIP" || fail "zip 생성 실패"
if ! xcrun notarytool submit "$TMPZIP" --keychain-profile "$PROFILE" --wait 2>&1 | tee /tmp/notary.log | tail -3; then
  fail "공증 제출 실패 (프로파일 '$PROFILE' 확인)"
fi
grep -q "status: Accepted" /tmp/notary.log || fail "공증 거부됨 — 로그: xcrun notarytool log <id> --keychain-profile $PROFILE"
rm -rf "$(dirname "$TMPZIP")"

step "공증 티켓 스테이플"
xcrun stapler staple "$APP" || fail "스테이플 실패"
spctl -a -vv "$APP" 2>&1 | grep -q "Notarized Developer ID" \
  && echo "  ✓ Gatekeeper 통과: Notarized Developer ID" \
  || fail "Gatekeeper 검증 실패"

if [ "$MAKE_DMG" = "1" ]; then
  step "배포용 DMG 생성 + 공증"
  DMGDIR="$(mktemp -d)/dmgroot"; mkdir -p "$DMGDIR"
  ditto "$APP" "$DMGDIR/$(basename "$APP")"
  ln -s /Applications "$DMGDIR/Applications"
  TMPDMG="$(mktemp -d)/WarpOss.dmg"
  hdiutil create -volname "WarpOss 한글판" -srcfolder "$DMGDIR" -ov -format UDZO "$TMPDMG" >/dev/null || fail "DMG 생성 실패"
  codesign --force --sign "$SIGN_ID" --timestamp "$TMPDMG" || fail "DMG 서명 실패"
  xcrun notarytool submit "$TMPDMG" --keychain-profile "$PROFILE" --wait 2>&1 | tee /tmp/notary-dmg.log | tail -3
  grep -q "status: Accepted" /tmp/notary-dmg.log || fail "DMG 공증 거부됨"
  xcrun stapler staple "$TMPDMG" || fail "DMG 스테이플 실패"
  ditto "$TMPDMG" "$DMG_OUT" && echo "  ✓ 배포본: $DMG_OUT"
  rm -rf "$(dirname "$DMGDIR")" "$(dirname "$TMPDMG")"
fi

printf '\n\033[1;32m✅ 공증 완료: %s\033[0m\n' "$APP"
