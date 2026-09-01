import Foundation

/// Splits a byte stream into JSONL records.
///
/// `pi --mode rpc` specifies strict JSONL framing: LF (`\n`) is the *only* record
/// delimiter, and a trailing CR is stripped. This framer works on raw bytes rather
/// than `String` lines on purpose — Swift's line-splitting APIs (like
/// `String.enumerateLines` and `components(separatedBy: .newlines)`) also break on
/// U+2028/U+2029, which are legal *inside* JSON strings and would corrupt records.
public struct JSONLFramer {
    private static let lineFeed: UInt8 = 0x0A
    private static let carriageReturn: UInt8 = 0x0D

    private var buffer = Data()

    /// Upper bound on a single record, so a peer that never emits a newline
    /// cannot grow this buffer without limit.
    public let maximumRecordBytes: Int

    public init(maximumRecordBytes: Int = 64 * 1024 * 1024) {
        self.maximumRecordBytes = maximumRecordBytes
    }

    public enum FramingError: Error, CustomStringConvertible {
        case recordTooLarge(bytes: Int)

        public var description: String {
            switch self {
            case let .recordTooLarge(bytes):
                return "JSONL record exceeded \(bytes) bytes without a newline"
            }
        }
    }

    /// Appends freshly read bytes and returns every complete record they closed.
    /// Empty records (blank lines) are skipped; the protocol never sends them.
    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)

        var records: [Data] = []
        var searchStart = buffer.startIndex

        while let newlineIndex = buffer[searchStart...].firstIndex(of: Self.lineFeed) {
            var record = buffer[searchStart..<newlineIndex]
            if record.last == Self.carriageReturn {
                record = record.dropLast()
            }
            if !record.isEmpty {
                records.append(Data(record))
            }
            searchStart = buffer.index(after: newlineIndex)
        }

        buffer = searchStart == buffer.endIndex ? Data() : Data(buffer[searchStart...])

        if buffer.count > maximumRecordBytes {
            let overflow = buffer.count
            buffer = Data()
            throw FramingError.recordTooLarge(bytes: overflow)
        }

        return records
    }

    /// Returns any trailing bytes not terminated by a newline. A well-behaved peer
    /// leaves nothing here; a peer killed mid-write may leave a partial record,
    /// which callers should treat as garbage rather than as a message.
    public mutating func flush() -> Data? {
        defer { buffer = Data() }
        return buffer.isEmpty ? nil : buffer
    }
}
