import AppKit
import CodexPetCore
import XCTest
@testable import Statelet

final class CompanionTests: XCTestCase {
    func testPromptIncludesConversationWithoutPuttingTextInArguments() throws {
        let messages = [CompanionMessage(role: .user, text: "private question"),
                        CompanionMessage(role: .assistant, text: "first answer"),
                        CompanionMessage(role: .user, text: "follow up")]
        let prompt = try CompanionChatPolicy.prompt(messages: messages)
        XCTAssertTrue(prompt.contains("private question"))
        XCTAssertTrue(prompt.contains("follow up"))
        XCTAssertFalse(CompanionChatPolicy.arguments.joined().contains("private question"))
        XCTAssertTrue(CompanionChatPolicy.arguments.contains("--ephemeral"))
        XCTAssertTrue(CompanionChatPolicy.arguments.contains("read-only"))
        XCTAssertFalse(CompanionChatPolicy.arguments.contains("--dangerously-bypass-approvals-and-sandbox"))
    }

    func testPromptRejectsOversizeUTF8() throws {
        XCTAssertThrowsError(try CompanionChatPolicy.prompt(messages: [
            CompanionMessage(role: .user, text: String(repeating: "語", count: 30_000))
        ]))
        XCTAssertThrowsError(try CompanionChatPolicy.prompt(messages: []))
    }

    func testOnlyAssistantTextAndSafeStatusReachChat() throws {
        XCTAssertEqual(try event(["type": "item.completed", "item": ["id": "a", "type": "agent_message", "text": "hello"]]), .reply(id: "a", text: "hello"))
        XCTAssertNil(try event(["type": "item.completed", "item": ["type": "command_execution", "aggregated_output": "secret path"]]))
        XCTAssertNil(try event(["type": "item.completed", "item": ["type": "reasoning", "text": "private reasoning"]]))
        XCTAssertEqual(try event(["type": "turn.completed"]), .completed)
        do {
            _ = try event(["type": "turn.failed", "error": ["message": "private key"]])
            XCTFail("Expected bounded error")
        } catch { XCTAssertFalse(error.localizedDescription.contains("private key")) }
    }

    func testTransientReconnectDoesNotDiscardConversation() throws {
        XCTAssertEqual(try event(["type": "error", "message": "Reconnecting... 2/5 (tls handshake eof)"]), .status("Reconnecting…"))
        XCTAssertThrowsError(try event(["type": "turn.failed", "error": ["message": "tls handshake eof"]])) {
            XCTAssertEqual($0 as? CompanionChatError, .connection)
        }
    }

    func testRoutingCopiesOnlyModelAndCredentialFreeLoopbackEndpoint() {
        let config = "model = \"gpt-test\"\nopenai_base_url = \"http://127.0.0.1:8000/v1\"\n[mcp_servers.private]\ncommand = \"private-command\""
        let arguments = CompanionCodexRouting.arguments(config: config)
        XCTAssertTrue(arguments.contains("model=\"gpt-test\""))
        XCTAssertEqual(arguments.count, 4)
        XCTAssertTrue(arguments.contains("openai_base_url=\"http://127.0.0.1:8000/v1\""))
        XCTAssertFalse(arguments.joined().contains("private-command"))
        for endpoint in ["https://example.com/v1", "http://127.0.0.1.evil.test/v1", "http://user:secret@127.0.0.1/v1", "http://127.0.0.1/v1?token=secret"] {
            let encoded = String(decoding: try! JSONSerialization.data(withJSONObject: endpoint, options: [.fragmentsAllowed]), as: UTF8.self)
            XCTAssertTrue(CompanionCodexRouting.arguments(config: "openai_base_url = " + encoded).isEmpty)
        }
        XCTAssertTrue(CompanionCodexRouting.arguments(config: "[other]\nmodel = \"not-a-root-model\"").isEmpty)
    }

    private func event(_ object: [String: Any]) throws -> CompanionChatEvent? {
        try CompanionChatPolicy.event(from: JSONSerialization.data(withJSONObject: object))
    }

    @MainActor
    func testSendFollowUpAndClearKeepConversationInMemory() async throws {
        let model = CompanionModel { _, receive in
            receive(.reply(id: "1", text: "Hello")); receive(.reply(id: "1", text: "Hello there")); receive(.completed)
        }
        model.draft = "First question"; model.send()
        await settle(model)
        XCTAssertEqual(model.messages.count, 2)
        XCTAssertEqual(model.messages.last?.text, "Hello there")
        XCTAssertEqual(model.sentMessages.count, 2)
        model.draft = "Follow up"; model.send()
        await settle(model)
        XCTAssertEqual(model.sentMessages.count, 4)
        model.newChat()
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertTrue(model.sentMessages.isEmpty)
        XCTAssertFalse(model.isRunning)
    }

    @MainActor
    func testCancellationRejectsLateOutputAndDoesNotStopNewReply() async throws {
        let gate = CompanionTestGate()
        let model = CompanionModel { _, receive in
            let call = gate.next()
            try? await Task.sleep(nanoseconds: call == 1 ? 150_000_000 : 10_000_000)
            receive(.reply(id: "1", text: call == 1 ? "stale" : "current")); receive(.completed)
        }
        model.draft = "first"; model.send()
        try await Task.sleep(nanoseconds: 20_000_000)
        model.newChat()
        model.draft = "second"; model.send()
        await settle(model)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(model.messages.map(\.text), ["second", "current"])
    }

    @MainActor
    func testRetryReplacesPartialResponseWithoutDuplicatingUserTurn() async throws {
        let gate = CompanionTestGate()
        let model = CompanionModel { _, receive in
            let call = gate.next()
            receive(.reply(id: "a", text: call == 1 ? "partial" : "finished"))
            if call == 1 { throw CompanionChatError.failed }
            receive(.completed)
        }
        model.draft = "question"; model.send(); await settle(model)
        XCTAssertNotNil(model.error)
        XCTAssertTrue(model.canRetry)
        model.retry(); await settle(model)
        XCTAssertEqual(model.messages.map(\.text), ["question", "finished"])
        XCTAssertEqual(model.sentMessages.count, 2)
        XCTAssertNil(model.error)
    }

    func testAttachmentRejectsOversizeAndBinaryFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("context.txt")
        try Data("Context".utf8).write(to: file)
        XCTAssertEqual(try CompanionAttachment.read(file).text, "Context")
        try Data([0, 1, 2]).write(to: file)
        XCTAssertThrowsError(try CompanionAttachment.read(file))
        try Data(repeating: 65, count: 16 * 1024 + 1).write(to: file)
        XCTAssertThrowsError(try CompanionAttachment.read(file))
        let link = directory.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try CompanionAttachment.read(link))
    }

    @MainActor
    func testMiniModeKeepsDraftAndFitsWindow() {
        _ = NSApplication.shared
        let controller = CompanionPanelController()
        controller.model.draft = "Unsent text"
        controller.model.toggleCompact()
        XCTAssertEqual(controller.window?.frame.height, 116)
        XCTAssertEqual(controller.model.draft, "Unsent text")
        controller.model.toggleCompact()
        XCTAssertEqual(controller.window?.frame.height, 640)
        controller.shutdown()
    }

    @MainActor
    private func settle(_ model: CompanionModel) async {
        for _ in 0..<200 {
            if !model.isRunning { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Chat did not settle")
    }

    func testServiceStreamsSyntheticCodexReplyAndCleansUp() async throws {
        let file = try script("""
        #!/bin/sh
        cat >/dev/null
        echo '{"type":"turn.started"}'
        echo '{"type":"item.completed","item":{"type":"agent_message","id":"a","text":"Hello"}}'
        echo '{"type":"turn.completed"}'
        """)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let events = CompanionTestEvents()
        let service = CompanionChatService(executableLocator: { file }, trustPolicy: .testOnlyAllowUnsignedExecutable, timeout: 2)
        try await service.run(prompt: "test") { events.append($0) }
        XCTAssertEqual(events.values, [.status("Thinking…"), .reply(id: "a", text: "Hello"), .completed])
    }

    func testServiceTimeoutAndCancellationFinishPromptly() async throws {
        let file = try script("#!/bin/sh\ncat >/dev/null\nsleep 30\n")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let service = CompanionChatService(executableLocator: { file }, trustPolicy: .testOnlyAllowUnsignedExecutable, timeout: 0.1)
        let start = Date()
        do { try await service.run(prompt: "test") { _ in }; XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error as? CompanionChatError, .timedOut) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        let cancellable = CompanionChatService(executableLocator: { file }, trustPolicy: .testOnlyAllowUnsignedExecutable, timeout: 30)
        let task = Task { try await cancellable.run(prompt: "test") { _ in } }
        try await Task.sleep(nanoseconds: 50_000_000); task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    private func script(_ text: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let file = directory.appendingPathComponent("codex")
        try Data((text + "\n").utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }
}

private final class CompanionTestGate: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
}
private final class CompanionTestEvents: @unchecked Sendable {
    private let lock = NSLock(); private var events: [CompanionChatEvent] = []
    func append(_ event: CompanionChatEvent) { lock.withLock { events.append(event) } }
    var values: [CompanionChatEvent] { lock.withLock { events } }
}
