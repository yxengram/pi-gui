import SwiftUI
import PiCore
import AppKit

/// Prompt entry.
///
/// Enter sends and Shift+Enter inserts a newline, matching every chat surface people
/// already use. Typing while the agent runs is allowed on purpose: pi accepts a
/// steering message mid-run, and making the user wait would be a downgrade.
struct ComposerView: View {
    @ObservedObject var session: ThreadSession

    @State private var text = ""
    @State private var attachments: [PiImageContent] = []
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !session.queuedMessages.isEmpty {
                queuedBanner
            }
            if let error = session.lastError {
                errorBanner(error)
            }
            if !attachments.isEmpty {
                attachmentBanner
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextEditor(text: $text)
                    .font(.callout)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 38, maxHeight: 140)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(placeholder)
                                .font(.callout)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 12)
                                .allowsHitTesting(false)
                        }
                    }
                    .focused($isFocused)
                    .onKeyPress(.return, phases: .down) { press in
                        // Shift+Return is a newline; a bare Return sends.
                        guard !press.modifiers.contains(.shift) else { return .ignored }
                        submit()
                        return .handled
                    }

                controls
            }
        }
        .padding(12)
        .background(.bar)
        .onAppear { isFocused = true }
    }

    private var placeholder: String {
        session.runState.isBusy
            ? "Steer the agent while it works…"
            : "Message pi…  (⏎ to send, ⇧⏎ for a new line)"
    }

    @ViewBuilder
    private var controls: some View {
        VStack(spacing: 6) {
            if session.runState.isBusy {
                Button(role: .destructive) {
                    Task { await session.abort() }
                } label: {
                    Label("Stop", systemImage: "stop.fill").labelStyle(.iconOnly)
                }
                .help("Stop the current run")
            }

            Button {
                attachImage()
            } label: {
                Label("Attach", systemImage: "paperclip").labelStyle(.iconOnly)
            }
            .help("Attach an image")

            Button(action: submit) {
                Label("Send", systemImage: "arrow.up.circle.fill").labelStyle(.iconOnly)
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty)
            .help("Send (⏎)")
        }
        .buttonStyle(.borderless)
        .imageScale(.large)
    }

    private var queuedBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock").font(.caption)
            Text(session.queuedMessages.count == 1
                 ? "1 message queued"
                 : "\(session.queuedMessages.count) messages queued")
                .font(.caption)
        }
        .foregroundStyle(.secondary)
    }

    private var attachmentBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "photo").font(.caption)
            Text("\(attachments.count) image\(attachments.count == 1 ? "" : "s") attached").font(.caption)
            Button("Clear") { attachments.removeAll() }
                .buttonStyle(.link)
                .font(.caption)
        }
        .foregroundStyle(.secondary)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").font(.caption)
            Text(message).font(.caption).textSelection(.enabled)
        }
        .foregroundStyle(.red)
    }

    private func submit() {
        let message = text
        let images = attachments
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty else { return }
        text = ""
        attachments = []
        Task { await session.send(message, images: images) }
    }

    private func attachImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .jpeg, .gif, .webP]
        guard panel.runModal() == .OK else { return }

        for url in panel.urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            attachments.append(PiImageContent(
                base64Data: data.base64EncodedString(),
                mimeType: Self.mimeType(for: url)
            ))
        }
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "image/jpeg"
        }
    }
}
