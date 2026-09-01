import SwiftUI
import PiCore
import AppKit

/// The window: threads on the left, conversation in the middle, and optional
/// diff/terminal panels docked on the right and bottom.
struct RootView: View {
    @EnvironmentObject private var model: AppModel

    @State private var showDiffPanel = false
    @State private var showTerminal = false
    @State private var showNewThreadSheet = false

    var body: some View {
        NavigationSplitView {
            SidebarView(onNewThread: { showNewThreadSheet = true })
                .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 400)
        } detail: {
            HSplitView {
                VStack(spacing: 0) {
                    ThreadPane()
                    if showTerminal {
                        Divider()
                        TerminalPanel(workingDirectory: currentDirectory)
                            .frame(minHeight: 140, idealHeight: 220, maxHeight: 400)
                    }
                }
                .frame(minWidth: 420)

                if showDiffPanel {
                    DiffPanel()
                        .frame(minWidth: 320, idealWidth: 460)
                }
            }
        }
        .toolbar { toolbarContent }
        .sheet(isPresented: $showNewThreadSheet) {
            NewThreadSheet(isPresented: $showNewThreadSheet)
                .environmentObject(model)
        }
        .task {
            await model.reloadThreads()
        }
        .onReceive(NotificationCenter.default.publisher(for: .piNewThread)) { _ in
            showNewThreadSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .piOpenFolder)) { _ in
            openFolder()
        }
        .onReceive(NotificationCenter.default.publisher(for: .piToggleDiff)) { _ in
            showDiffPanel.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .piToggleTerminal)) { _ in
            showTerminal.toggle()
        }
        .alert(
            "Couldn't start pi",
            isPresented: Binding(
                get: { model.startupError != nil },
                set: { if !$0 { model.startupError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.startupError = nil }
        } message: {
            Text(model.startupError ?? "")
        }
    }

    private var currentDirectory: URL? {
        model.activeSession?.workingDirectory ?? model.selectedWorkspace?.url
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                showNewThreadSheet = true
            } label: {
                Label("New Thread", systemImage: "square.and.pencil")
            }
            .disabled(model.selectedWorkspace == nil)
            .help("Start a new thread (⌘N)")
        }

        ToolbarItem(placement: .principal) {
            ThreadHeader()
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                showTerminal.toggle()
            } label: {
                Label("Terminal", systemImage: "terminal")
            }
            .help("Toggle the integrated terminal (⌘J)")
            .disabled(currentDirectory == nil)

            Button {
                showDiffPanel.toggle()
            } label: {
                Label("Changes", systemImage: "plusminus.circle")
            }
            .help("Toggle the diff panel (⌘D)")
            .disabled(currentDirectory == nil)
        }
    }

    /// Uses the real macOS folder picker so sandbox and recent-items behavior match
    /// what people expect from a native app.
    private func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a project folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.addWorkspace(path: url.path)
    }
}
