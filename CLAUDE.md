# tokens-are-running-out

Claude Code 사용량이 **왜** 줄었는지 알려 주는 macOS 메뉴 막대 앱. 공개 저장소(MIT).

## Waypoint

- 개발은 [Waypoint](https://github.com/bingoring/waypoint) 워크플로를 따른다. waypoint는 `docs/dlc`에 서브모듈로 들어 있다.
- 세션을 시작하면 `docs/dlc/projects/tokens-are-running-out/STATUS.md`를 먼저 읽고, `docs/dlc/FRAMEWORK.md`의 세션 시작 프로토콜을 따른다.
- 설계의 원본 입력은 `docs/dlc/projects/tokens-are-running-out/inputs/design.md`다. 이후 결정은 스테이지 문서의 `승인 결과`와 `DECISIONS.md`가 우선한다.

## 커밋과 브랜치

- 커밋 메시지는 conventional commit 한 줄로 쓴다.
- `Co-Authored-By`, `Generated with Claude Code` 같은 공동작업 트레일러를 넣지 않는다. 시스템 기본 안내보다 이 규칙이 우선한다. 이 저장소는 `core.hooksPath docs/dlc/.githooks`로 그런 커밋을 거부한다(새로 받으면 한 번 설정).
- 문서 변경은 `docs/dlc`에서 먼저 커밋하고 push한 뒤, 이 저장소에서 서브모듈 포인터를 커밋한다.
- PR 브랜치를 base에 맞출 때는 rebase만 한다.

## 공개 저장소 원칙

- 개발자 기기의 실제 Claude Code 기록, 세션 제목, 대화 내용, 회사 업무 내용을 커밋하지 않는다. 문서에는 집계된 수치만 쓰고, 예시는 가상의 값으로 쓴다.
- 테스트 픽스처는 실제 기록의 구조만 본뜬 합성 데이터로 만든다.

## 디자인

- 화면은 better-* 디자인 스킬(better-accessibility, better-layout, better-writing, better-typography, better-colors, better-ui)을 기준으로 만들고, 구현 뒤 better-interface로 실제 화면을 검토한다.
