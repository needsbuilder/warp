# BUILD-NOTES — WarpOss 한글판 운영 노트

(2026-07 기준. 로컬 작업 폴더를 정리하며 빌드 지식만 보존한 문서.)

## 브랜치 지도
- `korean-ui` — 업스트림 PR용 (로케일 전용). warpdotdev/warp **PR #13374**의 head 브랜치. 여기엔 PR과 무관한 커밋을 올리지 않는다.
- `korean-ui-with-shader` — 개인 빌드용: korean-ui + 애니메이션 셰이더 배경 16종 (paper.design 포팅). 이 packaging/ 커밋도 여기에만 있다.
- `i18n` — Phase 2 YAML 병합 작업 브랜치 (259 키).
- `backup-korean-ui-pre-rebase`, `backup-korean-ui-before-email-fix` — rebase 전 스냅샷 백업.
- 드미트리의 i18n 기반 PR: warpdotdev/warp #11382. korean-ui의 base는 그 head(cb86b33ac) 위였다 — #11382가 master에 머지되면 korean-ui를 master 위로 최종 rebase.

## 빌드 → 설치 파이프라인
1. `WARP_SKIP_COMMON_SKILLS_INSTALL=1 ./script/run --release --dont-open`
2. WarpOss 프로세스 종료 → `/Applications/WarpOss.app` 교체 (`packaging/staged-install-warposs.sh`)
3. `lsregister -f` 갱신 → `target/*/bundle` 삭제 (Launchpad 중복 아이콘 방지)

## 함정·주의 (실사고 기록)
- **전체 `cargo nextest` 로컬 실행 금지** — 테스트 빌드가 디스크 60GB+ 소모 (디스크 풀 사고 전례). CI에 맡긴다.
- **프로세스 확인은 `ps -eo pid,command | grep`으로** — 샌드박스 셸에서 `pgrep -f`/`pkill -f`는 다른 프로세스의 argv를 못 봐 조용히 실패한다. staged-install이 실행 중인 앱을 그대로 교체해버린 사고가 있었다 (macOS는 inode를 유지해 세션은 살아남음).
- WarpOss 설정 디렉터리 = `~/.warp-oss` — **정품 Warp의 `~/.warp`와 별개**. 공식 Warp(/Applications/Warp.app)는 절대 건드리지 않는다.
- Warp UI는 GPU 렌더링이라 접근성(AX)·백그라운드 키 자동화가 안 통한다 (메뉴바 항목 AX press는 됨).
- 새 빌드 테스트는 `WARP_CONFIG_DIR=/tmp/...` 별도 인스턴스로 — 쓰던 인스턴스를 죽이면 세션이 끊긴다.
- 언트랙 `*.orig-with-grid` 아이콘 파일은 커밋하지 않는다.
- 공증이 403 "required agreement is missing or expired"로 실패하면 developer.apple.com에서 개발자 계약 서명/갱신 필요 (로컬 실행엔 지장 없음).

## 번역 규칙 요약
전체 절차·용어 사전은 `.claude/skills/warp-ko-update/SKILL.md` 참고. 핵심:
- 번역 키는 `resources/bundled/locales/extra.yml` — 플랫 dotted 키, `en:`/`ko:` 동수, {placeholder} 패리티 검증 필수.
- 식별자 겸용 문자열(Display/FromStr, 이름 비교, telemetry)은 절대 번역하지 않는다.
- 하드코딩 문자열은 `crate::menu_label("네임스페이스.키", "원문")` 래핑, 반복 호출 지점은 OnceLock 캐싱 (`app_menus.rs`의 `cached_menu_label_fn!` 참고).
