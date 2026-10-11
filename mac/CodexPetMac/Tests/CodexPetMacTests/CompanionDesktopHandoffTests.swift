import AppKit
import CodexPetCore
import XCTest
@testable import Statelet

@MainActor
final class CompanionDesktopHandoffTests: XCTestCase {
    func testMissingApplicationNeverValidatesOrLaunches() async {
        let trust = HandoffTrustProbe()
        var launches = 0
        let activator = CodexDesktopActivator(
            applicationResolver: { _ in nil },
            applicationTrustResolver: { _ in trust.evaluate() },
            newThreadOpener: { _, _ in launches += 1; return true }
        )
        let opened = await activator.openNewThread()
        XCTAssertFalse(opened)
        XCTAssertEqual(trust.evaluations, 0)
        XCTAssertEqual(launches, 0)
    }

    func testUntrustedApplicationNeverLaunches() async throws {
        let fixture = try HandoffApplicationFixture()
        defer { fixture.remove() }
        let trust = HandoffTrustProbe(trusted: false)
        var launches = 0
        let activator = CodexDesktopActivator(
            applicationResolver: { _ in fixture.applicationURL },
            applicationTrustResolver: { _ in trust.evaluate() },
            applicationIdentityResolver: { _ in fixture.identity },
            newThreadOpener: { _, _ in launches += 1; return true }
        )
        let opened = await activator.openNewThread()
        XCTAssertFalse(opened)
        XCTAssertEqual(trust.evaluations, 1)
        XCTAssertEqual(launches, 0)
    }

    func testBlankTaskRevalidatesTrustEvenAfterActivityCacheWasWarmed() async throws {
        let fixture = try HandoffApplicationFixture()
        defer { fixture.remove() }
        let trust = HandoffTrustProbe()
        var launches = 0
        let activator = CodexDesktopActivator(
            applicationResolver: { _ in fixture.applicationURL },
            applicationTrustResolver: { _ in trust.evaluate() },
            applicationIdentityResolver: { _ in fixture.identity },
            newThreadOpener: { _, _ in launches += 1; return true }
        )
        let openable = await activator.openableIDs(for: ["activity": "synthetic-thread"])
        XCTAssertEqual(openable, ["activity"])
        trust.setTrusted(false)
        let opened = await activator.openNewThread()
        XCTAssertFalse(opened)
        XCTAssertEqual(trust.evaluations, 2)
        XCTAssertEqual(launches, 0)
    }

    func testApplicationReplacementOrDisappearanceAfterVerificationNeverLaunches() async throws {
        let fixture = try HandoffApplicationFixture()
        defer { fixture.remove() }
        let replacement = try fixture.replacementIdentity()
        for nextIdentity in [replacement, nil] as [CodexDesktopApplicationIdentity?] {
            var identityReads = 0
            var launches = 0
            let activator = CodexDesktopActivator(
                applicationResolver: { _ in fixture.applicationURL },
                applicationTrustResolver: { _ in true },
                applicationIdentityResolver: { _ in
                    identityReads += 1
                    return identityReads == 1 ? fixture.identity : nextIdentity
                },
                newThreadOpener: { _, _ in launches += 1; return true }
            )
            let opened = await activator.openNewThread()
            XCTAssertFalse(opened)
            XCTAssertEqual(identityReads, 2)
            XCTAssertEqual(launches, 0)
        }
    }

    func testLauncherReceivesOnlyExactBlankURIAndItsResultIsRespected() async throws {
        let fixture = try HandoffApplicationFixture()
        defer { fixture.remove() }
        for result in [false, true] {
            var launched: [(URL, URL)] = []
            var legacyLaunches = 0
            let activator = CodexDesktopActivator(
                applicationResolver: { link in
                    XCTAssertEqual(link.absoluteString, "codex://threads/new")
                    return fixture.applicationURL
                },
                applicationTrustResolver: { _ in true },
                applicationIdentityResolver: { _ in fixture.identity },
                opener: { _, _ in legacyLaunches += 1 },
                newThreadOpener: { link, application in
                    launched.append((link, application))
                    return result
                }
            )
            let opened = await activator.openNewThread()
            XCTAssertEqual(opened, result)
            XCTAssertEqual(launched.count, 1)
            let (link, application) = try XCTUnwrap(launched.first)
            XCTAssertEqual(link.absoluteString, "codex://threads/new")
            XCTAssertNil(link.query)
            XCTAssertNil(link.fragment)
            XCTAssertEqual(application, fixture.applicationURL)
            XCTAssertEqual(legacyLaunches, 0, "Completion-aware launch must be used")
        }
    }

    func testCancelledRequestDoesNotResolveOrLaunch() async {
        var resolutions = 0
        var launches = 0
        let activator = CodexDesktopActivator(
            applicationResolver: { _ in resolutions += 1; return nil },
            newThreadOpener: { _, _ in launches += 1; return true }
        )
        let task = Task { await activator.openNewThread() }
        task.cancel()
        let opened = await task.value
        XCTAssertFalse(opened)
        XCTAssertEqual(resolutions, 0)
        XCTAssertEqual(launches, 0)
    }

    func testSuccessAndFailurePreserveConversationDraftPreviewAndUnreadWithoutSending() async throws {
        for result in [false, true] {
            let requests = HandoffTrustProbe()
            let model = CompanionModel { _, receive in
                _ = requests.evaluate()
                receive(.reply(id: "reply", text: "Synthetic reply"))
                receive(.completed)
            }
            defer { model.shutdown() }
            model.draft = "Earlier question"
            model.send()
            await settle(model)
            let messages = model.messages
            let sent = model.sentMessages
            let status = model.status
            model.draft = "  Private unsent question 語  "
            let attachment = CompanionAttachment(name: "synthetic.txt", text: "Private selected context")
            model.attachments = [attachment]
            model.showContextPreview()
            let preview = try XCTUnwrap(model.contextPreview)
            model.error = "Preserve the existing chat error"
            let active = try SessionActivityItem(id: String(repeating: "a", count: 24), state: .waiting,
                                                 event: .permissionRequest, eventAt: 10, terminal: false)
            let unread = try SessionActivityItem(id: String(repeating: "b", count: 24), state: .idle,
                                                 event: .sessionEnd, eventAt: 11, terminal: true)
            model.activity = [active]
            model.completed = [unread]
            var activityActions = 0
            model.onAcknowledge = { _ in activityActions += 1 }
            model.onClearCompleted = { activityActions += 1 }
            model.onOpenTask = { _ in activityActions += 1 }
            var launches = 0
            model.onOpenNewTask = { launches += 1; return result }

            await model.openNewCodexTask()

            XCTAssertEqual(model.desktopHandoff, result ? .opened : .unavailable)
            XCTAssertEqual(launches, 1)
            XCTAssertEqual(requests.evaluations, 1, "Handoff must not send another chat request")
            XCTAssertFalse(model.isRunning)
            XCTAssertEqual(model.messages, messages)
            XCTAssertEqual(model.sentMessages, sent)
            XCTAssertEqual(model.status, status)
            XCTAssertEqual(model.error, "Preserve the existing chat error")
            XCTAssertEqual(model.draft, "  Private unsent question 語  ")
            XCTAssertEqual(model.attachments.map(\.id), [attachment.id])
            XCTAssertEqual(model.attachments.first?.text, attachment.text)
            XCTAssertEqual(model.contextPreview?.id, preview.id)
            XCTAssertEqual(model.contextPreview?.prompt, preview.prompt)
            XCTAssertEqual(model.activity, [active])
            XCTAssertEqual(model.completed, [unread])
            XCTAssertEqual(activityActions, 0)
        }
    }

    func testPendingClicksCoalesceAndCompletionKeepsTheLatestDraftAndAttachments() async throws {
        let model = CompanionModel { _, _ in XCTFail("Handoff must not run Quick Chat") }
        defer { model.shutdown() }
        let started = expectation(description: "Launcher started")
        var pending: CheckedContinuation<Bool, Never>?
        defer { pending?.resume(returning: false) }
        var launches = 0
        model.onOpenNewTask = {
            launches += 1
            return await withCheckedContinuation {
                pending = $0
                started.fulfill()
            }
        }
        model.draft = "Original draft"
        let first = Task { await model.openNewCodexTask() }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(model.desktopHandoff, .opening)
        await model.openNewCodexTask()
        XCTAssertEqual(launches, 1)
        let replacement = CompanionAttachment(name: "new.txt", text: "Latest selected context")
        model.draft = "Latest unsent draft"
        model.attachments = [replacement]
        model.showContextPreview()
        let preview = try XCTUnwrap(model.contextPreview)
        let completion = try XCTUnwrap(pending)
        pending = nil
        completion.resume(returning: true)
        await first.value
        XCTAssertEqual(model.desktopHandoff, .opened)
        XCTAssertEqual(model.draft, "Latest unsent draft")
        XCTAssertEqual(model.attachments.map(\.id), [replacement.id])
        XCTAssertEqual(model.attachments.first?.text, replacement.text)
        XCTAssertEqual(model.contextPreview?.id, preview.id)
        XCTAssertEqual(launches, 1)
    }

    func testImmediateSuccessfulClickBurstCoalescesButLaterRequestCanOpen() async {
        var clock: TimeInterval = 100
        let model = CompanionModel(handoffClock: { clock }) { _, _ in XCTFail("Unexpected chat request") }
        defer { model.shutdown() }
        var launches = 0
        model.onOpenNewTask = { launches += 1; return true }
        await model.openNewCodexTask()
        await model.openNewCodexTask()
        clock += 0.99
        await model.openNewCodexTask()
        XCTAssertEqual(launches, 1)
        clock = 101
        await model.openNewCodexTask()
        XCTAssertEqual(launches, 2)
        XCTAssertEqual(model.desktopHandoff, .opened)
    }

    func testFailureAndMissingHandlerCanBeRetriedImmediately() async {
        let model = CompanionModel(handoffClock: { 100 }) { _, _ in XCTFail("Unexpected chat request") }
        defer { model.shutdown() }
        await model.openNewCodexTask()
        XCTAssertEqual(model.desktopHandoff, .unavailable)
        var launches = 0
        model.onOpenNewTask = { launches += 1; return launches > 1 }
        await model.openNewCodexTask()
        XCTAssertEqual(model.desktopHandoff, .unavailable)
        await model.openNewCodexTask()
        XCTAssertEqual(model.desktopHandoff, .opened)
        XCTAssertEqual(launches, 2)
    }

    func testHandoffLeavesAnExistingChatRequestRunning() async {
        let model = CompanionModel { _, _ in try await Task.sleep(nanoseconds: 60_000_000_000) }
        defer { model.shutdown() }
        model.draft = "Current question"
        model.send()
        model.draft = "Next unsent question"
        let status = model.status
        let messages = model.messages
        let sent = model.sentMessages
        model.onOpenNewTask = { true }
        await model.openNewCodexTask()
        XCTAssertTrue(model.isRunning)
        XCTAssertEqual(model.status, status)
        XCTAssertEqual(model.messages, messages)
        XCTAssertEqual(model.sentMessages, sent)
        XCTAssertEqual(model.draft, "Next unsent question")
    }

    func testNativeControllerWiresVerifiedLauncherAndKeepsDraft() async throws {
        _ = NSApplication.shared
        let fixture = try HandoffApplicationFixture()
        defer { fixture.remove() }
        var links: [URL] = []
        let activator = CodexDesktopActivator(
            applicationResolver: { _ in fixture.applicationURL },
            applicationTrustResolver: { _ in true },
            applicationIdentityResolver: { _ in fixture.identity },
            newThreadOpener: { link, _ in links.append(link); return true }
        )
        let controller = CompanionPanelController(desktopActivator: activator)
        defer { controller.shutdown() }
        controller.model.draft = "Keep this native-panel draft"
        await controller.model.openNewCodexTask()
        XCTAssertEqual(links.map(\.absoluteString), ["codex://threads/new"])
        XCTAssertEqual(controller.model.desktopHandoff, .opened)
        XCTAssertEqual(controller.model.draft, "Keep this native-panel draft")
        XCTAssertTrue(controller.model.messages.isEmpty)
    }

    private func settle(_ model: CompanionModel) async {
        for _ in 0..<200 {
            if !model.isRunning { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Synthetic chat did not settle")
        model.stop()
    }
}

private struct HandoffApplicationFixture {
    let root: URL
    let applicationURL: URL
    let executableURL: URL
    let infoURL: URL
    let codeResourcesURL: URL
    let identity: CodexDesktopApplicationIdentity

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("statelet-handoff-\(UUID())")
        applicationURL = root.appendingPathComponent("Codex.app")
        executableURL = applicationURL.appendingPathComponent("Contents/MacOS/Codex")
        infoURL = applicationURL.appendingPathComponent("Contents/Info.plist")
        codeResourcesURL = applicationURL.appendingPathComponent("Contents/_CodeSignature/CodeResources")
        for url in [executableURL, infoURL, codeResourcesURL] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("synthetic fixture".utf8).write(to: url)
        }
        identity = CodexDesktopApplicationIdentity(
            bundleRevision: try XCTUnwrap(LocalFileRevision(url: applicationURL)),
            executableRevision: try XCTUnwrap(LocalFileRevision(url: executableURL)),
            infoRevision: try XCTUnwrap(LocalFileRevision(url: infoURL)),
            codeResourcesRevision: try XCTUnwrap(LocalFileRevision(url: codeResourcesURL))
        )
    }

    func replacementIdentity() throws -> CodexDesktopApplicationIdentity {
        try Data("changed synthetic signature fixture".utf8).write(to: codeResourcesURL)
        return CodexDesktopApplicationIdentity(
            bundleRevision: identity.bundleRevision, executableRevision: identity.executableRevision,
            infoRevision: identity.infoRevision,
            codeResourcesRevision: try XCTUnwrap(LocalFileRevision(url: codeResourcesURL))
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private final class HandoffTrustProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var trusted: Bool
    private var count = 0
    init(trusted: Bool = true) { self.trusted = trusted }
    var evaluations: Int { lock.withLock { count } }
    func setTrusted(_ value: Bool) { lock.withLock { trusted = value } }
    func evaluate() -> Bool { lock.withLock { count += 1; return trusted } }
}
