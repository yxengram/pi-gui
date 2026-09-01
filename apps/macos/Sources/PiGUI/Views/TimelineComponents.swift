import SwiftUI
import PiCore

/// A tool call, collapsed to one line by default.
///
/// Collapsing matters: a long agent run is mostly tool traffic, and a transcript
/// that inlines every file read and command output stops being readable as a
/// conversation. The header carries enough to skim; the body is one click away.
struct ToolCallRow: View {
    let tool: TimelineItem.ToolDetail

    var body: some View {
        CollapsibleBlock(
            icon: icon,
            title: tool.name,
            subtitle: tool.summary.isEmpty ? nil : tool.summary,
            tint: tool.isError ? .red : .secondary,
            trailing: {
                if tool.isRunning {
                    ProgressView().controlSize(.small)
                }
            }
        ) {
            if let output = tool.output, !output.isEmpty {
                MonospacedOutput(text: output, isError: tool.isError)
            } else if tool.isRunning {
                Text("Running…").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("No output").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    /// A glyph per tool family, so the shape of a run is readable at a glance.
    private var icon: String {
        switch tool.name {
        case "bash", "shell": return "terminal"
        case "read", "read_file": return "doc.text"
        case "write", "write_file": return "square.and.pencil"
        case "edit", "apply_patch": return "pencil.line"
        case "glob", "grep", "search": return "magnifyingglass"
        case "list", "ls": return "list.bullet"
        default: return "wrench.and.screwdriver"
        }
    }
}

/// A running tool, shown live from `tool_execution_*` events.
struct RunningToolRow: View {
    let tool: ThreadSession.RunningTool

    var body: some View {
        CollapsibleBlock(
            icon: "terminal",
            title: tool.name,
            subtitle: AgentMessageText.ToolCall(id: tool.id, name: tool.name, arguments: tool.arguments).summary,
            tint: .secondary,
            initiallyExpanded: true,
            trailing: { ProgressView().controlSize(.small) }
        ) {
            if tool.output.isEmpty {
                Text("Running…").font(.caption).foregroundStyle(.secondary)
            } else {
                MonospacedOutput(text: tool.output, isError: false)
            }
        }
    }
}

/// Disclosure row with a one-line header and a collapsible body.
struct CollapsibleBlock<Content: View, Trailing: View>: View {
    let icon: String
    let title: String
    let subtitle: String?
    let tint: Color
    let initiallyExpanded: Bool
    let trailing: () -> Trailing
    let content: () -> Content

    @State private var isExpanded: Bool?

    init(
        icon: String,
        title: String,
        subtitle: String?,
        tint: Color,
        initiallyExpanded: Bool = false,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() },
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.tint = tint
        self.initiallyExpanded = initiallyExpanded
        self.trailing = trailing
        self.content = content
    }

    private var expanded: Bool { isExpanded ?? initiallyExpanded }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                isExpanded = !expanded
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)
                    Image(systemName: icon)
                        .font(.caption)
                        .foregroundStyle(tint)
                    Text(title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(tint)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    trailing()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                content()
                    .padding(.leading, 18)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Fixed-width tool output, capped so one runaway command cannot make the
/// transcript unusable.
struct MonospacedOutput: View {
    let text: String
    let isError: Bool

    private static let characterLimit = 20_000

    private var displayed: String {
        guard text.count > Self.characterLimit else { return text }
        let truncated = String(text.prefix(Self.characterLimit))
        let omitted = text.count - Self.characterLimit
        return truncated + "\n… \(omitted) more characters"
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Text(displayed)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(isError ? Color.red : Color.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 300)
    }
}

/// Renders agent prose as Markdown, falling back to plain text.
///
/// `AttributedString`'s Markdown parser rejects some input the agent will happily
/// produce (an unterminated fence, a stray backslash), so the fallback is not
/// hypothetical — without it those messages would render as nothing.
struct MarkdownText: View {
    private let source: String

    init(_ source: String) {
        self.source = source
    }

    var body: some View {
        if let attributed = try? AttributedString(
            markdown: source,
            options: .init(
                allowsExtendedAttributes: true,
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) {
            Text(attributed)
        } else {
            Text(source)
        }
    }
}
