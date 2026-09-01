import Foundation
import Darwin
import PiCore

/// A shell running on a pseudo-terminal.
///
/// A PTY rather than a plain pipe because interactive tools change behavior when
/// they detect they are not on a terminal: colour disappears, prompts vanish, and
/// pagers refuse to page. `posix_spawn` is used instead of `fork` since forking a
/// Cocoa process is unsafe — only async-signal-safe calls are legal between fork
/// and exec, which AppKit does not honour.
final class PTYProcess: @unchecked Sendable {
    private var primaryDescriptor: Int32 = -1
    private var processID: pid_t = -1
    private var readSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "pi-gui.pty")
    private let lock = NSLock()

    /// Called on the main queue with each decoded chunk of output.
    var onOutput: ((String) -> Void)?
    /// Called on the main queue when the shell exits.
    var onExit: ((Int32) -> Void)?

    private var isRunning = false

    enum Failure: Error, CustomStringConvertible {
        case ptyUnavailable(errno: Int32)
        case spawnFailed(errno: Int32)

        var description: String {
            switch self {
            case let .ptyUnavailable(code):
                return "Could not allocate a pseudo-terminal (errno \(code))"
            case let .spawnFailed(code):
                return "Could not start the shell (errno \(code))"
            }
        }
    }

    func start(shell: String, workingDirectory: URL, columns: Int = 100, rows: Int = 30) throws {
        guard !isAlive else { return }

        var primary: Int32 = 0
        var replica: Int32 = 0
        var size = winsize(
            ws_row: UInt16(rows),
            ws_col: UInt16(columns),
            ws_xpixel: 0,
            ws_ypixel: 0
        )

        guard openpty(&primary, &replica, nil, nil, &size) != -1 else {
            throw Failure.ptyUnavailable(errno: errno)
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }

        // The child talks over the replica end on all three standard descriptors.
        posix_spawn_file_actions_adddup2(&actions, replica, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, replica, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, replica, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, replica)
        posix_spawn_file_actions_addclose(&actions, primary)
        posix_spawn_file_actions_addchdir_np(&actions, workingDirectory.path)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Give the child its own session so it becomes the terminal's controlling
        // process; without this, job control and Ctrl-C do not work.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        // A GUI app's PATH is minimal; reuse the same augmentation pi gets.
        environment["PATH"] = PiExecutablePathHelper.augmentedPath(inherited: environment["PATH"])
        let environmentStrings = environment.map { "\($0.key)=\($0.value)" }

        let arguments = [shell, "-l"]
        var pid: pid_t = 0
        let status = withCStringArray(arguments) { argv in
            withCStringArray(environmentStrings) { envp in
                posix_spawn(&pid, shell, &actions, &attributes, argv, envp)
            }
        }
        close(replica)

        guard status == 0 else {
            close(primary)
            throw Failure.spawnFailed(errno: status)
        }

        primaryDescriptor = primary
        processID = pid
        lock.lock()
        isRunning = true
        lock.unlock()
        startReading()
        watchForExit()
    }

    private func startReading() {
        let descriptor = primaryDescriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = read(descriptor, &buffer, buffer.count)
            guard count > 0 else {
                if count == 0 { self.finish(code: 0) }
                return
            }
            let text = String(decoding: buffer[0..<count], as: UTF8.self)
            DispatchQueue.main.async { self.onOutput?(text) }
        }
        source.resume()
        readSource = source
    }

    private func watchForExit() {
        let pid = processID
        // Reaping on a background queue keeps a zombie from lingering and gives the
        // UI the real exit status.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            let code = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : status & 0x7F
            self?.finish(code: Int32(code))
        }
    }

    /// Whether the shell is still alive.
    var isAlive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRunning
    }

    func write(_ text: String) {
        guard isAlive, primaryDescriptor >= 0 else { return }
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBufferPointer { pointer in
            Darwin.write(primaryDescriptor, pointer.baseAddress, pointer.count)
        }
    }

    func resize(columns: Int, rows: Int) {
        guard isAlive, primaryDescriptor >= 0 else { return }
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(columns), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(primaryDescriptor, TIOCSWINSZ, &size)
    }

    func terminate() {
        guard isAlive else { return }
        // Signal the whole process group so children of the shell go too.
        kill(-processID, SIGTERM)
    }

    private func finish(code: Int32) {
        // Reached from both the read source (on `queue`) and the waitpid reaper (on a
        // global queue). A lock rather than `queue.sync`, which would deadlock when
        // the caller is already running on `queue`.
        lock.lock()
        guard isRunning else {
            lock.unlock()
            return
        }
        isRunning = false
        teardown()
        lock.unlock()

        DispatchQueue.main.async { self.onExit?(code) }
    }

    private func teardown() {
        readSource?.cancel()
        readSource = nil
        if primaryDescriptor >= 0 {
            close(primaryDescriptor)
            primaryDescriptor = -1
        }
    }

    deinit {
        if primaryDescriptor >= 0 { close(primaryDescriptor) }
    }
}

/// Bridges a Swift `[String]` into the NULL-terminated `char *[]` posix_spawn wants.
private func withCStringArray<Result>(
    _ values: [String],
    _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> Result
) -> Result {
    var pointers: [UnsafeMutablePointer<CChar>?] = values.map { strdup($0) }
    pointers.append(nil)
    defer { pointers.forEach { pointer in if let pointer { free(pointer) } } }
    return body(&pointers)
}

/// Reuses PiCore's PATH augmentation without exposing the executable lookup itself.
enum PiExecutablePathHelper {
    static func augmentedPath(inherited: String?) -> String {
        PiCore.PiExecutable.augmentedPath(inherited: inherited)
    }
}
