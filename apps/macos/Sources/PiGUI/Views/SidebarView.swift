import SwiftUI
import PiCore
import AppKit

/// Workspace picker plus the thread list for the selected workspace.
struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    var onNewThread: () -> Void

    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            workspacePicker
            Divider()
            threadList
        }
        .frame(maxHeight: .infinity)
    }

    private var workspacePicker: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(model.workspaces) { workspace in
                    Button {
                        model.selectWorkspace(workspace)
                    } label: {
                        if workspace.id == model.selectedWorkspaceID {
                            Label(workspace.name, systemImage: "checkmark")
                        } else {
                            Text(workspace.name)
                        }
                    }
                }

                if !model.workspaces.isEmpty {
                    Divider()
                    if let selected = model.selectedWorkspace {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([selected.url])
                        }
                        Button("Remove \(selected.name)", role: .destructive) {
                            model.removeWorkspace(selected)
                        }
                    }
                    Divider()
                }
                Button("Open Folder…") {
                    NotificationCenter.default.post(name: .piOpenFolder, object: nil)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                    Text(model.selectedWorkspace?.name ?? "No folder")
                        .lineLimit(1)
                }
            }
            .menuStyle(.borderlessButton)
            .help(model.selectedWorkspace?.path ?? "Open a project folder to begin")

            Spacer(minLength: 0)

            Button(action: onNewThread) {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.borderless)
            .disabled(model.selectedWorkspace == nil)
            .help("New thread (⌘N)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var threadList: some View {
        Group {
            if model.selectedWorkspace == nil {
                emptyState(
                    icon: "folder.badge.plus",
                    title: "Open a folder to start",
                    message: "Threads are stored by pi per project folder."
                )
            } else if model.isLoadingThreads && model.threads.isEmpty {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredThreads.isEmpty {
                emptyState(
                    icon: "bubble.left.and.bubble.right",
                    title: searchText.isEmpty ? "No threads yet" : "No matches",
                    message: searchText.isEmpty ? "Start one with ⌘N." : "Try a different search."
                )
            } else {
                List(selection: threadSelection) {
                    ForEach(filteredThreads) { thread in
                        ThreadRow(thread: thread)
                            .tag(thread.url.path)
                            .contextMenu {
                                Button("Archive") { model.archiveThread(thread) }
                                Button("Reveal Session File") {
                                    NSWorkspace.shared.activateFileViewerSelecting([thread.url])
                                }
                            }
                    }
                }
                .listStyle(.sidebar)
                .searchable(text: $searchText, placement: .sidebar, prompt: "Search threads")
            }
        }
    }

    /// Selecting a row opens that session; the binding funnels it through the model
    /// so the previous pi process is shut down first.
    private var threadSelection: Binding<String?> {
        Binding(
            get: { model.selectedThreadPath },
            set: { path in
                guard let path, let thread = model.threads.first(where: { $0.url.path == path }) else { return }
                Task { await model.openThread(thread) }
            }
        )
    }

    private var filteredThreads: [SessionStore.Summary] {
        let visible = model.visibleThreads
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return visible }
        return visible.filter {
            $0.title.lowercased().contains(query) || ($0.preview?.lowercased().contains(query) ?? false)
        }
    }

    private func emptyState(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text(title).font(.callout.weight(.medium))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ThreadRow: View {
    let thread: SessionStore.Summary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(thread.title)
                .font(.callout)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(thread.modifiedAt, format: .relative(presentation: .named))
                if thread.messageCount > 0 {
                    Text("·")
                    Text("\(thread.messageCount) messages")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 3)
    }
}
