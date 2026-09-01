import SwiftUI
import PiCore

/// Changed files for the directory the active thread runs in, with an inline diff.
///
/// Scoping to the thread's own directory is the point: a thread running in a
/// worktree shows that worktree's changes, not the workspace's.
struct DiffPanel: View {
    @EnvironmentObject private var model: AppModel

    @State private var files: [ChangedFile] = []
    @State private var selectedPath: String?
    @State private var diff = UnifiedDiff(lines: [])
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if files.isEmpty {
                emptyState
            } else {
                VSplitView {
                    fileList.frame(minHeight: 120, idealHeight: 180)
                    diffView.frame(minHeight: 160)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: model.activeSession?.id) { await reload() }
        // A finished run is when the working tree most likely changed.
        .task(id: model.activeSession?.timeline.count) { await reload() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Changes").font(.callout.weight(.medium))
            if !files.isEmpty {
                Text("\(files.count)")
                    .font(.caption2)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.2), in: Capsule())
            }
            Spacer()
            if isLoading { ProgressView().controlSize(.small) }
            Button {
                Task { await reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle").font(.title2).foregroundStyle(.tertiary)
            Text("No changes").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fileList: some View {
        List(files, selection: $selectedPath) { file in
            HStack(spacing: 8) {
                Text(statusGlyph(file.status))
                    .font(.system(.caption, design: .monospaced).weight(.bold))
                    .foregroundStyle(statusColor(file.status))
                    .frame(width: 12)

                VStack(alignment: .leading, spacing: 1) {
                    Text(file.fileName).font(.callout).lineLimit(1)
                    if !file.directory.isEmpty {
                        Text(file.directory)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Spacer(minLength: 0)
                if file.isStaged {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("Staged")
                }
            }
            .tag(file.path)
        }
        .listStyle(.inset)
        .onChange(of: selectedPath) { _, _ in
            Task { await loadDiff() }
        }
    }

    private var diffView: some View {
        Group {
            if selectedPath == nil {
                Text("Select a file").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if diff.lines.isEmpty {
                Text("No diff to show").font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(diff.lines) { line in
                            DiffLineRow(line: line)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func statusGlyph(_ status: ChangedFile.Status) -> String {
        switch status {
        case .added: return "A"
        case .modified: return "M"
        case .deleted: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        case .untracked: return "?"
        case .conflicted: return "U"
        case .typeChanged: return "T"
        case let .unknown(code): return code
        }
    }

    private func statusColor(_ status: ChangedFile.Status) -> Color {
        switch status {
        case .added, .untracked: return .green
        case .deleted: return .red
        case .conflicted: return .orange
        default: return .secondary
        }
    }

    private func reload() async {
        isLoading = true
        files = await model.changedFiles()
        // Drop a selection whose file is no longer changed, so the pane cannot show
        // a diff for something already committed or reverted.
        if let selectedPath, !files.contains(where: { $0.path == selectedPath }) {
            self.selectedPath = nil
            diff = UnifiedDiff(lines: [])
        }
        isLoading = false
        await loadDiff()
    }

    private func loadDiff() async {
        guard let selectedPath, let file = files.first(where: { $0.path == selectedPath }) else {
            diff = UnifiedDiff(lines: [])
            return
        }
        diff = await model.diff(for: file)
    }
}

private struct DiffLineRow: View {
    let line: UnifiedDiff.Line

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            gutter(line.oldLineNumber)
            gutter(line.newLineNumber)
            Text(prefix)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(foreground)
                .frame(width: 12, alignment: .center)
            Text(line.text.isEmpty ? " " : line.text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(foreground)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 6)
        .background(background)
    }

    private func gutter(_ number: Int?) -> some View {
        Text(number.map(String.init) ?? "")
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(.tertiary)
            .frame(width: 40, alignment: .trailing)
            .padding(.trailing, 4)
    }

    private var prefix: String {
        switch line.kind {
        case .addition: return "+"
        case .deletion: return "-"
        default: return ""
        }
    }

    private var foreground: Color {
        switch line.kind {
        case .addition: return .green
        case .deletion: return .red
        case .hunkHeader: return .accentColor
        case .fileHeader: return .secondary
        case .context: return .primary
        }
    }

    private var background: Color {
        switch line.kind {
        case .addition: return Color.green.opacity(0.10)
        case .deletion: return Color.red.opacity(0.10)
        case .hunkHeader: return Color.accentColor.opacity(0.08)
        default: return .clear
        }
    }
}
