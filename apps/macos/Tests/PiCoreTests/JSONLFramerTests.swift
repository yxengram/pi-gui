import XCTest
@testable import PiCore

/// The framer is the one piece where a subtle bug corrupts every message, so it is
/// tested against the exact hazards pi's RPC docs call out.
final class JSONLFramerTests: XCTestCase {
    private func frame(_ framer: inout JSONLFramer, _ text: String) throws -> [String] {
        let records = try framer.append(Data(text.utf8))
        return records.map { String(decoding: $0, as: UTF8.self) }
    }

    func testSplitsOnLineFeed() throws {
        var framer = JSONLFramer()
        XCTAssertEqual(try frame(&framer, "{\"a\":1}\n{\"b\":2}\n"), ["{\"a\":1}", "{\"b\":2}"])
    }

    func testReassemblesRecordSplitAcrossReads() throws {
        var framer = JSONLFramer()
        XCTAssertEqual(try frame(&framer, "{\"a\":"), [])
        XCTAssertEqual(try frame(&framer, "1}\n"), ["{\"a\":1}"])
    }

    func testStripsTrailingCarriageReturn() throws {
        var framer = JSONLFramer()
        XCTAssertEqual(try frame(&framer, "{\"a\":1}\r\n"), ["{\"a\":1}"])
    }

    /// U+2028/U+2029 are valid inside JSON strings. Splitting on them — as several
    /// stock line readers do — would truncate a record mid-string.
    func testDoesNotSplitOnUnicodeLineSeparators() throws {
        var framer = JSONLFramer()
        let record = "{\"text\":\"before\u{2028}after\u{2029}end\"}"
        XCTAssertEqual(try frame(&framer, record + "\n"), [record])
    }

    func testSkipsBlankLines() throws {
        var framer = JSONLFramer()
        XCTAssertEqual(try frame(&framer, "\n\n{\"a\":1}\n\n"), ["{\"a\":1}"])
    }

    func testPreservesMultibyteCharactersAcrossChunkBoundary() throws {
        var framer = JSONLFramer()
        // Split a 4-byte emoji down the middle of its UTF-8 encoding.
        let full = Array("{\"t\":\"🙂\"}\n".utf8)
        let cut = 8
        XCTAssertEqual(try framer.append(Data(full[..<cut])).count, 0)
        let records = try framer.append(Data(full[cut...]))
        XCTAssertEqual(records.map { String(decoding: $0, as: UTF8.self) }, ["{\"t\":\"🙂\"}"])
    }

    func testFlushReturnsUnterminatedTail() throws {
        var framer = JSONLFramer()
        _ = try frame(&framer, "{\"a\":1}\n{\"partial\"")
        XCTAssertEqual(framer.flush().map { String(decoding: $0, as: UTF8.self) }, "{\"partial\"")
        XCTAssertNil(framer.flush())
    }

    func testThrowsWhenRecordExceedsCap() {
        var framer = JSONLFramer(maximumRecordBytes: 16)
        XCTAssertThrowsError(try framer.append(Data(String(repeating: "x", count: 64).utf8)))
    }
}
