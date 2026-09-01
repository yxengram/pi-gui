import Foundation
import PiCore

/// App preferences, persisted in `UserDefaults`.
///
/// Only view state and app-local choices live here. Provider credentials, model
/// configuration and session data all belong to pi and are deliberately not
/// duplicated — a second copy would be one more thing to drift out of sync.
public final class Preferences: @unchecked Sendable {
    public static let shared = Preferences()

    private let defaults: UserDefaults

    private enum Key {
        static let workspaces = "workspaces"
        static let archivedThreads = "archivedThreadPaths"
        static let piExecutablePath = "piExecutablePath"
        static let showThinking = "showThinking"
        static let terminalShell = "terminalShell"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var workspaces: [Workspace] {
        get {
            guard let data = defaults.data(forKey: Key.workspaces),
                  let decoded = try? JSONDecoder().decode([Workspace].self, from: data) else { return [] }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Key.workspaces)
        }
    }

    public var archivedThreadPaths: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.archivedThreads) ?? []) }
        set { defaults.set(Array(newValue), forKey: Key.archivedThreads) }
    }

    /// An explicit path to `pi`, for installs the PATH search cannot reach.
    public var piExecutablePath: String? {
        get {
            let value = defaults.string(forKey: Key.piExecutablePath)
            return (value?.isEmpty ?? true) ? nil : value
        }
        set { defaults.set(newValue, forKey: Key.piExecutablePath) }
    }

    public var showThinking: Bool {
        get { defaults.object(forKey: Key.showThinking) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.showThinking) }
    }

    /// Shell for the integrated terminal.
    ///
    /// The settings field stores an empty string when the user clears it, so empty
    /// must mean "unset" — otherwise the terminal would try to spawn "".
    public var terminalShell: String {
        get {
            let configured = defaults.string(forKey: Key.terminalShell)?
                .trimmingCharacters(in: .whitespaces)
            if let configured, !configured.isEmpty { return configured }
            return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        }
        set { defaults.set(newValue, forKey: Key.terminalShell) }
    }

    /// Where per-thread git worktrees are created — inside Application Support, never
    /// inside the user's project.
    public var worktreeRoot: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("pi-gui", isDirectory: true)
            .appendingPathComponent("worktrees", isDirectory: true)
    }
}
