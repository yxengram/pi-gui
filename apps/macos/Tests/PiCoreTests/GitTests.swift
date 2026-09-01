import XCTest
@testable import PiCore

/// Fixtures here are byte-for-byte output from a real `git`, so a change in git's
/// porcelain format shows up as a failing test rather than a mis-rendered panel.
final class GitStatusParsingTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
        return try Data(contentsOf: url)
    }

    private func realStatusOutput() throws -> String {
        String(decoding: try fixture("status-porcelain-z.bin"), as: UTF8.self)
    }

    func testParsesEveryStatusInRealOutput() throws {
        let files = GitCommand.parsePorcelainZ(try realStatusOutput())
        XCTAssertEqual(files.map(\.path), [
            "deleted.txt",
            "kept.txt",
            "renamed-to.txt",
            "staged-new.txt",
            "untracked file with spaces.txt",
        ])
        XCTAssertEqual(files.map(\.status), [.deleted, .modified, .renamed, .added, .untracked])
    }

    /// A rename emits two NUL records: the new path, then the old one. Consuming the
    /// second as if it were its own entry would invent a phantom file.
    func testRenameConsumesItsOriginalPathRecord() throws {
        let files = GitCommand.parsePorcelainZ(try realStatusOutput())
        let renamed = try XCTUnwrap(files.first { $0.status == .renamed })
        XCTAssertEqual(renamed.path, "renamed-to.txt")
        XCTAssertEqual(renamed.originalPath, "renamed-from.txt")
        XCTAssertFalse(files.contains { $0.path == "renamed-from.txt" })
    }

    /// The whole reason for `-z`: paths with spaces arrive unquoted and unescaped.
    func testPathWithSpacesSurvivesIntact() throws {
        let files = GitCommand.parsePorcelainZ(try realStatusOutput())
        XCTAssertTrue(files.contains { $0.path == "untracked file with spaces.txt" })
    }

    func testStagedFlagReflectsIndexColumn() throws {
        let files = GitCommand.parsePorcelainZ(try realStatusOutput())
        let byPath = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0) })
        XCTAssertEqual(byPath["staged-new.txt"]?.isStaged, true)
        XCTAssertEqual(byPath["renamed-to.txt"]?.isStaged, true)
        XCTAssertEqual(byPath["kept.txt"]?.isStaged, false)
        XCTAssertEqual(byPath["untracked file with spaces.txt"]?.isStaged, false)
    }

    func testEmptyStatusMeansCleanTree() {
        XCTAssertTrue(GitCommand.parsePorcelainZ("").isEmpty)
    }

    func testFileNameAndDirectoryAreSplitFromPath() {
        let file = ChangedFile(path: "Sources/PiCore/Thing.swift", status: .modified, isStaged: false)
        XCTAssertEqual(file.fileName, "Thing.swift")
        XCTAssertEqual(file.directory, "Sources/PiCore")
    }
}

final class UnifiedDiffTests: XCTestCase {
    private func realDiff() throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/kept.diff", withExtension: nil))
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testCountsAdditionsAndDeletions() throws {
        let diff = UnifiedDiff.parse(try realDiff())
        XCTAssertEqual(diff.additions, 2)
        XCTAssertEqual(diff.deletions, 1)
    }

    /// Gutter numbers must be real file positions taken from the hunk header, not
    /// offsets within the diff text.
    func testAssignsRealFileLineNumbers() throws {
        let diff = UnifiedDiff.parse(try realDiff())

        let added = diff.lines.filter { $0.kind == .addition }
        XCTAssertEqual(added.map(\.text), ["TWO", "four"])
        XCTAssertEqual(added.map(\.newLineNumber), [2, 4])
        XCTAssertEqual(added.map(\.oldLineNumber), [nil, nil])

        let removed = diff.lines.filter { $0.kind == .deletion }
        XCTAssertEqual(removed.map(\.text), ["two"])
        XCTAssertEqual(removed.map(\.oldLineNumber), [2])
    }

    func testStripsLeadingMarkerFromContentLines() throws {
        let diff = UnifiedDiff.parse(try realDiff())
        let context = diff.lines.filter { $0.kind == .context }
        XCTAssertEqual(context.map(\.text), ["one", "three", ""])
    }

    func testClassifiesHeadersSeparatelyFromContent() throws {
        let diff = UnifiedDiff.parse(try realDiff())
        XCTAssertTrue(diff.lines.contains { $0.kind == .fileHeader && $0.text.hasPrefix("diff --git") })
        XCTAssertTrue(diff.lines.contains { $0.kind == .hunkHeader && $0.text.hasPrefix("@@") })
    }

    func testParsesHunkHeaderStartLines() {
        XCTAssertEqual(UnifiedDiff.parseHunkHeader("@@ -1,3 +1,4 @@").old, 1)
        XCTAssertEqual(UnifiedDiff.parseHunkHeader("@@ -1,3 +1,4 @@").new, 1)
        // A new file starts the old side at 0.
        XCTAssertEqual(UnifiedDiff.parseHunkHeader("@@ -0,0 +1 @@").old, 0)
        XCTAssertEqual(UnifiedDiff.parseHunkHeader("@@ -0,0 +1 @@").new, 1)
        // Single-line hunks omit the count.
        XCTAssertEqual(UnifiedDiff.parseHunkHeader("@@ -12 +14 @@").old, 12)
        XCTAssertEqual(UnifiedDiff.parseHunkHeader("@@ -12 +14 @@").new, 14)
    }

    func testNoNewlineMarkerIsNotTreatedAsContent() {
        let diff = UnifiedDiff.parse("@@ -1 +1 @@\n-a\n+b\n\\ No newline at end of file\n")
        XCTAssertEqual(diff.additions, 1)
        XCTAssertEqual(diff.deletions, 1)
        XCTAssertTrue(diff.lines.contains { $0.kind == .fileHeader && $0.text.hasPrefix("\\") })
    }
}

final class WorktreeManagerTests: XCTestCase {
    private func realWorktreeList() throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/worktree-list.porcelain.txt", withExtension: nil))
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testParsesWorktreeRecords() throws {
        let worktrees = WorktreeManager.parseWorktreeList(try realWorktreeList())
        XCTAssertEqual(worktrees.count, 2)
        XCTAssertEqual(worktrees.map(\.branch), ["main", "feature-x"])
        XCTAssertEqual(worktrees[0].head, "58a05a489020ad67891215949a4c01fb168e91c3")
    }

    /// Only the first record is the repository's own checkout; misidentifying it
    /// would let removal target the user's real project directory.
    func testFirstRecordIsPrimaryAndOthersAreNot() throws {
        let worktrees = WorktreeManager.parseWorktreeList(try realWorktreeList())
        XCTAssertTrue(worktrees[0].isPrimary)
        XCTAssertFalse(worktrees[1].isPrimary)
    }

    func testStripsRefsHeadsPrefixFromBranch() {
        let worktrees = WorktreeManager.parseWorktreeList("worktree /tmp/a\nbranch refs/heads/topic/nested\n")
        XCTAssertEqual(worktrees.first?.branch, "topic/nested")
    }

    func testDetachedWorktreeHasNoBranch() {
        let worktrees = WorktreeManager.parseWorktreeList("worktree /tmp/a\nHEAD abc123\ndetached\n")
        XCTAssertEqual(worktrees.count, 1)
        XCTAssertNil(worktrees.first?.branch)
        XCTAssertEqual(worktrees.first?.head, "abc123")
    }

    func testSlugIsFilesystemSafe() {
        XCTAssertEqual(WorktreeManager.slug(for: "Fix the Login Bug!", fallback: "thread"), "fix-the-login-bug")
        XCTAssertEqual(WorktreeManager.slug(for: "a/b\\c:d", fallback: "thread"), "a-b-c-d")
        XCTAssertEqual(WorktreeManager.slug(for: "   ", fallback: "thread"), "thread")
        XCTAssertEqual(WorktreeManager.slug(for: "!!!", fallback: "thread"), "thread")
        XCTAssertLessThanOrEqual(WorktreeManager.slug(for: String(repeating: "x", count: 200), fallback: "t").count, 40)
    }

    /// Removal must refuse anything it did not create — the guard that stands
    /// between a stale record and deleting a user's project.
    func testRemovalRefusesPrimaryAndOutsidePaths() throws {
        let git = try GitCommand(executableURL: URL(fileURLWithPath: "/usr/bin/git"))
        let root = URL(fileURLWithPath: "/tmp/pi-gui-worktrees")
        let manager = WorktreeManager(git: git, worktreeRoot: root)

        let primary = Worktree(path: root.appendingPathComponent("a"), branch: "main", head: nil, isPrimary: true)
        XCTAssertThrowsError(try manager.removeWorktree(repository: root, worktree: primary))

        let outside = Worktree(path: URL(fileURLWithPath: "/Users/dev/project"), branch: "x", head: nil, isPrimary: false)
        XCTAssertThrowsError(try manager.removeWorktree(repository: root, worktree: outside))
    }
}
