# tokens-are-running-out (내 토큰 어디 갔어?) — waypoint 현황

[설계 입력](inputs/design.md) · [결정 로그](DECISIONS.md) · [지난 기록](HISTORY.md) · [소개 글 초안](03-operations/first-release/launch-posts.md)

## 스테이지

| ID | 스테이지 | 상태 | 줄기 | 지금 | 기다림 | 링크 |
|---|---|---|---|---|---|---|
| 1-1 | Context Synthesis | MERGED | | | | [문서](01-inception/01-context-synthesis.md) |
| 1-2 | Domain Model | MERGED | | | | [문서](01-inception/02-domain-model.md) |
| 1-3 | Architecture Decision ⚠️ | MERGED | | | | [문서](01-inception/03-architecture-decision.md) |
| 2-1 | 기록 리더와 색인 | MERGED | | | | [문서](02-construction/01-reader-and-index.md) · [#1](https://github.com/bingoring/tokens-are-running-out/pull/1) |
| 2-2 | 재구축 판정 · 원인 분류 · 비용 분해 | MERGED | | | | [문서](02-construction/02-rebuild-analysis.md) · [#2](https://github.com/bingoring/tokens-are-running-out/pull/2) |
| 2-3 | 메뉴 막대 앱 | MERGED | | | | [문서](02-construction/03-menu-bar-app.md) · [#3](https://github.com/bingoring/tokens-are-running-out/pull/3) |
| 2-4 | 릴리스 파이프라인 | MERGED | | | | [문서](02-construction/04-release-pipeline.md) · [#4](https://github.com/bingoring/tokens-are-running-out/pull/4) |
| 2-5 | 큰 세션 정리 안내 | MERGED | | | | [문서](02-construction/05-compact-guidance.md) · [#10](https://github.com/bingoring/tokens-are-running-out/pull/10) · [#11](https://github.com/bingoring/tokens-are-running-out/pull/11) |
| R-1 | Independent Code Review 🔍 | MERGED | | | | [문서](0R-review/01-independent-review.md) · [#5](https://github.com/bingoring/tokens-are-running-out/pull/5) |
| 3-1 | 첫 공개 | IN_PROGRESS | | 구현: 소개 글 게시가 확인되면 닫음(게시·기준선 기록은 3-2가 맡음) | 오너 할 일 | [문서](03-operations/01-first-release.md) |
| 3-2 | 반응 확인 | IN_PROGRESS | | 구현: 계획·결과 공유 템플릿 머지(#16) → 게시 직전 D+0 스냅숏 → 28일 관찰 | 오너 할 일 | [#16](https://github.com/bingoring/tokens-are-running-out/pull/16) |

## 오너 할 일

- [ ] 소개 글 게시(Show HN, GeekNews). 올리기 직전에 "곧 올린다"고 알림(3-2의 D+0 스냅숏) (막음: 3-1, 3-2)
- [ ] 2-5 기기에서 못 본 두 가지 확인: 데스크톱 앱에서 붙여 넣기, compact 뒤 목록 제외
