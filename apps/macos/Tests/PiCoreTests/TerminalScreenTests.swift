import XCTest
@testable import PiCore

final class TerminalScreenTests: XCTestCase {
    private func render(_ chunks: String...) -> String {
        var screen = TerminalScreen()
        for chunk in chunks { screen.append(chunk) }
        return screen.text
    }

    func testPlainTextAndNewlines() {
        XCTAssertEqual(render("one\ntwo\n"), "one\ntwo")
        XCTAssertEqual(render("one\ntwo"), "one\ntwo")
    }

    /// A progress bar rewrites its line with CR; showing every intermediate state
    /// would fill the pane with duplicates of the same line.
    func testCarriageReturnRewritesCurrentLine() {
        XCTAssertEqual(render("50%\r100%"), "100%")
        XCTAssertEqual(render("50%\r100%\ndone"), "100%\ndone")
    }

    func testBackspaceErases() {
        XCTAssertEqual(render("abc\u{08}\u{08}X"), "aX")
        // Backspace at the start of a line must not underflow.
        XCTAssertEqual(render("\u{08}\u{08}a"), "a")
    }

    func testStripsColorCodes() {
        XCTAssertEqual(render("\u{1B}[31mred\u{1B}[0m done"), "red done")
    }

    func testStripsCursorMovementAndEraseSequences() {
        XCTAssertEqual(render("a\u{1B}[2Kb\u{1B}[1;5Hc"), "abc")
    }

    /// A window title sequence is OSC-terminated by BEL, not by a CSI final byte.
    func testStripsOperatingSystemCommandTerminatedByBell() {
        XCTAssertEqual(render("\u{1B}]0;my title\u{07}prompt$ "), "prompt$ ")
    }

    func testStripsOperatingSystemCommandTerminatedByStringTerminator() {
        XCTAssertEqual(render("\u{1B}]0;title\u{1B}\\text"), "text")
    }

    /// Escape sequences routinely straddle read boundaries; state must carry over.
    func testEscapeSequenceSplitAcrossChunks() {
        XCTAssertEqual(render("red:\u{1B}", "[31mvalue"), "red:value")
        XCTAssertEqual(render("a\u{1B}[", "0mb"), "ab")
    }

    func testKeepsTabsButDropsOtherControlCharacters() {
        XCTAssertEqual(render("a\tb"), "a\tb")
        XCTAssertEqual(render("a\u{01}\u{02}b"), "ab")
        XCTAssertEqual(render("bell\u{07}"), "bell")
    }

    func testScrollbackIsCapped() {
        var screen = TerminalScreen(scrollbackLimit: 10)
        for index in 0..<100 { screen.append("line \(index)\n") }
        XCTAssertEqual(screen.lines.count, 10)
        XCTAssertEqual(screen.lines.first, "line 90")
        XCTAssertEqual(screen.lines.last, "line 99")
    }

    func testClearResetsEverything() {
        var screen = TerminalScreen()
        screen.append("stuff\npartial")
        screen.clear()
        XCTAssertEqual(screen.text, "")
        XCTAssertTrue(screen.lines.isEmpty)
    }

    func testUnicodeSurvives() {
        XCTAssertEqual(render("✓ done 🙂\n"), "✓ done 🙂")
    }
}
