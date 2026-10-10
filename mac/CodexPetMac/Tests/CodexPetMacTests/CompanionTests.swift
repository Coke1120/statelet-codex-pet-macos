import AppKit
import CodexPetCore
import Darwin
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

    func testQuickChatDisablesOptionalImageAndDesktopCapabilities() {
        let arguments = CompanionChatPolicy.arguments
        let disabled = Set(arguments.indices.dropLast().compactMap { index in
            arguments[index] == "--disable" ? arguments[index + 1] : nil
        })
        XCTAssertTrue(disabled.isSuperset(of: ["view_image", "image_generation", "browser_use",
            "browser_use_external", "browser_use_full_cdp_access", "computer_use", "sleep_tool", "tool_suggest"]))
        XCTAssertTrue(arguments.contains("--ignore-rules"))
        XCTAssertTrue(arguments.contains("tools.experimental_request_user_input.enabled=false"))
        XCTAssertTrue(arguments.contains("tools.update_plan.enabled=false"))
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

    func testRoutingHandlesCommentsWithoutInterpretingQuotedContent() {
        let config = """
        # model_provider = "not-openai"
        model = "gpt-test" # selected model
        model_provider = 'openai' # provider
        openai_base_url = 'http://127.0.0.1:8000/v1' # local route
        """
        XCTAssertEqual(CompanionCodexRouting.arguments(config: config), [
            "-c", "model=\"gpt-test\"", "-c", "openai_base_url=\"http://127.0.0.1:8000/v1\""
        ])
        // A hash inside a quoted value is data, not the start of a comment.
        XCTAssertTrue(CompanionCodexRouting.arguments(config: "model = 'gpt-test#suffix' # note").isEmpty)
        XCTAssertTrue(CompanionCodexRouting.arguments(config: "openai_base_url = \"http://localhost/v1#fragment\"").isEmpty)
        XCTAssertTrue(CompanionCodexRouting.arguments(config: "model = \"gpt-test\\\"#suffix\" # note").isEmpty)
        XCTAssertTrue(CompanionCodexRouting.arguments(config: "model = \"gpt-test\" unexpected").isEmpty)
        XCTAssertTrue(CompanionCodexRouting.arguments(config: "model = 'gpt-test'\nmodel_provider = 'other' # note").isEmpty)
    }

    func testRoutingReadsOnlyBoundedRegularConfigFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config.toml")
        try Data("model = 'gpt-test' # chosen model".utf8).write(to: config)
        XCTAssertEqual(CompanionCodexRouting.arguments(configURL: config), ["-c", "model=\"gpt-test\""])
        let link = directory.appendingPathComponent("linked-config.toml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: config)
        XCTAssertEqual(CompanionCodexRouting.arguments(configURL: link), ["-c", "model=\"gpt-test\""])
        XCTAssertTrue(CompanionCodexRouting.arguments(configURL: directory).isEmpty)
        try Data(repeating: 65, count: 1_048_577).write(to: config)
        XCTAssertTrue(CompanionCodexRouting.arguments(configURL: config).isEmpty)
        try Data([0xff]).write(to: config)
        XCTAssertTrue(CompanionCodexRouting.arguments(configURL: config).isEmpty)
    }

    func testRoutingRejectsFIFOWithoutWaitingForAWriter() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config.toml")
        XCTAssertEqual(mkfifo(config.path, 0o600), 0)
        let link = directory.appendingPathComponent("linked-config.toml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: config)
        for candidate in [config, link] {
            let finished = expectation(description: "Config FIFO rejected without a writer")
            DispatchQueue.global().async {
                XCTAssertTrue(CompanionCodexRouting.arguments(configURL: candidate).isEmpty)
                finished.fulfill()
            }
            wait(for: [finished], timeout: 1)
            // Unblock the old implementation after a failing timeout so the native
            // suite does not retain a worker waiting indefinitely on this fixture.
            let writer = Darwin.open(config.path, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
            if writer >= 0 { Darwin.close(writer) }
        }
    }

    func testRoutingRejectsApparentRootKeysInsideComplexValues() {
        for opener in ["'''", "\"\"\"", "[", "{"] {
            let config = "model = 'earlier-model'\ndeveloper_instructions = \(opener)\nopenai_base_url = 'http://127.0.0.1:9999/v1'"
            XCTAssertTrue(CompanionCodexRouting.arguments(config: config).isEmpty, opener)
        }
        let validMultiline = "developer_instructions = '''\nopenai_base_url = \"http://127.0.0.1:9999/v1\"\n'''\nmodel = 'actual-model'"
        XCTAssertTrue(CompanionCodexRouting.arguments(config: validMultiline).isEmpty)
        let quotedKey = "\"foo=bar\" = '''\nopenai_base_url = 'http://127.0.0.1:9999/v1'\n'''"
        XCTAssertTrue(CompanionCodexRouting.arguments(config: quotedKey).isEmpty)
        XCTAssertTrue(CompanionCodexRouting.arguments(config: "model = 'gpt-test'\nunknown.key = 1").isEmpty)
        XCTAssertTrue(CompanionCodexRouting.arguments(config: "model = 'gpt-test'\nunexpected line").isEmpty)
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

    @MainActor
    func testClosingPanelSuppressesLateAutomaticSpeechAndReopeningRestoresIt() async {
        var spoken: [String] = []
        let model = CompanionModel(speechStarter: { text in spoken.append(text); return true }) { _, receive in
            receive(.reply(id: "a", text: "Finished reply")); receive(.completed)
        }
        model.speakReplies = true
        model.setPanelVisible(true)
        model.draft = "First question"; model.send()
        // The runner cannot finish on the main actor until this synchronous close.
        model.setPanelVisible(false)
        await settle(model)
        XCTAssertEqual(model.messages.last?.text, "Finished reply")
        XCTAssertTrue(spoken.isEmpty)
        XCTAssertFalse(model.speaking)
        XCTAssertTrue(model.speakReplies)

        model.setPanelVisible(true)
        model.draft = "Follow up"; model.send()
        await settle(model)
        XCTAssertEqual(spoken, ["Finished reply"])
        model.setPanelVisible(false)
        XCTAssertFalse(model.speaking)
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

    func testAttachmentRejectsFIFOWithoutWaitingForAWriter() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("context.txt")
        XCTAssertEqual(mkfifo(file.path, 0o600), 0)
        let finished = expectation(description: "FIFO rejected without a writer")
        DispatchQueue.global().async {
            XCTAssertThrowsError(try CompanionAttachment.read(file))
            finished.fulfill()
        }
        wait(for: [finished], timeout: 1)
        // Release a blocked reader if the regression returns, so failure does
        // not leave a worker stuck for the rest of the native test suite.
        let writer = Darwin.open(file.path, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
        if writer >= 0 { Darwin.close(writer) }
    }

    @MainActor
    func testMiniModeKeepsDraftAndFitsWindow() {
        _ = NSApplication.shared
        let controller = CompanionPanelController()
        controller.model.draft = "Unsent text"
        controller.model.toggleCompact()
        XCTAssertEqual(controller.window?.frame.height, 56)
        XCTAssertEqual(controller.window?.styleMask, .borderless)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(controller.window?.contentView?.fittingSize.height ?? .infinity, 56)
        XCTAssertEqual(controller.model.draft, "Unsent text")
        controller.model.toggleCompact()
        XCTAssertEqual(controller.window?.frame.height, 640)
        XCTAssertTrue(controller.window?.styleMask.contains(.titled) == true)
        XCTAssertTrue(controller.window?.styleMask.contains(.resizable) == true)
        XCTAssertEqual(controller.model.draft, "Unsent text")
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
