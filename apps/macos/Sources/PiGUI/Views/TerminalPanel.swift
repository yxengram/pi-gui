import SwiftUI
import PiCore

/// Integrated terminal, docked under the conversation.
///
/// It runs a login shell on a PTY in the directory the active thread runs in — so a
/// thread working in a worktree gets a shell in that worktree, not the workspace.
struct TerminalPanel: View {
    let workingDirectory: URL?

    @StateObject private var terminal = TerminalController()
    @State private var input = ""
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            output
            Divider()
            inputField
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: workingDirectory) {
            guard let workingDirectory else { return }
            terminal.start(in: workingDirectory)
        }
        .onDisappear { terminal.stop() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal").font(.caption)
            Text(workingDirectory?.lastPathComponent ?? "Terminal")
                .font(.caption.weight(.medium))
            if !terminal.isRunning {
                Text("· exited").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                terminal.clear()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Clear")

            Button {
                terminal.sendInterrupt()
            } label: {
                Image(systemName: "stop.circle")
            }
            .buttonStyle(.borderless)
            .help("Send Ctrl-C")
            .disabled(!terminal.isRunning)

            if !terminal.isRunning, let workingDirectory {
                Button("Restart") { terminal.start(in: workingDirectory) }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private var output: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(terminal.text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .id("terminal.bottom")
            }
            .onChange(of: terminal.text) { _, _ in
                proxy.scrollTo("terminal.bottom", anchor: .bottom)
            }
        }
    }

    private var inputField: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            TextField("", text: $input)
                .textFieldStyle(.plain)
                .font(.system(.caption, design: .monospaced))
                .focused($isInputFocused)
                .onSubmit {
                    terminal.send(line: input)
                    input = ""
                }
                .disabled(!terminal.isRunning)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

/// Owns the PTY and the screen buffer it feeds.
@MainActor
final class TerminalController: ObservableObject {
    @Published private(set) var text: String = ""
    @Published private(set) var isRunning = false

    private var process: PTYProcess?
    private var screen = TerminalScreen()

    func start(in directory: URL) {
        stop()
        screen.clear()
        text = ""

        let process = PTYProcess()
        process.onOutput = { [weak self] chunk in
            guard let self else { return }
            self.screen.append(chunk)
            self.text = self.screen.text
        }
        process.onExit = { [weak self] code in
            guard let self else { return }
            self.isRunning = false
            self.screen.append("\n[process exited with code \(code)]\n")
            self.text = self.screen.text
        }

        do {
            try process.start(shell: Preferences.shared.terminalShell, workingDirectory: directory)
            self.process = process
            isRunning = true
        } catch {
            screen.append("Could not start a shell: \(error)\n")
            text = screen.text
            isRunning = false
        }
    }

    func stop() {
        process?.terminate()
        process = nil
        isRunning = false
    }

    func send(line: String) {
        process?.write(line + "\n")
    }

    /// Ctrl-C, so a runaway command can be stopped without killing the shell.
    func sendInterrupt() {
        process?.write("\u{03}")
    }

    func clear() {
        screen.clear()
        text = ""
    }
}
