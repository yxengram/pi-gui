import XCTest
@testable import PiCore

final class TimelineBuilderTests: XCTestCase {
    private func activeBranch() throws -> [SessionEntry] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/session-branching.jsonl", withExtension: nil))
        let entries = try SessionParser.parse(contentsOf: url).entries
        return SessionTree(entries: entries).branch(endingAt: "aa000004")
    }

    func testProjectsConversationInOrder() throws {
        let items = TimelineBuilder.build(branch: try activeBranch())
        let kinds = items.map(\.kind)
        // bash runs, then prompt, thinking, prose, tool call, closing prose.
        XCTAssertEqual(Array(kinds.suffix(5)), [.userMessage, .thinking, .assistantMessage, .toolCall, .assistantMessage])
    }

    /// The call and its result are separate session entries; the timeline must join
    /// them into one collapsible row rather than showing an orphan result.
    func testToolCallIsJoinedWithItsResult() throws {
        let items = TimelineBuilder.build(branch: try activeBranch())
        let toolItem = try XCTUnwrap(items.first { $0.id == "call_ls_1" })
        let tool = try XCTUnwrap(toolItem.tool)
        XCTAssertEqual(tool.name, "bash")
        XCTAssertEqual(tool.summary, "ls src")
        XCTAssertEqual(tool.output, "main.swift\nutil.swift")
        XCTAssertFalse(tool.isError)
        XCTAssertFalse(tool.isRunning)
    }

    func testToolResultDoesNotAlsoRenderAsItsOwnRow() throws {
        let items = TimelineBuilder.build(branch: try activeBranch())
        XCTAssertFalse(items.contains { $0.id == "aa000003" })
    }

    /// A call with no result yet is what the user sees mid-run; it must read as running.
    func testToolCallWithoutResultIsMarkedRunning() {
        let assistant = JSONValue.object([
            "type": .string("message"), "id": .string("m1"), "parentId": .null,
            "message": .object([
                "role": .string("assistant"),
                "content": .array([.object([
                    "type": .string("toolCall"), "id": .string("call_x"),
                    "name": .string("read"), "arguments": .object(["file_path": .string("/tmp/a")]),
                ])]),
            ]),
        ])
        let entry = SessionEntry(id: "m1", parentID: nil, kind: .message, timestamp: nil, payload: assistant)
        let tool = TimelineBuilder.build(branch: [entry]).first?.tool
        XCTAssertEqual(tool?.isRunning, true)
        XCTAssertNil(tool?.output ?? nil)
        XCTAssertEqual(tool?.summary, "/tmp/a")
    }

    /// Captured from a real pi run: bash execution carries output/exitCode on the
    /// message itself, not as a separate toolResult entry.
    func testBashExecutionEntryRendersWithExitStatus() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/session-branching.jsonl", withExtension: nil))
        let entries = try SessionParser.parse(contentsOf: url).entries
        let items = TimelineBuilder.build(branch: SessionTree(entries: entries).branch(endingAt: "aa000004"))

        let ok = try XCTUnwrap(items.first { $0.id == "35865648" }?.tool)
        XCTAssertEqual(ok.summary, "echo first-command")
        XCTAssertEqual(ok.output, "first-command\n")
        XCTAssertFalse(ok.isError)

        let failed = try XCTUnwrap(items.first { $0.id == "afc3b17f" }?.tool)
        XCTAssertTrue(failed.isError, "a non-zero exit must read as an error")
    }

    func testThinkingCanBeSuppressed() throws {
        let items = TimelineBuilder.build(branch: try activeBranch(), includeThinking: false)
        XCTAssertFalse(items.contains { $0.kind == .thinking })
    }

    /// State-change entries are not conversation and must stay out of the transcript.
    func testBookkeepingEntriesAreNotRendered() throws {
        let items = TimelineBuilder.build(branch: try activeBranch())
        XCTAssertFalse(items.contains { $0.id == "0b7e1291" })  // model_change
        XCTAssertFalse(items.contains { $0.id == "25f4ccf7" })  // thinking_level_change
        XCTAssertFalse(items.contains { $0.id == "bf2651c1" })  // session_info
    }

    /// A run can fail after the prompt is accepted: pi answers the command with
    /// success, then the turn ends with stopReason "error", an errorMessage, and
    /// empty content. This fixture is that exact event, captured from a real pi.
    /// Without the errorMessage fallback the turn would render as nothing at all.
    func testFailedAssistantTurnFromRealEventSurfacesItsError() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/event-turn-end-failed.json", withExtension: nil))
        let event = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        let message = try XCTUnwrap(event["message"])

        XCTAssertEqual(message["stopReason"]?.stringValue, "error")
        XCTAssertEqual(message["content"]?.arrayValue?.isEmpty, true)
        XCTAssertNil(AgentMessageText.plainText(from: message))

        let entry = SessionEntry(
            id: "e1", parentID: nil, kind: .message, timestamp: nil,
            payload: .object(["message": message])
        )
        let items = TimelineBuilder.build(branch: [entry])
        XCTAssertEqual(items.first?.kind, .notice)
        XCTAssertEqual(items.first?.text, message["errorMessage"]?.stringValue)
    }

    func testHiddenCustomMessageIsNotRendered() {
        let visible = SessionEntry(
            id: "c1", parentID: nil, kind: .customMessage, timestamp: nil,
            payload: .object(["content": .string("shown"), "display": .bool(true)])
        )
        let hidden = SessionEntry(
            id: "c2", parentID: nil, kind: .customMessage, timestamp: nil,
            payload: .object(["content": .string("hidden"), "display": .bool(false)])
        )
        let items = TimelineBuilder.build(branch: [visible, hidden])
        XCTAssertEqual(items.map(\.text), ["shown"])
    }

    func testCompactionAndBranchSummariesAppear() {
        let compaction = SessionEntry(
            id: "k1", parentID: nil, kind: .compaction, timestamp: nil,
            payload: .object(["summary": .string("earlier work")])
        )
        let branchSummary = SessionEntry(
            id: "k2", parentID: "k1", kind: .branchSummary, timestamp: nil,
            payload: .object(["summary": .string("abandoned path")])
        )
        let items = TimelineBuilder.build(branch: [compaction, branchSummary])
        XCTAssertEqual(items.map(\.kind), [.compactionSummary, .branchSummary])
    }
}

final class AgentMessageTextTests: XCTestCase {
    /// Both content shapes occur in real sessions: a bare string and typed blocks.
    func testReadsBareStringContent() {
        let message = JSONValue.object(["role": .string("user"), "content": .string("hello")])
        XCTAssertEqual(AgentMessageText.plainText(from: message), "hello")
    }

    func testReadsBlockArrayContentAndIgnoresNonText() {
        let message = JSONValue.object(["content": .array([
            .object(["type": .string("text"), "text": .string("a")]),
            .object(["type": .string("thinking"), "thinking": .string("ignored")]),
            .object(["type": .string("text"), "text": .string("b")]),
        ])])
        XCTAssertEqual(AgentMessageText.plainText(from: message), "ab")
        XCTAssertEqual(AgentMessageText.thinkingText(from: message), "ignored")
    }

    func testEmptyContentIsNilNotEmptyString() {
        XCTAssertNil(AgentMessageText.plainText(from: .object(["content": .string("")])))
        XCTAssertNil(AgentMessageText.plainText(from: .object(["content": .array([])])))
        XCTAssertNil(AgentMessageText.plainText(from: nil))
    }

    func testExtractsImages() {
        let message = JSONValue.object(["content": .array([
            .object([
                "type": .string("image"),
                "data": .string("QUJD"),
                "mimeType": .string("image/png"),
            ]),
        ])])
        XCTAssertEqual(AgentMessageText.images(from: message).first?.mimeType, "image/png")
    }

    func testToolCallSummaryPrefersCommandThenPath() {
        let withCommand = AgentMessageText.ToolCall(
            id: "1", name: "bash", arguments: .object(["command": .string("ls -la")])
        )
        XCTAssertEqual(withCommand.summary, "ls -la")

        let withPath = AgentMessageText.ToolCall(
            id: "2", name: "read", arguments: .object(["file_path": .string("/tmp/x")])
        )
        XCTAssertEqual(withPath.summary, "/tmp/x")

        let opaque = AgentMessageText.ToolCall(id: "3", name: "custom", arguments: .object([:]))
        XCTAssertEqual(opaque.summary, "")
    }

    func testPreviewCollapsesWhitespaceAndTruncates() {
        XCTAssertEqual("a\n\n  b\tc".singleLinePreview(limit: 100), "a b c")
        XCTAssertEqual(String(repeating: "x", count: 20).singleLinePreview(limit: 5), "xxxxx…")
    }
}
