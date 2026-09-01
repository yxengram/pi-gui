import Foundation

/// Locates the `pi` executable.
///
/// An app launched from Finder or the Dock inherits a minimal `PATH` (typically
/// `/usr/bin:/bin:/usr/sbin:/sbin`), not the login shell's, so a `pi` installed by
/// Homebrew, mise, volta or npm is invisible to a naive lookup. This mirrors the
/// PATH augmentation the Electron app needed for the same reason.
public struct PiExecutable: Sendable {
    public let url: URL
    /// The PATH a child process should inherit, augmented with the usual install roots.
    public let augmentedPath: String

    public init(url: URL, augmentedPath: String) {
        self.url = url
        self.augmentedPath = augmentedPath
    }

    /// Directories to append to an inherited PATH, in priority order.
    static func candidateDirectories(home: URL) -> [String] {
        [
            "/opt/homebrew/bin",          // Homebrew on Apple Silicon
            "/usr/local/bin",             // Homebrew on Intel, manual installs
            home.appendingPathComponent(".local/bin").path,
            home.appendingPathComponent(".bun/bin").path,
            home.appendingPathComponent(".volta/bin").path,
            home.appendingPathComponent(".local/share/mise/shims").path,
            home.appendingPathComponent(".asdf/shims").path,
            home.appendingPathComponent(".npm-global/bin").path,
            home.appendingPathComponent(".nvm/versions/node/current/bin").path,
            "/usr/bin",
            "/bin",
        ]
    }

    /// Builds a PATH from the inherited one plus the candidate roots, preserving
    /// inherited precedence and dropping duplicates.
    public static func augmentedPath(
        inherited: String?,
        home: URL = URL(fileURLWithPath: NSHomeDirectory())
    ) -> String {
        var seen = Set<String>()
        var ordered: [String] = []

        func append(_ directory: String) {
            let trimmed = directory.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return }
            ordered.append(trimmed)
        }

        (inherited ?? "").split(separator: ":", omittingEmptySubsequences: true).forEach { append(String($0)) }
        candidateDirectories(home: home).forEach(append)
        return ordered.joined(separator: ":")
    }

    /// Resolves `pi`, honouring an explicit override first.
    ///
    /// - Parameter override: An absolute path chosen by the user in Settings. When
    ///   present it is used verbatim so a deliberate choice is never second-guessed.
    public static func resolve(
        override: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = URL(fileURLWithPath: NSHomeDirectory()),
        fileManager: FileManager = .default
    ) throws -> PiExecutable {
        let path = augmentedPath(inherited: environment["PATH"], home: home)

        if let override, !override.isEmpty {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            guard fileManager.isExecutableFile(atPath: url.path) else {
                throw PiRPCError.executableNotFound(searched: [url.path])
            }
            return PiExecutable(url: url, augmentedPath: path)
        }

        let searched = path.split(separator: ":").map(String.init)
        for directory in searched {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("pi")
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return PiExecutable(url: candidate, augmentedPath: path)
            }
        }
        throw PiRPCError.executableNotFound(searched: searched)
    }
}
