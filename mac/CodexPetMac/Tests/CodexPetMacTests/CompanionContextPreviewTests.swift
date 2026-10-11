import AppKit
import XCTest
@testable import Statelet

final class CompanionContextPreviewTests: XCTestCase {
    @MainActor
    func testPreviewAndDismissPreserveDraftAndAttachmentsWithoutStartingChat() throws {
        let requests = PreviewTestRequests()
        let model = makeModel(recording: requests)
        let attachment = CompanionAttachment(name: "notes.txt", text: "Selected synthetic context 語")
        model.draft = "  Explain these notes\n"
        model.attachments = [attachment]

        model.showContextPreview()
        let preview = try XCTUnwrap(model.contextPreview)
        XCTAssertEqual(preview.messages.map(\.text), ["Explain these notes\n\nAttached text (notes.txt):\nSelected synthetic context 語"])
        XCTAssertEqual(preview.prompt, try CompanionChatPolicy.prompt(messages: preview.messages))
        XCTAssertTrue(requests.values.isEmpty)
        XCTAssertFalse(model.isRunning)
        XCTAssertTrue(model.messages.isEmpty)

        model.dismissContextPreview()
        XCTAssertNil(model.contextPreview)
        XCTAssertEqual(model.draft, "  Explain these notes\n")
        XCTAssertEqual(model.attachments.map(\.id), [attachment.id])
        model.sendContextPreview(id: preview.id)
        XCTAssertFalse(model.isRunning)
        XCTAssertTrue(requests.values.isEmpty)
    }

    @MainActor
    func testReviewedSendUsesExactPreviewAndFollowUpIncludesEarlierAttachmentText() async throws {
        let requests = PreviewTestRequests()
        let model = makeModel(recording: requests)
        model.draft = "First question"
        model.attachments = [CompanionAttachment(name: "notes.txt", text: "Earlier attached context")]
        model.showContextPreview()
        let first = try XCTUnwrap(model.contextPreview)
        model.sendContextPreview(id: first.id)
        await settle(model)
        XCTAssertEqual(requests.values, [first.prompt])
        XCTAssertNil(model.contextPreview)
        XCTAssertTrue(model.draft.isEmpty)
        XCTAssertTrue(model.attachments.isEmpty)
        XCTAssertEqual(model.messages.first?.text, "First question\n\n📎 notes.txt")
        XCTAssertEqual(model.sentMessages.count, 2)

        model.draft = "Follow up"
        model.showContextPreview()
        let followUp = try XCTUnwrap(model.contextPreview)
        XCTAssertEqual(followUp.messages.count, 3)
        XCTAssertEqual(followUp.messages.first?.text, first.messages.first?.text)
        XCTAssertEqual(followUp.messages[1].text, "Synthetic reply")
        XCTAssertEqual(followUp.messages.last?.text, "Follow up")
        XCTAssertEqual(requests.values.count, 1, "Previewing a follow-up must not send it")
        model.sendContextPreview(id: followUp.id)
        await settle(model)
        XCTAssertEqual(requests.values, [first.prompt, followUp.prompt])
        XCTAssertEqual(model.sentMessages.count, 4)
    }

    @MainActor
    func testDirectSendUsesTheSamePreparedContentAsPreview() async throws {
        let requests = PreviewTestRequests()
        let model = makeModel(recording: requests)
        model.draft = "Quoted \"text\" and 語"
        model.attachments = [CompanionAttachment(name: "example.txt", text: "line 1\nline 2")]
        model.showContextPreview()
        let preview = try XCTUnwrap(model.contextPreview)
        model.dismissContextPreview()
        model.send()
        await settle(model)
        XCTAssertEqual(requests.values, [preview.prompt])
    }

    @MainActor
    func testChangedDraftOrAttachmentCannotBeSentFromOldPreview() throws {
        for changeAttachment in [false, true] {
            let requests = PreviewTestRequests()
            let model = makeModel(recording: requests)
            model.draft = "Original question"
            model.attachments = [CompanionAttachment(name: "notes.txt", text: "Original context")]
            model.showContextPreview()
            let preview = try XCTUnwrap(model.contextPreview)
            if changeAttachment {
                model.attachments = [CompanionAttachment(name: "notes.txt", text: "Changed context")]
            } else { model.draft = "Changed question" }
            model.sendContextPreview(id: preview.id)
            XCTAssertFalse(model.isRunning)
            XCTAssertTrue(requests.values.isEmpty)
            XCTAssertTrue(model.sentMessages.isEmpty)
            XCTAssertNil(model.contextPreview)
            XCTAssertNotNil(model.error)
            XCTAssertEqual(model.draft, changeAttachment ? "Original question" : "Changed question")
            XCTAssertEqual(model.attachments.first?.text, changeAttachment ? "Changed context" : "Original context")
        }
    }

    @MainActor
    func testSupersededPreviewActionCannotSendOrDismissANewerPreview() throws {
        let model = makeModel(recording: PreviewTestRequests())
        model.draft = "Question"
        model.showContextPreview()
        let old = try XCTUnwrap(model.contextPreview)
        model.dismissContextPreview()
        model.showContextPreview()
        let current = try XCTUnwrap(model.contextPreview)
        model.sendContextPreview(id: old.id)
        XCTAssertEqual(model.contextPreview?.id, current.id)
        XCTAssertFalse(model.isRunning)
        model.newChat()
        model.sendContextPreview(id: current.id)
        XCTAssertNil(model.contextPreview)
        XCTAssertTrue(model.sentMessages.isEmpty)
        XCTAssertTrue(model.draft.isEmpty)
    }

    @MainActor
    func testClosingOrCompactingPanelDiscardsPreviewButKeepsInput() throws {
        let model = makeModel(recording: PreviewTestRequests())
        model.draft = "Unsent draft"
        model.attachments = [CompanionAttachment(name: "notes.txt", text: "Unsent context")]
        model.setPanelVisible(true)
        model.showContextPreview()
        let old = try XCTUnwrap(model.contextPreview)
        model.setPanelVisible(false)
        XCTAssertNil(model.contextPreview)
        model.sendContextPreview(id: old.id)
        XCTAssertFalse(model.isRunning)
        model.setPanelVisible(true)
        model.showContextPreview()
        model.setCompact(true)
        XCTAssertNil(model.contextPreview)
        XCTAssertEqual(model.draft, "Unsent draft")
        XCTAssertEqual(model.attachments.first?.text, "Unsent context")
    }

    @MainActor
    func testPreviewRejectsOversizeInputWithoutClearingIt() {
        let requests = PreviewTestRequests()
        let model = makeModel(recording: requests)
        let draft = String(repeating: "語", count: 30_000)
        model.draft = draft
        model.attachments = [CompanionAttachment(name: "notes.txt", text: "Keep this context")]
        model.showContextPreview()
        XCTAssertNil(model.contextPreview)
        XCTAssertEqual(model.error, CompanionChatError.tooLarge.localizedDescription)
        XCTAssertEqual(model.draft, draft)
        XCTAssertEqual(model.attachments.count, 1)
        XCTAssertFalse(model.isRunning)
        XCTAssertTrue(requests.values.isEmpty)
        XCTAssertTrue(model.messages.isEmpty)
    }

    func testPreviewUsesTheSerializedUTF8LimitWithoutTruncatingContent() throws {
        let sample = try CompanionContextPreview(history: [], draft: "x", attachments: [])
        let available = CompanionChatPolicy.maximumPromptBytes - sample.prompt.utf8.count + 1
        let exact = try CompanionContextPreview(history: [], draft: String(repeating: "x", count: available), attachments: [])
        XCTAssertEqual(exact.prompt.utf8.count, CompanionChatPolicy.maximumPromptBytes)
        XCTAssertEqual(exact.messages.last?.text.count, available)
        XCTAssertThrowsError(try CompanionContextPreview(history: [], draft: exact.messages[0].text + "語", attachments: [])) {
            XCTAssertEqual($0 as? CompanionChatError, .tooLarge)
        }
    }

    @MainActor
    func testNativePanelEscapeReturnsToDraftBeforeRequestingClose() throws {
        _ = NSApplication.shared
        let controller = CompanionPanelController()
        defer { controller.shutdown() }
        var closeRequested = false
        controller.model.onClose = { closeRequested = true }
        controller.model.draft = "Keep this draft"
        controller.model.showContextPreview()
        XCTAssertNotNil(controller.model.contextPreview)
        let panel = try XCTUnwrap(controller.window)
        panel.cancelOperation(nil)
        XCTAssertNil(controller.model.contextPreview)
        XCTAssertFalse(closeRequested)
        XCTAssertEqual(controller.model.draft, "Keep this draft")
        panel.cancelOperation(nil)
        XCTAssertTrue(closeRequested)
    }

    @MainActor
    func testEmptyDraftAndRunningReplyCannotOpenPreview() throws {
        let model = CompanionModel { _, _ in try await Task.sleep(nanoseconds: 1_000_000_000) }
        defer { model.stop() }
        model.draft = " \n "
        model.showContextPreview()
        XCTAssertNil(model.contextPreview)
        model.draft = "Question"
        model.send()
        model.draft = "Next question"
        model.showContextPreview()
        XCTAssertTrue(model.isRunning)
        XCTAssertNil(model.contextPreview)
        XCTAssertEqual(model.draft, "Next question")
    }

    @MainActor
    func testPartialFailedReplyIsNotMisrepresentedAsSentContext() async throws {
        let model = CompanionModel { _, receive in
            receive(.reply(id: "a", text: "Unfinished output"))
            throw CompanionChatError.failed
        }
        model.draft = "First question"
        model.send()
        await settle(model)
        XCTAssertTrue(model.canRetry)
        XCTAssertEqual(model.messages.last?.text, "Unfinished output")
        model.draft = "Follow up"
        model.showContextPreview()
        let preview = try XCTUnwrap(model.contextPreview)
        XCTAssertEqual(preview.messages.map(\.text), ["First question", "Follow up"])
        XCTAssertFalse(preview.prompt.contains("Unfinished output"))
    }

    @MainActor
    private func makeModel(recording requests: PreviewTestRequests) -> CompanionModel {
        CompanionModel { prompt, receive in
            requests.append(prompt)
            receive(.reply(id: "reply", text: "Synthetic reply"))
            receive(.completed)
        }
    }

    @MainActor
    private func settle(_ model: CompanionModel) async {
        for _ in 0..<200 {
            if !model.isRunning { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Synthetic chat did not settle")
        model.stop()
    }
}

private final class PreviewTestRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var prompts: [String] = []
    func append(_ prompt: String) { lock.withLock { prompts.append(prompt) } }
    var values: [String] { lock.withLock { prompts } }
}
