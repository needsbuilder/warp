---
name: warp-ko-update
description: Warp 한글판을 업스트림 최신으로 업데이트한다 — master 재병합(충돌 해결 포함), 신규 문자열 한국어 번역, release 빌드, /Applications 설치, 정리까지 전 과정. 사용자가 "warp 업데이트", "한글판 최신으로", "재병합" 등을 요청할 때 실행.
---

# Warp 한글판 업데이트 파이프라인

저장소: 이 저장소 루트 (브랜치 `korean-ui` = upstream master + i18n PR #11382 + 한글화 커밋들, `korean-ui-with-shader` = 개인 빌드용).
업스트림 PR: https://github.com/warpdotdev/warp/pull/13374 (fork: needsbuilder/warp-korean).
배경 문서: `packaging/BUILD-NOTES.md`.

## 절차

1. **기계적 파이프라인 시도**: `bash packaging/update-warp-ko.sh` 실행 (release 빌드 포함 — 백그라운드로 돌리고 대기). 충돌·신규 키 없이 끝나면 8단계로.

2. **병합 충돌 시**: 직접 `git merge origin/master` 후 충돌 해결. 원칙:
   - 기능 변화는 master 편을 든다. i18n 래핑(menu_label)은 유지하되 fallback 문자열을 master의 새 문구로 갱신하고, en.yml/extra.yml의 해당 키 값과 ko 번역도 새 의미로 함께 갱신한다.
   - 식별자 겸용 문자열(Display/FromStr, 이름 비교, telemetry)은 절대 번역하지 않는다.
   - upstream이 #11382를 정식 머지(스쿼시)한 경우 대규모 중복 충돌이 날 수 있다 — 그때는 upstream master를 새 베이스로 삼고 우리 한글화 커밋만 체리픽하는 재구축을 검토한다.

3. **신규 번역 키**: `python3 packaging/scan_missing_keys.py` (저장소 루트에서) → `missing_keys.json`.
   - 60개 이하: 직접 번역. 그 이상: sonnet 에이전트로 청크 분할 병렬 번역 (에이전트 수 사용자 고지, model 명시).
   - `resources/bundled/locales/extra.yml`에 추가 — 플랫 dotted 키, `en:`/`ko:` 두 섹션 모두, JSON 이스케이프 쌍따옴표, 키 정렬 유지.
   - 검증 필수: YAML 파싱, en/ko 키 동수, {placeholder} 패리티, 선행/후행 공백 보존(조각 문자열).

4. **용어 사전** (기존 번역과 통일):
   tab=탭, window=윈도우, pane=패널, block=블록, session=세션, command=명령어, settings=설정, editor=편집기, code review=코드 리뷰, project explorer=프로젝트 탐색기, agent=에이전트, credit=크레딧, environment=환경, repo=저장소, remove=제거, delete=삭제, cut=오려두기(macOS), undo=실행 취소, redo=실행 복귀, new X=새로운 X, Show X=X 표시, Always ask=항상 확인, blur=블러, keybinding=키 바인딩. 고유명사 유지: Warp, Warp Agent, Warp Drive, Oz, Warpify, MCP, LSP, SSH, PR, diff, Hunk, BYOK, git(소문자), 플랜명(Build/Turbo/Lightspeed/Max/Business/Enterprise). 버튼=간결형, 설명문="-합니다"체.

5. **새 하드코딩 문자열** (사용자가 영어 화면을 신고했을 때): menu_label 래핑으로 연결. `crate::menu_label("네임스페이스.키", "원문")`. 반복 호출 위치(렌더 루프, 메뉴 갱신 클로저)는 OnceLock 캐싱 패턴 사용 (app_menus.rs의 `cached_menu_label_fn!` 참고). 식별자 겸용 문자열은 렌더 지점에서만 래핑.

6. **품질 게이트**: `cargo test -p i18n`, `cargo clippy -p <변경 크레이트> --all-targets -- -D warnings`, `./script/format`, `./script/check_no_inline_test_modules`.
   ⚠️ 전체 `cargo nextest`는 로컬 금지 — 테스트 빌드가 디스크 60GB+ 소모 (과거 디스크 풀 사고). CI에 맡긴다.

7. **빌드·설치**: `WARP_SKIP_COMMON_SKILLS_INSTALL=1 ./script/run --release --dont-open` → WarpOss 프로세스 종료 → `/Applications/WarpOss.app` 교체 (`packaging/staged-install-warposs.sh`) → lsregister -f → **target/*/bundle 삭제** (Launchpad 중복 아이콘 방지).

8. **마무리**: 커밋(브랜치 korean-ui), `git push fork korean-ui` (PR #13374 자동 갱신 — 푸시 전 사용자에게 고지), 실행 후 스크린샷으로 한국어 확인, `packaging/BUILD-NOTES.md` 갱신.

## 주의
- 공식 Warp(/Applications/Warp.app)는 절대 건드리지 않는다.
- AGENTS.md가 병합으로 또 바뀌면 master 버전으로 복원한다 (PR 작성자의 개인 설정 파일이 섞여 들어온 전례 있음).
- ru.yml은 키 존재만 유지하면 됨 (번역 품질은 러시아 커뮤니티 몫).
