import XCTest
@testable import PiCore

/// Decoding tests run against JSON captured from a real `pi --mode rpc` process
/// (see Fixtures/), not hand-written approximations, so a protocol drift in pi
/// shows up here rather than as an empty pane at runtime.
final class PiRPCProtocolTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil),
            "missing fixture \(name)"
        )
        return try Data(contentsOf: url)
    }

    private func json(_ name: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: fixture(name))
    }

    // MARK: - Responses

    func testDecodesGetStateResponse() throws {
        guard case let .response(response) = try PiRPCIncoming(json: json("get_state.json")) else {
            return XCTFail("expected a response")
        }
        XCTAssertEqual(response.command, "get_state")
        XCTAssertTrue(response.success)
        XCTAssertEqual(response.id, "1")
        XCTAssertEqual(response.data?.path("model.id")?.stringValue, "us.anthropic.claude-opus-4-6-v1")
        XCTAssertEqual(response.data?.path("model.provider")?.stringValue, "amazon-bedrock")
        XCTAssertEqual(response.data?["thinkingLevel"]?.stringValue, "medium")
        XCTAssertEqual(response.data?["isStreaming"]?.boolValue, false)
        XCTAssertNotNil(response.data?["sessionFile"]?.stringValue)
    }

    func testDecodesBashResponse() throws {
        guard case let .response(response) = try PiRPCIncoming(json: json("bash.json")) else {
            return XCTFail("expected a response")
        }
        XCTAssertEqual(response.command, "bash")
        XCTAssertEqual(response.data?["output"]?.stringValue, "hello-from-pi-bash\n")
        XCTAssertEqual(response.data?["exitCode"]?.intValue, 0)
    }

    func testDecodesSessionStatsResponse() throws {
        guard case let .response(response) = try PiRPCIncoming(json: json("get_session_stats.json")) else {
            return XCTFail("expected a response")
        }
        XCTAssertEqual(response.data?["sessionId"]?.stringValue, "01a05cb5-a499-7eec-9467-91f9349a2572")
        XCTAssertEqual(response.data?.path("contextUsage.contextWindow")?.intValue, 1_000_000)
    }

    func testDecodesAvailableModels() throws {
        guard case let .response(response) = try PiRPCIncoming(json: json("get_available_models.sample.json")) else {
            return XCTFail("expected a response")
        }
        let models = try XCTUnwrap(response.data?["models"]?.arrayValue)
        XCTAssertFalse(models.isEmpty)
        XCTAssertNotNil(models[0]["id"]?.stringValue)
        XCTAssertNotNil(models[0]["provider"]?.stringValue)
    }

    /// An event is anything whose `type` is not `response`; events never carry an id.
    func testDecodesEventAndDistinguishesItFromResponse() throws {
        guard case let .event(event) = try PiRPCIncoming(json: json("event_session_info_changed.json")) else {
            return XCTFail("expected an event")
        }
        XCTAssertEqual(event.kind, .sessionInfoChanged)
        XCTAssertEqual(event.payload["name"]?.stringValue, "renamed probe")
    }

    /// pi may add event types at any release; they must survive as `.other`.
    func testUnknownEventTypeIsPreservedRatherThanDropped() throws {
        let value = JSONValue.object(["type": .string("brand_new_event"), "detail": .string("x")])
        guard case let .event(event) = try PiRPCIncoming(json: value) else {
            return XCTFail("expected an event")
        }
        XCTAssertEqual(event.kind, .other("brand_new_event"))
        XCTAssertEqual(event.payload["detail"]?.stringValue, "x")
    }

    /// pi rejects an unknown command with success:false plus a reason, which the
    /// client turns into a thrown error rather than a silently ignored request.
    func testDecodesRejectedCommandResponse() throws {
        guard case let .response(response) = try PiRPCIncoming(json: json("response-unknown-command.json")) else {
            return XCTFail("expected a response")
        }
        XCTAssertFalse(response.success)
        XCTAssertEqual(response.command, "not_a_real_command")
        XCTAssertEqual(response.error, "Unknown command: not_a_real_command")
    }

    /// The most common real rejection: no credentials for the selected model. pi's
    /// message is multi-line and tells the user how to fix it, so it is surfaced
    /// verbatim rather than replaced with a generic failure string.
    func testDecodesMissingCredentialsRejection() throws {
        guard case let .response(response) = try PiRPCIncoming(json: json("response-prompt-no-auth.json")) else {
            return XCTFail("expected a response")
        }
        XCTAssertFalse(response.success)
        XCTAssertEqual(response.command, "prompt")
        let message = try XCTUnwrap(response.error)
        XCTAssertTrue(message.hasPrefix("No API key found"))
        XCTAssertTrue(message.contains("\n"), "pi's guidance is multi-line and must survive intact")
    }

    func testRecordWithoutTypeIsRejected() {
        XCTAssertThrowsError(try PiRPCIncoming(json: .object(["id": .string("1")])))
    }

    func testTextDeltaAccessorReadsStreamingChunk() {
        let event = PiRPCEvent(type: "message_update", payload: .object([
            "type": .string("message_update"),
            "assistantMessageEvent": .object([
                "type": .string("text_delta"),
                "delta": .string("Hello "),
            ]),
        ]))
        XCTAssertEqual(event.textDelta, "Hello ")
        XCTAssertNil(event.thinkingDelta)
    }

    // MARK: - Commands

    private func encode(_ command: PiRPCCommand) throws -> [String: JSONValue] {
        let data = try JSONEncoder().encode(command)
        return try XCTUnwrap(JSONDecoder().decode(JSONValue.self, from: data).objectValue)
    }

    func testPromptCommandEncodesMessageAndStreamingBehavior() throws {
        let object = try encode(.prompt(id: "req-1", message: "hi", streamingBehavior: .steer))
        XCTAssertEqual(object["type"]?.stringValue, "prompt")
        XCTAssertEqual(object["id"]?.stringValue, "req-1")
        XCTAssertEqual(object["message"]?.stringValue, "hi")
        // pi's wire value is camelCase `followUp`/`steer`.
        XCTAssertEqual(object["streamingBehavior"]?.stringValue, "steer")
    }

    func testPromptOmitsStreamingBehaviorWhenUnset() throws {
        let object = try encode(.prompt(id: "req-2", message: "hi"))
        XCTAssertNil(object["streamingBehavior"])
        XCTAssertNil(object["images"])
    }

    func testFollowUpUsesSnakeCaseWireName() throws {
        XCTAssertEqual(try encode(.followUp(message: "later"))["type"]?.stringValue, "follow_up")
    }

    func testImagesEncodeInImageContentShape() throws {
        let object = try encode(.prompt(
            id: "req-3",
            message: "look",
            images: [PiImageContent(base64Data: "AAAA", mimeType: "image/png")]
        ))
        let image = try XCTUnwrap(object["images"]?[0])
        XCTAssertEqual(image["type"]?.stringValue, "image")
        XCTAssertEqual(image["data"]?.stringValue, "AAAA")
        XCTAssertEqual(image["mimeType"]?.stringValue, "image/png")
    }

    /// Arguments must never be able to overwrite the envelope's own fields.
    func testArgumentsCannotShadowTypeOrID() throws {
        let command = PiRPCCommand(
            id: "req-4",
            type: "prompt",
            arguments: ["type": .string("evil"), "id": .string("evil"), "message": .string("ok")]
        )
        let object = try encode(command)
        XCTAssertEqual(object["type"]?.stringValue, "prompt")
        XCTAssertEqual(object["id"]?.stringValue, "req-4")
        XCTAssertEqual(object["message"]?.stringValue, "ok")
    }

    func testSetModelEncodesProviderAndModel() throws {
        let object = try encode(.setModel(provider: "anthropic", modelId: "claude-sonnet-4-5"))
        XCTAssertEqual(object["type"]?.stringValue, "set_model")
        XCTAssertEqual(object["provider"]?.stringValue, "anthropic")
        XCTAssertEqual(object["model"]?.stringValue, "claude-sonnet-4-5")
    }

    /// Commands are written one per line; an embedded newline would split the record.
    func testEncodedCommandContainsNoRawNewline() throws {
        let data = try JSONEncoder().encode(PiRPCCommand.prompt(message: "line one\nline two"))
        XCTAssertFalse(data.contains(0x0A))
    }
}
