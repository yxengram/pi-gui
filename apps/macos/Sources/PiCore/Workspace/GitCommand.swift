import Foundation

/// Runs `git` and returns its output.
///
/// Everything git-related in this app shells out rather than linking libgit2: the
/// user's repo already has a git that understands their config, credential helpers
/// and hooks, and matching it exactly matters more than saving a process spawn.
public struct GitCommand: Sendable {
    public struct Result: Sendable {
        public let standardOutput: String
        public let standardError: String
        public let exitCode: Int32

        public var succeeded: Bool { exitCode == 0 }

        /// Output with the single trailing newline git adds, removed.
        public var trimmedOutput: String {
            standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    public enum Failure: Error, CustomStringConvertible {
        case gitUnavailable
        case failed(command: [String], exitCode: Int32, message: String)

        public var description: String {
            switch self {
            case .gitUnavailable:
                return "git was not found on PATH"
            case let .failed(command, exitCode, message):
                return "git \(command.joined(separator: " ")) failed (\(exitCode)): \(message)"
            }
        }
    }

    public let executableURL: URL

    public init(executableURL: URL? = nil, fileManager: FileManager = .default) throws {
        if let executableURL {
            self.executableURL = executableURL
            return
        }
        let candidates = ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
        guard let found = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) else {
            throw Failure.gitUnavailable
        }
        self.executableURL = URL(fileURLWithPath: found)
    }

    /// Runs git in `directory`, returning output regardless of exit status.
    @discardableResult
    public func run(_ arguments: [String], in directory: URL) throws -> Result {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = directory

        var environment = ProcessInfo.processInfo.environment
        // A GUI app has no terminal to prompt in; without this git can block forever
        // waiting on a credential or passphrase nobody can answer.
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Read before waiting: a repo with many changes can fill a pipe buffer, and
        // waiting first would deadlock against a child blocked on write.
        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return Result(
            standardOutput: String(decoding: outputData, as: UTF8.self),
            standardError: String(decoding: errorData, as: UTF8.self),
            exitCode: process.terminationStatus
        )
    }

    /// Runs git and throws unless it exits zero.
    @discardableResult
    public func require(_ arguments: [String], in directory: URL) throws -> Result {
        let result = try run(arguments, in: directory)
        guard result.succeeded else {
            throw Failure.failed(
                command: arguments,
                exitCode: result.exitCode,
                message: result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return result
    }

    // MARK: - Queries

    public func isRepository(_ directory: URL) -> Bool {
        guard let result = try? run(["rev-parse", "--is-inside-work-tree"], in: directory) else { return false }
        return result.succeeded && result.trimmedOutput == "true"
    }

    public func repositoryRoot(_ directory: URL) throws -> URL? {
        let result = try run(["rev-parse", "--show-toplevel"], in: directory)
        guard result.succeeded else { return nil }
        return URL(fileURLWithPath: result.trimmedOutput)
    }

    public func currentBranch(_ directory: URL) throws -> String? {
        let result = try run(["rev-parse", "--abbrev-ref", "HEAD"], in: directory)
        guard result.succeeded else { return nil }
        let name = result.trimmedOutput
        // Detached HEAD reports the literal "HEAD", which is not a branch name.
        return (name.isEmpty || name == "HEAD") ? nil : name
    }
}
