import SwiftUI
import PiCore
import AppKit

/// App settings.
///
/// Providers, credentials and models are configured with pi itself (`pi` handles
/// OAuth and API keys, and stores them under `~/.pi`). Duplicating that here would
/// create a second source of truth for the user's credentials, so this pane points
/// at pi instead of reimplementing it.
struct SettingsView: View {
    @AppStorage("piExecutablePath") private var piExecutablePath = ""
    @AppStorage("showThinking") private var showThinking = true
    @AppStorage("terminalShell") private var terminalShell = ""

    @State private var resolvedPath: String?
    @State private var resolutionError: String?

    var body: some View {
        TabView {
            generalTab.tabItem { Label("General", systemImage: "gearshape") }
            piTab.tabItem { Label("pi", systemImage: "terminal") }
        }
        .frame(width: 520, height: 320)
        .task { resolveExecutable() }
    }

    private var generalTab: some View {
        Form {
            Toggle("Show the agent's reasoning in the transcript", isOn: $showThinking)

            TextField("Terminal shell", text: $terminalShell, prompt: Text(defaultShell))
                .help("Shell used by the integrated terminal. Leave blank to use $SHELL.")
        }
        .formStyle(.grouped)
        .padding()
    }

    private var piTab: some View {
        Form {
            Section {
                HStack {
                    TextField("pi executable", text: $piExecutablePath, prompt: Text("Found automatically"))
                    Button("Choose…") { choosePiExecutable() }
                }

                if let resolvedPath {
                    LabeledContent("Using") {
                        Text(resolvedPath)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                } else if let resolutionError {
                    Label(resolutionError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }

                Button("Re-check") { resolveExecutable() }
            } header: {
                Text("Executable")
            } footer: {
                Text("pi-gui runs this binary for every thread. An app launched from the Dock doesn't inherit your shell's PATH, so set this if pi isn't found.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("Providers, API keys and models are configured with pi itself, and shared with the `pi` command in your terminal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open ~/.pi in Finder") {
                    let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".pi")
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } header: {
                Text("Providers")
            }
        }
        .formStyle(.grouped)
        .padding()
        .onChange(of: piExecutablePath) { _, _ in resolveExecutable() }
    }

    private var defaultShell: String {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    private func resolveExecutable() {
        do {
            let executable = try PiExecutable.resolve(
                override: piExecutablePath.isEmpty ? nil : piExecutablePath
            )
            resolvedPath = executable.url.path
            resolutionError = nil
        } catch {
            resolvedPath = nil
            resolutionError = String(describing: error)
        }
    }

    private func choosePiExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        piExecutablePath = url.path
    }
}
