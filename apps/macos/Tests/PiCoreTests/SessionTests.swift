import XCTest
@testable import PiCore

final class SessionParsingTests: XCTestCase {
    private func fixtureURL(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
    }

    private func branchingSession() throws -> SessionFile {
        try SessionParser.parse(contentsOf: fixtureURL("session-branching.jsonl"))
    }

    func testParsesHeader() throws {
        let header = try XCTUnwrap(branchingSession().header)
        XCTAssertEqual(header.version, 3)
        XCTAssertEqual(header.id, "01a05cbb-f6d5-7df1-94f4-7bc7725c94e7")
        XCTAssertEqual(header.cwd, "/Users/dev/projects/demo")
        XCTAssertNotNil(header.timestamp)
    }

    /// The header is metadata, not a tree node — including it would give the tree a
    /// bogus root and shift every branch.
    func testHeaderIsNotAnEntry() throws {
        XCTAssertFalse(try branchingSession().entries.contains { $0.kind == .unknown("session") })
    }

    func testParsesEntryKinds() throws {
        let kinds = try branchingSession().entries.map(\.kind)
        XCTAssertEqual(kinds.first, .sessionInfo)
        XCTAssertTrue(kinds.contains(.modelChange))
        XCTAssertTrue(kinds.contains(.thinkingLevelChange))
        XCTAssertTrue(kinds.contains(.message))
    }

    func testDisplayNameComesFromSessionInfoEntry() throws {
        XCTAssertEqual(try branchingSession().displayName, "fixture thread")
    }

    /// A live pi process appends while the GUI reads, so a truncated tail must not
    /// throw away the records that did parse.
    func testPartialTrailingLineDoesNotDiscardEarlierEntries() throws {
        let data = try Data(contentsOf: fixtureURL("session-branching.jsonl"))
        let truncated = data.prefix(data.count - 40)
        let file = SessionParser.parse(data: Data(truncated), url: URL(fileURLWithPath: "/tmp/x.jsonl"))
        XCTAssertNotNil(file.header)
        XCTAssertGreaterThan(file.entries.count, 3)
    }

    func testUnknownEntryTypeIsRetainedAsUnknown() {
        let line = #"{"type":"future_kind","id":"zz","parentId":null,"timestamp":"2026-01-01T00:00:00.000Z"}"#
        let file = SessionParser.parse(data: Data((line + "\n").utf8), url: URL(fileURLWithPath: "/tmp/x.jsonl"))
        XCTAssertEqual(file.entries.first?.kind, .unknown("future_kind"))
    }

    func testParsesTimestampsWithAndWithoutFractionalSeconds() {
        XCTAssertNotNil(SessionTimestamp.parse("2026-09-01T11:30:17.429Z"))
        XCTAssertNotNil(SessionTimestamp.parse("2026-09-01T11:30:17Z"))
        XCTAssertNil(SessionTimestamp.parse("not a date"))
    }
}

/// The live path: entries arriving inside a `get_entries` response rather than as
/// lines of a file. Fixture is a real response from `pi --mode rpc`.
final class SessionEntryFromRPCTests: XCTestCase {
    private func response() throws -> JSONValue {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/get_entries_full.json", withExtension: nil))
        return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    }

    func testBuildsEntriesFromRealGetEntriesResponse() throws {
        let raw = try XCTUnwrap(response().path("data.entries")?.arrayValue)
        let entries = raw.compactMap(SessionEntry.init(json:))

        XCTAssertEqual(entries.count, raw.count, "every entry in a real response must parse")
        XCTAssertEqual(entries.first?.kind, .sessionInfo)
        XCTAssertEqual(entries.first?.sessionName, "fixture thread")
        XCTAssertNil(entries.first?.parentID, "the first entry roots the tree")
        XCTAssertTrue(entries.contains { $0.kind == .modelChange })
        XCTAssertNotNil(entries.last?.timestamp)
    }

    /// pi reports the active leaf; the app must prefer it over any local heuristic.
    func testResponseCarriesLeafID() throws {
        XCTAssertEqual(try response().path("data.leafId")?.stringValue, "afc3b17f")
    }

    /// A real bashExecution message keeps its output and exit code on the message
    /// itself rather than in a separate toolResult entry.
    func testRealBashExecutionEntryRendersAsAToolRow() throws {
        let raw = try XCTUnwrap(response().path("data.entries")?.arrayValue)
        let entries = raw.compactMap(SessionEntry.init(json:))
        let items = TimelineBuilder.build(branch: entries)

        let tool = try XCTUnwrap(items.last?.tool)
        XCTAssertEqual(tool.name, "bash")
        XCTAssertEqual(tool.summary, "ls /nonexistent-path-xyz")
        XCTAssertTrue(tool.isError, "exit code 2 must read as an error")
        XCTAssertEqual(tool.output?.contains("No such file or directory"), true)
    }

    func testMalformedEntryIsSkippedNotCrashed() {
        XCTAssertNil(SessionEntry(json: .object(["type": .string("message")])))   // no id
        XCTAssertNil(SessionEntry(json: .object(["id": .string("a")])))           // no type
        XCTAssertNil(SessionEntry(json: .string("not an object")))
    }
}

final class SessionTreeTests: XCTestCase {
    private func tree() throws -> SessionTree {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/session-branching.jsonl", withExtension: nil))
        return SessionTree(entries: try SessionParser.parse(contentsOf: url).entries)
    }

    func testBuildsSingleRoot() throws {
        XCTAssertEqual(try tree().rootIDs, ["bf2651c1"])
    }

    /// The fixture forks at aa000001 into the main path and an abandoned branch.
    func testFindsBothBranchTips() throws {
        XCTAssertEqual(Set(try tree().leafIDs), ["aa000004", "bb000001"])
    }

    func testBranchWalksRootToLeafInOrder() throws {
        let branch = try tree().branch(endingAt: "aa000004")
        XCTAssertEqual(branch.first?.id, "bf2651c1")
        XCTAssertEqual(branch.last?.id, "aa000004")
        // The abandoned branch must not leak into the active path.
        XCTAssertFalse(branch.contains { $0.id == "bb000001" })
    }

    func testSwitchingLeafSelectsTheOtherBranch() throws {
        let branch = try tree().branch(endingAt: "bb000001")
        XCTAssertEqual(branch.last?.id, "bb000001")
        XCTAssertFalse(branch.contains { $0.id == "aa000004" })
        // Both branches share everything up to the fork point.
        XCTAssertTrue(branch.contains { $0.id == "aa000001" })
    }

    func testOrphanEntryBecomesItsOwnRootRatherThanVanishing() {
        let entries = [
            SessionEntry(id: "a", parentID: nil, kind: .message, timestamp: nil, payload: .object([:])),
            SessionEntry(id: "b", parentID: "missing", kind: .message, timestamp: nil, payload: .object([:])),
        ]
        let tree = SessionTree(entries: entries)
        XCTAssertEqual(Set(tree.rootIDs), ["a", "b"])
        XCTAssertEqual(tree.branch(endingAt: "b").map(\.id), ["b"])
    }

    /// A corrupt file could link entries in a cycle; walking one must terminate.
    func testCyclicParentLinksDoNotHang() {
        let entries = [
            SessionEntry(id: "a", parentID: "b", kind: .message, timestamp: nil, payload: .object([:])),
            SessionEntry(id: "b", parentID: "a", kind: .message, timestamp: nil, payload: .object([:])),
        ]
        XCTAssertEqual(SessionTree(entries: entries).branch(endingAt: "a").count, 2)
    }

    /// pi resolves the leaf by file order, not by timestamp. Confirmed by resuming
    /// this exact fixture in a live `pi --mode rpc`, which reported `leafId` as
    /// bb000001 — the last line — even though aa000004 carries a newer timestamp.
    /// Diverging here would show a different branch than pi considers active.
    func testDefaultLeafMatchesPiAndUsesFileOrder() throws {
        XCTAssertEqual(try tree().defaultLeafID, "bb000001")
    }

    func testEmptyEntriesProduceEmptyBranch() {
        let tree = SessionTree(entries: [])
        XCTAssertTrue(tree.isEmpty)
        XCTAssertNil(tree.defaultLeafID)
        XCTAssertTrue(tree.activeBranch().isEmpty)
    }
}

final class SessionStoreTests: XCTestCase {
    /// Mirrors pi's own `getDefaultSessionDirPath`. If this drifts, the sidebar shows
    /// an empty thread list for a project that actually has sessions.
    func testEncodesWorkingDirectoryLikePi() {
        XCTAssertEqual(
            SessionStore.encodedDirectoryName(forWorkingDirectory: "/Users/matt/proj"),
            "--Users-matt-proj--"
        )
        XCTAssertEqual(SessionStore.encodedDirectoryName(forWorkingDirectory: "/"), "----")
    }

    func testEncodingReplacesColonsAndBackslashes() {
        XCTAssertEqual(
            SessionStore.encodedDirectoryName(forWorkingDirectory: "/a/b:c"),
            "--a-b-c--"
        )
    }

    func testSessionDirectoryIsUnderAgentSessions() {
        let store = SessionStore(agentDirectory: URL(fileURLWithPath: "/tmp/agent"))
        XCTAssertEqual(
            store.sessionDirectory(forWorkingDirectory: "/Users/matt/proj").path,
            "/tmp/agent/sessions/--Users-matt-proj--"
        )
    }

    func testListingAbsentDirectoryReturnsEmptyRatherThanThrowing() throws {
        let store = SessionStore(agentDirectory: URL(fileURLWithPath: "/tmp/definitely-not-here-\(UUID().uuidString)"))
        XCTAssertEqual(try store.listSessions(forWorkingDirectory: "/Users/matt/proj").count, 0)
    }

    func testSummarizeReadsNamePreviewAndCount() throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/session-branching.jsonl", withExtension: nil))
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let copy = directory.appendingPathComponent("session.jsonl")
        try FileManager.default.copyItem(at: source, to: copy)

        let summary = try XCTUnwrap(SessionStore().summarize(url: copy))
        XCTAssertEqual(summary.displayName, "fixture thread")
        XCTAssertEqual(summary.title, "fixture thread")
        XCTAssertEqual(summary.workingDirectory, "/Users/dev/projects/demo")
        XCTAssertEqual(summary.preview, "List the source files")
        // Branch-scoped, matching pi: a live pi resuming this same file reported
        // messageCount 4, while the file as a whole holds 7 message entries.
        XCTAssertEqual(summary.messageCount, 4)
    }

    func testTitleFallsBackToPreviewThenPlaceholder() {
        let base = SessionStore.Summary(
            url: URL(fileURLWithPath: "/tmp/a.jsonl"), sessionID: "s", displayName: nil,
            workingDirectory: nil, modifiedAt: .distantPast, messageCount: 0, preview: "do the thing"
        )
        XCTAssertEqual(base.title, "do the thing")

        let bare = SessionStore.Summary(
            url: URL(fileURLWithPath: "/tmp/a.jsonl"), sessionID: "s", displayName: nil,
            workingDirectory: nil, modifiedAt: .distantPast, messageCount: 0, preview: nil
        )
        XCTAssertEqual(bare.title, "Untitled thread")
    }
}
