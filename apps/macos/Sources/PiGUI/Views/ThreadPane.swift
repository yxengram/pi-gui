import SwiftUI
import PiCore

/// The conversation: transcript above, composer below.
struct ThreadPane: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let session = model.activeSession {
            SessionView(session: session)
                // Rebuild cleanly when switching threads rather than animating one
                // thread's transcript into another's.
                .id(session.id)
        } else {
            WelcomePane()
        }
    }
}

private struct SessionView: View {
    @ObservedObject var session: ThreadSession

    var body: some View {
        VStack(spacing: 0) {
            TimelineView(session: session)
            Divider()
            ComposerView(session: session)
        }
    }
}

/// Scrolling transcript of messages and tool calls.
struct TimelineView: View {
    @ObservedObject var session: ThreadSession
    @State private var isPinnedToBottom = true

    private let bottomAnchor = "pi.timeline.bottom"
    private let coordinateSpace = "pi.timeline.scroll"

    var body: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(session.timeline) { item in
                        TimelineRow(item: item)
                            .id(item.id)
                    }

                    // Live overlay for the run in flight. These rows exist only until
                    // pi reports the finished message, at which point the transcript
                    // above becomes the record.
                    if !session.streamingThinking.isEmpty {
                        StreamingBlock(
                            title: "Thinking",
                            text: session.streamingThinking,
                            isSecondary: true
                        )
                    }
                    if !session.streamingText.isEmpty {
                        StreamingBlock(title: nil, text: session.streamingText, isSecondary: false)
                    }
                    ForEach(session.runningTools) { tool in
                        RunningToolRow(tool: tool)
                    }
                    if session.runState.isBusy && session.streamingText.isEmpty && session.runningTools.isEmpty {
                        WorkingIndicator()
                    }

                    // Reports where the end of the transcript sits relative to the
                    // viewport, which is how scrolling away un-pins the view.
                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchor)
                        .background(
                            GeometryReader { anchor in
                                Color.clear.preference(
                                    key: BottomAnchorOffsetKey.self,
                                    value: anchor.frame(in: .named(coordinateSpace)).maxY
                                )
                            }
                        )
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                }
                .coordinateSpace(name: coordinateSpace)
                .background(Color(nsColor: .textBackgroundColor))
                .onPreferenceChange(BottomAnchorOffsetKey.self) { bottomOffset in
                    // Within a line or so of the end counts as "at the bottom", so a
                    // rounding difference doesn't strand the user with a jump button.
                    isPinnedToBottom = bottomOffset <= outer.size.height + 24
                }
                .onChange(of: session.timeline.count) { _, _ in
                    scrollToBottomIfPinned(proxy)
                }
                .onChange(of: session.streamingText) { _, _ in
                    scrollToBottomIfPinned(proxy)
                }
                .overlay(alignment: .bottomTrailing) {
                    if !isPinnedToBottom {
                        Button {
                            isPinnedToBottom = true
                            withAnimation { proxy.scrollTo(bottomAnchor, anchor: .bottom) }
                        } label: {
                            Label("Jump to latest", systemImage: "arrow.down.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(16)
                    }
                }
            }
        }
    }

    private func scrollToBottomIfPinned(_ proxy: ScrollViewProxy) {
        guard isPinnedToBottom else { return }
        proxy.scrollTo(bottomAnchor, anchor: .bottom)
    }
}

/// Carries the transcript end's position out of the scroll content.
private struct BottomAnchorOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct TimelineRow: View {
    let item: TimelineItem

    var body: some View {
        switch item.kind {
        case .userMessage:
            UserMessageRow(text: item.text)
        case .assistantMessage:
            AssistantMessageRow(text: item.text)
        case .thinking:
            CollapsibleBlock(
                icon: "brain",
                title: "Thinking",
                subtitle: nil,
                tint: .secondary
            ) {
                Text(item.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        case .toolCall:
            if let tool = item.tool {
                ToolCallRow(tool: tool)
            }
        case .compactionSummary:
            NoticeRow(icon: "arrow.down.right.and.arrow.up.left", title: "Context compacted", text: item.text)
        case .branchSummary:
            NoticeRow(icon: "arrow.triangle.branch", title: "Branch summary", text: item.text)
        case .notice:
            NoticeRow(icon: "exclamationmark.triangle", title: nil, text: item.text)
        }
    }
}

private struct UserMessageRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "person.crop.circle")
                .foregroundStyle(.tint)
                .font(.system(size: 15))
                .padding(.top, 1)
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct AssistantMessageRow: View {
    let text: String

    var body: some View {
        // Markdown is how agents write; rendering it is what makes the transcript
        // readable rather than a wall of asterisks.
        MarkdownText(text)
            .font(.callout)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StreamingBlock: View {
    let title: String?
    let text: String
    let isSecondary: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title {
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            Text(text)
                .font(.callout)
                .foregroundStyle(isSecondary ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct WorkingIndicator: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Working…").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct NoticeRow: View {
    let icon: String
    let title: String?
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(.secondary).font(.caption)
            VStack(alignment: .leading, spacing: 2) {
                if let title {
                    Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
                Text(text).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }
}
