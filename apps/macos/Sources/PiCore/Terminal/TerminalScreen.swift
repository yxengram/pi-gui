import Foundation

/// A line-oriented terminal screen.
///
/// This is deliberately *not* a full VT emulator. It handles the control sequences
/// that ordinary command-line tools actually emit — newlines, carriage returns,
/// backspaces, and SGR colour codes it discards — which covers builds, tests, git
/// and package managers. Full-screen programs (vim, top) need real cursor
/// addressing and are out of scope; `TerminalScreen` renders their escape traffic
/// as no-ops rather than pretending to support them.
public struct TerminalScreen: Sendable {
    /// Completed lines, oldest first.
    public private(set) var lines: [String] = []
    /// The line still being written.
    public private(set) var currentLine: String = ""
    /// Cap on retained scrollback, so a runaway process cannot exhaust memory.
    public let scrollbackLimit: Int

    private enum ParserState {
        case text
        /// Saw ESC, waiting to learn which sequence this is.
        case escape
        /// Inside CSI (`ESC [`), consuming until a final byte in @–~.
        case controlSequence
        /// Inside OSC (`ESC ]`), consuming until BEL or ST.
        case operatingSystemCommand
    }

    private var state: ParserState = .text

    public init(scrollbackLimit: Int = 5_000) {
        self.scrollbackLimit = scrollbackLimit
    }

    /// All visible text, including the line in progress.
    public var text: String {
        currentLine.isEmpty ? lines.joined(separator: "\n") : (lines + [currentLine]).joined(separator: "\n")
    }

    public mutating func clear() {
        lines = []
        currentLine = ""
        state = .text
    }

    public mutating func append(_ chunk: String) {
        for character in chunk {
            consume(character)
        }
        trimScrollback()
    }

    private mutating func consume(_ character: Character) {
        switch state {
        case .escape:
            switch character {
            case "[": state = .controlSequence
            case "]": state = .operatingSystemCommand
            default: state = .text   // A two-character sequence; nothing to render.
            }

        case .controlSequence:
            // CSI parameters are 0x30–0x3F and intermediates 0x20–0x2F; the sequence
            // ends at the first final byte in 0x40–0x7E.
            if let ascii = character.asciiValue, (0x40...0x7E).contains(ascii) {
                state = .text
            }

        case .operatingSystemCommand:
            // Terminated by BEL, or by ST (ESC \) whose ESC restarts the escape state.
            if character == "\u{07}" {
                state = .text
            } else if character == "\u{1B}" {
                state = .escape
            }

        case .text:
            switch character {
            case "\u{1B}":
                state = .escape
            case "\n":
                lines.append(currentLine)
                currentLine = ""
            case "\r":
                // A progress bar rewrites its line in place; dropping the content is
                // what makes the final state show rather than every intermediate one.
                currentLine = ""
            case "\u{08}", "\u{7F}":
                if !currentLine.isEmpty { currentLine.removeLast() }
            case "\u{07}":
                break   // Bell.
            default:
                // Other C0 controls would render as boxes; only tab is meaningful.
                if let ascii = character.asciiValue, ascii < 0x20, character != "\t" {
                    break
                }
                currentLine.append(character)
            }
        }
    }

    private mutating func trimScrollback() {
        guard lines.count > scrollbackLimit else { return }
        lines.removeFirst(lines.count - scrollbackLimit)
    }
}
