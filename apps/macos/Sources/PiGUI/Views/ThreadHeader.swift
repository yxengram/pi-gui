import SwiftUI
import PiCore

/// Toolbar centre: thread title, where it runs, and the model picker.
struct ThreadHeader: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let session = model.activeSession {
            HeaderContent(session: session)
        } else {
            EmptyView()
        }
    }
}

private struct HeaderContent: View {
    @ObservedObject var session: ThreadSession
    @State private var models: [ModelOption] = []
    @State private var isRenaming = false
    @State private var draftTitle = ""

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .font(.headline)
                    .lineLimit(1)
                    .onTapGesture(count: 2) {
                        draftTitle = session.title
                        isRenaming = true
                    }
                    .help("Double-click to rename")

                HStack(spacing: 4) {
                    if let worktree = session.worktree {
                        Image(systemName: "arrow.triangle.branch").font(.caption2)
                        Text(worktree.branch ?? worktree.path.lastPathComponent)
                    } else {
                        Image(systemName: "folder").font(.caption2)
                        Text(session.workingDirectory.lastPathComponent)
                    }
                    if session.runState.isBusy {
                        Text("· running")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            modelPicker
        }
        .popover(isPresented: $isRenaming) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Rename thread").font(.headline)
                TextField("Title", text: $draftTitle)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .onSubmit { commitRename() }
                HStack {
                    Spacer()
                    Button("Cancel") { isRenaming = false }
                    Button("Rename") { commitRename() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
        }
        .task {
            models = await session.availableModels()
        }
    }

    /// pi owns the model list; this only reflects it and asks pi to switch.
    private var modelPicker: some View {
        Menu {
            if models.isEmpty {
                Text("No models configured")
            }
            ForEach(models) { option in
                Button {
                    Task { await session.setModel(provider: option.provider, modelId: option.id) }
                } label: {
                    if option.name == session.modelName {
                        Label(option.displayName, systemImage: "checkmark")
                    } else {
                        Text(option.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu").font(.caption2)
                Text(session.modelName ?? "Model").font(.caption).lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose the model pi runs with")
    }

    private func commitRename() {
        let title = draftTitle
        isRenaming = false
        Task { await session.rename(to: title) }
    }
}

/// Shown when nothing is open.
struct WelcomePane: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)

            Text(model.selectedWorkspace == nil ? "Open a project folder" : "No thread open")
                .font(.title3.weight(.medium))

            Text(model.selectedWorkspace == nil
                 ? "pi-gui runs the pi CLI inside a folder you choose."
                 : "Pick a thread on the left, or start a new one.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button(model.selectedWorkspace == nil ? "Open Folder…" : "New Thread") {
                NotificationCenter.default.post(
                    name: model.selectedWorkspace == nil ? .piOpenFolder : .piNewThread,
                    object: nil
                )
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// Asks for a title and where the thread should run.
struct NewThreadSheet: View {
    @EnvironmentObject private var model: AppModel
    @Binding var isPresented: Bool

    @State private var title = ""
    @State private var location: ThreadLocation = .local
    @State private var isCreating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New thread").font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Title").font(.caption).foregroundStyle(.secondary)
                TextField("What are you working on?", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(create)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Run in").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $location) {
                    ForEach(ThreadLocation.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(location.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                if isCreating { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isCreating)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func create() {
        guard !isCreating else { return }
        isCreating = true
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = location
        Task {
            await model.createThread(
                title: name.isEmpty ? "New thread" : name,
                location: chosen
            )
            isCreating = false
            isPresented = false
        }
    }
}
