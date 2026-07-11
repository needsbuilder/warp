# packaging — WarpOss 한글판 빌드·서명·설치 도구

Warp OSS를 한글화 브랜치로 빌드해 macOS 앱(`/Applications/WarpOss.app`)으로 서명·공증·설치하는 스크립트 모음.
원래 저장소 바깥(`~/projects/warp-setting/`)에 있던 것을 저장소 보존용으로 옮겨왔다 — 경로는 스크립트 위치 기준으로 자동 계산되므로 어디에 클론해도 동작한다.

| 파일 | 역할 |
|---|---|
| `update-warp-ko.sh` | 전체 파이프라인: upstream 병합 → 누락 키 스캔 → 테스트 → release 빌드 → 설치 → 공증 |
| `update-warp-ko-cron.sh` | 위 파이프라인의 cron/launchd 래퍼 (caffeinate 포함) |
| `rebuild-and-notarize.sh` | 재빌드 + 공증 + DMG 생성 단축 스크립트 |
| `notarize-warposs.sh` | Developer ID 재서명 → Apple 공증 → 스테이플 → (MAKE_DMG=1) 배포 DMG |
| `staged-install-warposs.sh` | 빌드 산출물을 /Applications에 안전 교체 설치 |
| `rebuild-test.sh` | 테스트용 빠른 재빌드 |
| `scan_missing_keys.py` | 한글화 누락 키 스캔 → `missing_keys.json` |
| `WarpOss-Entitlements.plist` | 서명용 entitlements |
| `BUILD-NOTES.md` | 빌드·운영 노트 (함정·주의사항) |

## 사전 요건
- 키체인에 Developer ID Application 인증서
- notarytool 키체인 프로파일 `WarpOssNotary`:
  `xcrun notarytool store-credentials "WarpOssNotary" --apple-id <Apple ID 이메일> --team-id <팀ID> --password <앱전용비밀번호>`
- Rust 툴체인 (저장소 루트의 `rust-toolchain.toml` 버전)

Claude Code 사용자는 `.claude/skills/warp-ko-update/`의 스킬이 전 과정을 안내한다.
