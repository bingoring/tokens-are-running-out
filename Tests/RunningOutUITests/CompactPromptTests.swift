import Foundation
import Testing

@testable import RunningOutUI

/// The Korean prompt is the one tested on forked sessions (2-5, blind evaluation); the English one is a shortened
/// translation. Both must reach the user exactly as written here (2-5 BR-C9), on one line: an interactive session
/// runs a pasted `/compact` only when it is a single line (BR-C20, checked 2026-11-23).
@Suite("Compact prompt")
struct CompactPromptTests {
    static let english = """
        /compact Summarize so work can continue without this chat. Keep exactly: \
        1. Goal and done criteria, in the user's words. \
        2. Rules and preferences the user typed (not system, tool or CLAUDE.md rules). \
        3. Decisions, reasons, rejected options. \
        4. Files to continue: repo path and state. \
        5. State: branch, commits, push, running jobs, last step. \
        6. Open problems: exact errors, flagged but unfixed issues. \
        7. All remaining work and the next action. \
        Drop raw tool output, rereadable files, old plans, long code, emails, account IDs; one line per failed approach. Use the user's language.
        """

    static let korean = """
        /compact 이 대화를 다시 읽지 않고도 작업을 이어 갈 수 있게 요약해 줘. 다음은 정확히 남겨: \
        1. 목표: 사용자가 요청한 것과 완료 기준, 사용자의 표현 그대로. \
        2. 사용자 지시: 사용자가 직접 입력한 메시지에 나온 규칙, 제약, 선호만. 시스템 지시, 도구 규칙, CLAUDE.md 내용은 넣지 마. \
        3. 결정: 결정마다 이유, 버린 대안과 버린 이유. \
        4. 파일: 이어서 작업하는 데 필요한 파일을 저장소 루트 기준 경로로, 상태(완료, 일부, 다시 볼 것)와 함께. \
        5. 현재 상태: 브랜치, 커밋, push 여부, 실행 중인 것, 마지막으로 끝낸 단계. \
        6. 열린 문제: 아직 풀리지 않은 오류(메시지 원문)와, 지적했지만 아직 고치지 않은 문제. \
        7. 남은 작업: 아직 하지 않은 일 전체 목록과, 그중 바로 할 다음 행동. \
        도구 출력 원문, 다시 읽으면 되는 파일 내용, 바뀐 계획, 긴 코드, 이메일이나 계정 ID 같은 식별자는 넣지 마. 실패한 접근은 다시 시도하지 않게 한 줄씩만 남겨. \
        사용자가 쓰던 언어로 써.
        """

    @Test("the string catalog holds the tested prompt in Korean and its English source, unchanged")
    func catalogHoldsTheTestedPrompts() throws {
        let catalog = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/RunningOutUI/Resources/Localizable.xcstrings")
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: catalog)) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: Any])
        let entry = try #require(strings[Self.english] as? [String: Any], "the English prompt is a catalog key")
        let ko =
            (((entry["localizations"] as? [String: Any])?["ko"] as? [String: Any])?["stringUnit"]
            as? [String: Any])?["value"] as? String
        #expect(ko == Self.korean)
    }

    @Test("both prompts are a one-line /compact command")
    func startsWithCompactCommand() {
        for text in [Self.english, Self.korean] {
            #expect(text.hasPrefix("/compact "))
            #expect(!text.contains("\n") && !text.contains("\r"))
            #expect(text.contains(" 7. "))
        }
    }

    @Test("both prompts fit in one paste: a /compact longer than about 600 characters arrives as a plain message")
    func fitsInOnePaste() {
        // Checked 2026-11-23 in an interactive session: 582 characters ran as /compact, 1,070 did not.
        for text in [Self.english, Self.korean, CompactPrompt.text] {
            #expect(text.count <= 600)
        }
    }

    @Test("the app hands out one of the two prompts")
    func runtimeTextIsOneOfThem() {
        #expect([Self.english, Self.korean].contains(CompactPrompt.text))
    }
}
