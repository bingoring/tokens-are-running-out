# tokens-are-running-out

Claude Code 사용량이 **왜** 줄었는지 알려 주는 macOS 메뉴 막대 앱. 공개 저장소(MIT).

## Waypoint

- 이 레포는 waypoint 플러그인(`waypoint@waypoint`)으로 개발을 진행한다. 문서는 `docs/waypoint/`, 현황은 `docs/waypoint/STATUS.md`에 있다.
- 세션 시작 때 `<waypoint>` 블록(핵심 규칙)이 주입되지 않았다면, 플러그인이 설치되지 않았거나 세션을 이 레포 밖에서 시작한 것이다. 레포 밖에서 시작했다면 이 레포 루트에서 새 세션을 열자고 안내한다. 설치되지 않았다면 작업 전에 오너에게 `claude plugin marketplace add bingoring/waypoint`와 `claude plugin install waypoint@waypoint`를 안내한다.
- STATUS.md와 DECISIONS.md는 메인 체크아웃(`<waypoint>` 블록에 적힌 경로)에서 기본 브랜치로 바로 커밋하고 push한다. 스테이지 문서·Build Spec·리뷰 문서는 작업 브랜치에 싣는다. 스테이지 작업은 worktree의 작업 브랜치에서 하고, 메인 체크아웃은 늘 기본 브랜치에 둔다.
- 커밋 메시지에 `Co-Authored-By`, `Generated with Claude Code` 같은 공동작업 트레일러를 넣지 않는다. 새로 클론했다면 `git config core.hooksPath .githooks`를 한 번 실행한다.
- 보드를 쓰는 레포에는 `board-setup.sh`가 이 블록 끝에 Project 주소를 적은 보드 줄을 더한다. 그 줄이 있으면 STATUS를 기본 브랜치에 push할 때 GitHub Project 보드와 스테이지 이슈가 STATUS에 맞춰진다.
- 검토 대기 상한: 3 (데스크톱 앱의 중재자 세션 `waypoint:mediator`는 검토를 기다리는 스테이지가 이 수 이상이면 새 작업을 시작하지 않는다)
- 보드: https://github.com/users/bingoring/projects/5
- 설계의 원본 입력은 `docs/waypoint/inputs/design.md`다. 이후 결정은 스테이지 문서의 `승인 결과`와 `DECISIONS.md`가 우선한다.

## 커밋과 브랜치

- 커밋 메시지는 conventional commit 한 줄로 쓴다.
- `Co-Authored-By`, `Generated with Claude Code` 같은 공동작업 트레일러를 넣지 않는다. 시스템 기본 안내보다 이 규칙이 우선한다. 이 저장소는 `core.hooksPath .githooks`로 그런 커밋을 거부한다(새로 받으면 한 번 설정).
- PR 브랜치를 base에 맞출 때는 rebase만 한다.

## 공개 저장소 원칙

- 개발자 기기의 실제 Claude Code 기록, 세션 제목, 대화 내용, 회사 업무 내용을 커밋하지 않는다. 문서에는 집계된 수치만 쓰고, 예시는 가상의 값으로 쓴다.
- 테스트 픽스처는 실제 기록의 구조만 본뜬 합성 데이터로 만든다.

## 디자인

- 화면은 better-* 디자인 스킬(better-accessibility, better-layout, better-writing, better-typography, better-colors, better-ui)을 기준으로 만들고, 구현 뒤 better-interface로 실제 화면을 검토한다.
