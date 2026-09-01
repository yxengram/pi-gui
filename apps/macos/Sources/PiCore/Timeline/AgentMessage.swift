import Foundation

/// Reads pi's `AgentMessage` content blocks.
///
/// A message's `content` is either a bare string or an array of typed blocks
/// (`text`, `image`, `thinking`, `toolCall`). Both shapes are live in real session
/// files, so every reader has to handle both.
public enum AgentMessageText {
    /// Concatenated `text` blocks, or the bare string form.
    public static func plainText(from message: JSONValue?) -> String? {
        guard let content = message?["content"] else { return nil }

        if let text = content.stringValue {
            return text.isEmpty ? nil : text
        }

        guard let blocks = content.arrayValue else { return nil }
        let text = blocks
            .filter { $0["type"]?.stringValue == "text" }
            .compactMap { $0["text"]?.stringValue }
            .joined()
        return text.isEmpty ? nil : text
    }

    /// Concatenated `thinking` blocks.
    public static func thinkingText(from message: JSONValue?) -> String? {
        guard let blocks = message?["content"]?.arrayValue else { return nil }
        let text = blocks
            .filter { $0["type"]?.stringValue == "thinking" }
            .compactMap { $0["thinking"]?.stringValue }
            .joined()
        return text.isEmpty ? nil : text
    }

    /// Tool calls requested by an assistant message.
    public static func toolCalls(from message: JSONValue?) -> [ToolCall] {
        guard let blocks = message?["content"]?.arrayValue else { return [] }
        return blocks.compactMap { block in
            guard block["type"]?.stringValue == "toolCall",
                  let id = block["id"]?.stringValue,
                  let name = block["name"]?.stringValue else { return nil }
            return ToolCall(id: id, name: name, arguments: block["arguments"] ?? .object([:]))
        }
    }

    /// Image attachments on a user message.
    public static func images(from message: JSONValue?) -> [PiImageContent] {
        guard let blocks = message?["content"]?.arrayValue else { return [] }
        return blocks.compactMap { block in
            guard block["type"]?.stringValue == "image",
                  let data = block["data"]?.stringValue,
                  let mimeType = block["mimeType"]?.stringValue else { return nil }
            return PiImageContent(base64Data: data, mimeType: mimeType)
        }
    }

    public struct ToolCall: Sendable, Hashable, Identifiable {
        public let id: String
        public let name: String
        public let arguments: JSONValue

        public init(id: String, name: String, arguments: JSONValue) {
            self.id = id
            self.name = name
            self.arguments = arguments
        }

        /// A one-line argument summary for the collapsed row, chosen per tool so the
        /// header reads like what the agent actually did.
        public var summary: String {
            let interesting = ["command", "file_path", "path", "pattern", "query", "url", "description"]
            for key in interesting {
                if let value = arguments[key]?.stringValue, !value.isEmpty {
                    return value.singleLinePreview(limit: 160)
                }
            }
            if let object = arguments.objectValue, object.isEmpty { return "" }
            return ""
        }
    }
}
