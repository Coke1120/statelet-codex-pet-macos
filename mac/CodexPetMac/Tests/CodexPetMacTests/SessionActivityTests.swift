import AppKit
import CodexPetCore
import XCTest
@testable import Statelet

private final class ActivityReaderState: @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0
    private var delivered: [Double] = []

    func nextCall() -> Int {
        lock.withLock {
            callCount += 1
            return callCount
        }
    }

    func append(_ value: Double) {
        lock.withLock { delivered.append(value) }
    }

    var values: [Double] { lock.withLock { delivered } }
}

private final class ActivationTrustProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var trusted = true
    private var evaluations = 0
    private var mainThreadEvaluations = 0

    func setTrusted(_ value: Bool) {
        lock.withLock { trusted = value }
    }

    func evaluate() -> Bool {
        lock.withLock {
            evaluations += 1
            if Thread.isMainThread {
                mainThreadEvaluations += 1
            }
            return trusted
        }
    }

    var evaluationCount: Int { lock.withLock { evaluations } }
    var mainThreadEvaluationCount: Int { lock.withLock { mainThreadEvaluations } }
}

final class SessionActivityTests: XCTestCase {
    private func item(
        _ hex: String,
        state: PetState,
        event: CurrentStateHookEvent,
        terminal: Bool,
        eventAt: Double
    ) throws -> SessionActivityItem {
        try SessionActivityItem(
            id: String(repeating: hex, count: 24),
            state: state,
            event: event,
            eventAt: eventAt,
            terminal: terminal
        )
    }

    @MainActor
    func testPresentationFiltersAcknowledgementsAndBoundsRows() throws {
        let active = try [
            item("a", state: .waiting, event: .permissionRequest, terminal: false, eventAt: 1),
            item("b", state: .review, event: .preCompact, terminal: false, eventAt: 2),
            item("c", state: .running, event: .userPromptSubmit, terminal: false, eventAt: 3),
            item("d", state: .running, event: .postToolUse, terminal: false, eventAt: 4),
        ]
        let completed = try [
            item("e", state: .idle, event: .sessionEnd, terminal: true, eventAt: 5),
            item("f", state: .idle, event: .stop, terminal: true, eventAt: 6),
        ]
        let snapshot = try SessionActivitySnapshot(
            emittedAt: 10,
            active: active,
            completed: completed
        )

        let display = SessionActivityPresentation.displayState(
            snapshot: snapshot,
            acknowledgedIDs: [String(repeating: "e", count: 24)],
            compact: false,
            maximumRowsPerGroup: 3
        )
        XCTAssertEqual(display.active.count, 3)
        XCTAssertEqual(display.hiddenActiveCount, 1)
        XCTAssertTrue(display.completed.isEmpty)
        XCTAssertEqual(display.hiddenCompletedCount, 0)
    }

    @MainActor
    func testViewRendersUnreadActionAndCompactCounts() throws {
        let completed = try item(
            "a",
            state: .idle,
            event: .sessionEnd,
            terminal: true,
            eventAt: 90
        )
        let snapshot = try SessionActivitySnapshot(
            emittedAt: 100,
            completed: [completed]
        )
        let view = SessionActivityView(
            frame: NSRect(x: 0, y: 0, width: 230, height: 150),
            clock: { Date(timeIntervalSince1970: 100) }
        )
        var acknowledged: String?
        view.onAcknowledge = { acknowledged = $0 }
        view.update(snapshot: snapshot, acknowledgedIDs: [])
        view.layoutSubtreeIfNeeded()

        XCTAssertFalse(view.isHidden)
        XCTAssertEqual(view.renderedItemIDs, [completed.id])
        let button = allDescendants(of: view).compactMap { $0 as? NSButton }.first {
            $0.title == "Mark as read"
        }
        XCTAssertNotNil(button)
        button?.performClick(nil)
        XCTAssertEqual(acknowledged, completed.id)

        view.setCompactOverride(true)
        XCTAssertTrue(view.displayState.compact)
        XCTAssertEqual(view.displayState.hiddenCompletedCount, 1)
        XCTAssertTrue(view.renderedItemIDs.isEmpty)
        let targets = [completed.id: "thread-a"]
        XCTAssertTrue(
            SessionActivityTitleHydrationPolicy.eligibleTargets(
                targets: targets,
                renderedItemIDs: view.renderedItemIDs,
                panelVisible: true,
                layoutAvailable: true
            ).isEmpty
        )
        let pill = allDescendants(of: view).compactMap { $0 as? NSButton }.first {
            $0.title == "Completed · 1"
        }
        XCTAssertNotNil(pill)
        pill?.performClick(nil)
        XCTAssertFalse(view.displayState.compact)
        XCTAssertEqual(
            SessionActivityTitleHydrationPolicy.eligibleTargets(
                targets: targets,
                renderedItemIDs: view.renderedItemIDs,
                panelVisible: true,
                layoutAvailable: true
            ),
            targets
        )
        let scrollContainer = SessionActivityScrollContainer(activityView: view)
        scrollContainer.frame = NSRect(x: 0, y: 0, width: 190, height: 44)
        scrollContainer.setScrollable(true)
        scrollContainer.layoutSubtreeIfNeeded()
        XCTAssertTrue(scrollContainer.hasVerticalScroller)
        XCTAssertEqual(view.renderedItemIDs, [completed.id])
        XCTAssertGreaterThan(view.frame.height, scrollContainer.contentSize.height)

        let accessibilityValues = allDescendants(of: view).compactMap {
            $0.accessibilityValue() as? String
        }
        XCTAssertFalse(accessibilityValues.contains { $0.contains("ago ago") })
    }

    @MainActor
    func testActivityRowsAreExplicitlyInformationalWhenActivationIsUnavailable() throws {
        let active = try item(
            "a",
            state: .running,
            event: .userPromptSubmit,
            terminal: false,
            eventAt: 90
        )
        let snapshot = try SessionActivitySnapshot(emittedAt: 100, active: [active])
        let view = SessionActivityView(
            frame: NSRect(x: 0, y: 0, width: 230, height: 150),
            clock: { Date(timeIntervalSince1970: 100) }
        )
        view.update(snapshot: snapshot, acknowledgedIDs: [])
        view.layoutSubtreeIfNeeded()

        XCTAssertTrue(
            allDescendants(of: view).compactMap { $0 as? NSTextField }.contains {
                $0.stringValue.contains("activation is unavailable")
            }
        )
        let rowLabel = try XCTUnwrap(
            allDescendants(of: view).compactMap { $0 as? NSTextField }.first {
                $0.accessibilityLabel()?.contains("active running") == true
            }
        )
        XCTAssertEqual(rowLabel.accessibilityRole(), .staticText)
        XCTAssertEqual(rowLabel.accessibilityLabel(), "Codex, active running session 1")
    }

    @MainActor
    func testGrokRowsShowProviderAndNeverExposeCodexActivation() throws {
        let grok = try SessionActivityItem(
            id: String(repeating: "a", count: 24),
            state: .running,
            event: .userPromptSubmit,
            eventAt: 90,
            terminal: false,
            provider: .grok
        )
        let view = SessionActivityView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 150),
            clock: { Date(timeIntervalSince1970: 100) }
        )
        view.update(
            snapshot: try SessionActivitySnapshot(emittedAt: 100, active: [grok]),
            acknowledgedIDs: [],
            openableIDs: [grok.id],
            titles: [grok.id: "Must not hydrate"]
        )

        XCTAssertEqual(view.accessibilityLabel(), "Agent session activity")
        XCTAssertFalse(allDescendants(of: view).compactMap { $0 as? NSButton }.contains {
            $0.title == "Open in Codex"
        })
        XCTAssertTrue(allDescendants(of: view).compactMap { $0 as? NSTextField }.contains {
            $0.stringValue.contains("Grok")
        })
        XCTAssertFalse(allDescendants(of: view).compactMap { $0 as? NSTextField }.contains {
            $0.stringValue.contains("Must not hydrate")
        })
    }

    @MainActor
    func testOpenButtonEmitsOnlyHashedIDAndDoesNotAcknowledge() throws {
        let completed = try item(
            "a",
            state: .idle,
            event: .sessionEnd,
            terminal: true,
            eventAt: 90
        )
        let view = SessionActivityView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 150),
            clock: { Date(timeIntervalSince1970: 100) }
        )
        var opened: String?
        var acknowledged: String?
        view.onOpen = { opened = $0 }
        view.onAcknowledge = { acknowledged = $0 }
        view.update(
            snapshot: try SessionActivitySnapshot(emittedAt: 100, completed: [completed]),
            acknowledgedIDs: [],
            openableIDs: [completed.id]
        )

        let buttons = allDescendants(of: view).compactMap { $0 as? NSButton }
        let open = try XCTUnwrap(buttons.first { $0.title == "Open in Codex" })
        open.performClick(nil)
        XCTAssertEqual(opened, completed.id)
        XCTAssertNil(acknowledged)
        XCTAssertNotNil(buttons.first { $0.title == "Mark as read" })
    }

    @MainActor
    func testExpandedRowsShowPrivateTitlesWithoutChangingActionsOrCompactCounts() throws {
        let active = try item(
            "a",
            state: .running,
            event: .userPromptSubmit,
            terminal: false,
            eventAt: 90
        )
        let completed = try item(
            "b",
            state: .idle,
            event: .sessionEnd,
            terminal: true,
            eventAt: 91
        )
        let view = SessionActivityView(
            frame: NSRect(x: 0, y: 0, width: 360, height: 180),
            clock: { Date(timeIntervalSince1970: 100) }
        )
        var opened: String?
        var acknowledged: String?
        view.onOpen = { opened = $0 }
        view.onAcknowledge = { acknowledged = $0 }
        view.update(
            snapshot: try SessionActivitySnapshot(
                emittedAt: 100,
                active: [active],
                completed: [completed]
            ),
            acknowledgedIDs: [],
            openableIDs: [active.id, completed.id],
            titles: [
                active.id: "Repair tool execution",
                completed.id: "Verify release signing",
            ]
        )
        view.layoutSubtreeIfNeeded()

        let labels = allDescendants(of: view).compactMap { $0 as? NSTextField }
        let activeLabel = try XCTUnwrap(labels.first {
            $0.stringValue.hasPrefix("Codex · Repair tool execution · Running")
        })
        XCTAssertEqual(
            activeLabel.accessibilityLabel(),
            "Codex, Repair tool execution, active running session 1"
        )
        XCTAssertEqual(activeLabel.lineBreakMode, .byTruncatingTail)

        let completedLabel = try XCTUnwrap(labels.first {
            $0.stringValue.hasPrefix("Codex · Verify release signing · Completed")
        })
        XCTAssertEqual(
            completedLabel.accessibilityLabel(),
            "Codex, Verify release signing, completed unread session 1"
        )
        XCTAssertTrue(completedLabel.stringValue.contains("Unread"))

        let buttons = allDescendants(of: view).compactMap { $0 as? NSButton }
        let openButtons = buttons.filter { $0.title == "Open in Codex" }
        XCTAssertEqual(openButtons.count, 2)
        openButtons[0].performClick(nil)
        XCTAssertTrue([active.id, completed.id].contains(opened))
        XCTAssertNil(acknowledged)
        try XCTUnwrap(buttons.first { $0.title == "Mark as read" }).performClick(nil)
        XCTAssertEqual(acknowledged, completed.id)

        view.setCompactOverride(true)
        let compactText = allDescendants(of: view).compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertFalse(compactText.contains { $0.contains("Repair tool execution") })
        XCTAssertFalse(compactText.contains { $0.contains("Verify release signing") })
        XCTAssertNotNil(allDescendants(of: view).compactMap { $0 as? NSButton }.first {
            $0.title == "Running · 1"
        })
        XCTAssertNotNil(allDescendants(of: view).compactMap { $0 as? NSButton }.first {
            $0.title == "Completed · 1"
        })
    }

    @MainActor
    func testSoftEmptyTitleRefreshRetainsLongRenderedTitleLayoutAndActions() throws {
        let completed = try item(
            "a",
            state: .idle,
            event: .sessionEnd,
            terminal: true,
            eventAt: 90
        )
        let snapshot = try SessionActivitySnapshot(emittedAt: 100, completed: [completed])
        let targets = [completed.id: "thread-a"]
        let renderedIDs = [completed.id]
        let longTitle = "Review the complete signed release verification evidence"
        let accepted = try XCTUnwrap(
            SessionActivityTitleHydrationPolicy.adopting(
                resolvedTitles: [completed.id: longTitle],
                retainedTitles: [:],
                requestedTargets: targets,
                currentTargets: targets,
                expectedEmittedAt: snapshot.emittedAt,
                currentEmittedAt: snapshot.emittedAt,
                expectedRenderedItemIDs: renderedIDs,
                currentRenderedItemIDs: renderedIDs,
                panelVisible: true,
                layoutAvailable: true,
                requestGeneration: 1,
                currentGeneration: 1
            )
        )

        let view = SessionActivityView(
            frame: NSRect(x: 0, y: 0, width: 230, height: 150),
            clock: { Date(timeIntervalSince1970: 100) }
        )
        var opened: String?
        var acknowledged: String?
        view.onOpen = { opened = $0 }
        view.onAcknowledge = { acknowledged = $0 }
        view.update(
            snapshot: snapshot,
            acknowledgedIDs: [],
            openableIDs: [completed.id],
            titles: accepted
        )
        view.layoutSubtreeIfNeeded()
        let acceptedFittingSize = view.fittingSize

        let afterSoftEmpty = try XCTUnwrap(
            SessionActivityTitleHydrationPolicy.adopting(
                resolvedTitles: [:],
                retainedTitles: accepted,
                requestedTargets: targets,
                currentTargets: targets,
                expectedEmittedAt: snapshot.emittedAt,
                currentEmittedAt: snapshot.emittedAt,
                expectedRenderedItemIDs: renderedIDs,
                currentRenderedItemIDs: renderedIDs,
                panelVisible: true,
                layoutAvailable: true,
                requestGeneration: 2,
                currentGeneration: 2
            )
        )
        XCTAssertEqual(afterSoftEmpty, accepted)

        view.update(
            snapshot: snapshot,
            acknowledgedIDs: [],
            openableIDs: [completed.id],
            titles: afterSoftEmpty
        )
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.fittingSize, acceptedFittingSize)
        XCTAssertTrue(allDescendants(of: view).compactMap { $0 as? NSTextField }.contains {
            $0.stringValue.hasPrefix("Codex · \(longTitle)")
        })

        let buttons = allDescendants(of: view).compactMap { $0 as? NSButton }
        try XCTUnwrap(buttons.first { $0.title == "Open in Codex" }).performClick(nil)
        XCTAssertEqual(opened, completed.id)
        XCTAssertNil(acknowledged)
        try XCTUnwrap(buttons.first { $0.title == "Mark as read" }).performClick(nil)
        XCTAssertEqual(acknowledged, completed.id)

        // A long accepted title can make the final layout choose compact mode.
        // Once compact removes all rendered rows, the retention-only final pass
        // must discard that title without triggering another lookup/reflow.
        view.setCompactOverride(true)
        XCTAssertTrue(view.renderedItemIDs.isEmpty)
        let afterCompactReflow = SessionActivityTitleHydrationPolicy.retainingTitlesForFinalPresentation(
            afterSoftEmpty,
            currentTargets: targets,
            renderedItemIDs: view.renderedItemIDs,
            panelVisible: true,
            layoutAvailable: true
        )
        XCTAssertTrue(afterCompactReflow.isEmpty)
        view.update(
            snapshot: snapshot,
            acknowledgedIDs: [],
            openableIDs: [completed.id],
            titles: afterCompactReflow
        )
        XCTAssertTrue(view.displayState.compact)
        XCTAssertTrue(view.renderedItemIDs.isEmpty)
    }

    @MainActor
    func testMissingPrivateTitlePreservesGenericRowContract() throws {
        let active = try item(
            "a",
            state: .running,
            event: .userPromptSubmit,
            terminal: false,
            eventAt: 90
        )
        let view = SessionActivityView(
            frame: NSRect(x: 0, y: 0, width: 230, height: 150),
            clock: { Date(timeIntervalSince1970: 100) }
        )
        view.update(
            snapshot: try SessionActivitySnapshot(emittedAt: 100, active: [active]),
            acknowledgedIDs: [],
            titles: [:]
        )
        view.layoutSubtreeIfNeeded()

        let rowLabel = try XCTUnwrap(
            allDescendants(of: view).compactMap { $0 as? NSTextField }.first {
                $0.accessibilityLabel() == "Codex, active running session 1"
            }
        )
        XCTAssertEqual(rowLabel.stringValue, "Codex · Running · Lifecycle #1 · just now")
    }

    @MainActor
    func testCodexDesktopActivationPolicyCoalescesOffMainAndRevalidatesOpen() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("statelet-codex-activation-\(UUID().uuidString)", isDirectory: true)
        let appURL = temporaryRoot.appendingPathComponent("Codex.app", isDirectory: true)
        let executableURL = appURL.appendingPathComponent("Contents/MacOS/Codex")
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        let codeResourcesURL = appURL.appendingPathComponent("Contents/_CodeSignature/CodeResources")
        try FileManager.default.createDirectory(
            at: executableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: codeResourcesURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("executable".utf8).write(to: executableURL)
        try Data("info".utf8).write(to: infoURL)
        try Data("signature".utf8).write(to: codeResourcesURL)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        var currentIdentity = CodexDesktopApplicationIdentity(
            bundleRevision: try XCTUnwrap(LocalFileRevision(url: appURL)),
            executableRevision: try XCTUnwrap(LocalFileRevision(url: executableURL)),
            infoRevision: try XCTUnwrap(LocalFileRevision(url: infoURL)),
            codeResourcesRevision: try XCTUnwrap(LocalFileRevision(url: codeResourcesURL))
        )

        let trustProbe = ActivationTrustProbe()
        var resolverCalls = 0
        var opened: (URL, URL)?
        let trusted = CodexDesktopActivator(
            applicationResolver: { _ in
                resolverCalls += 1
                return appURL
            },
            applicationTrustResolver: { _ in trustProbe.evaluate() },
            applicationIdentityResolver: { _ in currentIdentity },
            opener: { opened = ($0, $1) }
        )
        let targets = Dictionary(uniqueKeysWithValues: (0 ..< 10).map {
            ("activity-\($0)", "thread-\($0)")
        })
        let firstOpenableIDs = await trusted.openableIDs(for: targets)
        XCTAssertEqual(firstOpenableIDs, Set(targets.keys))
        XCTAssertEqual(resolverCalls, 1)
        XCTAssertEqual(trustProbe.evaluationCount, 1)
        XCTAssertEqual(trustProbe.mainThreadEvaluationCount, 0)

        let cachedOpenableIDs = await trusted.openableIDs(for: targets)
        XCTAssertEqual(cachedOpenableIDs, firstOpenableIDs)
        XCTAssertEqual(trustProbe.evaluationCount, 1)

        try Data("updated-signature".utf8).write(to: codeResourcesURL)
        currentIdentity = CodexDesktopApplicationIdentity(
            bundleRevision: try XCTUnwrap(LocalFileRevision(url: appURL)),
            executableRevision: try XCTUnwrap(LocalFileRevision(url: executableURL)),
            infoRevision: try XCTUnwrap(LocalFileRevision(url: infoURL)),
            codeResourcesRevision: try XCTUnwrap(LocalFileRevision(url: codeResourcesURL))
        )
        let refreshedOpenableIDs = await trusted.openableIDs(for: targets)
        XCTAssertEqual(refreshedOpenableIDs, firstOpenableIDs)
        XCTAssertEqual(trustProbe.evaluationCount, 2, "A changed app identity must invalidate trust")

        let didOpenTrustedTarget = await trusted.open(threadID: "thread/with?reserved")
        XCTAssertTrue(didOpenTrustedTarget)
        XCTAssertEqual(trustProbe.evaluationCount, 3, "Open must perform one fresh fail-closed validation")
        XCTAssertEqual(opened?.0.absoluteString, "codex://threads/thread%2Fwith%3Freserved")
        XCTAssertEqual(opened?.1, appURL)

        trustProbe.setTrusted(false)
        let didOpenUntrustedTarget = await trusted.open(threadID: "valid")
        XCTAssertFalse(didOpenUntrustedTarget)
        XCTAssertEqual(trustProbe.evaluationCount, 4)
        XCTAssertEqual(opened?.0.absoluteString, "codex://threads/thread%2Fwith%3Freserved")

        let invalidOpenableIDs = await trusted.openableIDs(for: ["invalid": "contains space"])
        XCTAssertTrue(invalidOpenableIDs.isEmpty)
        XCTAssertEqual(CodexDesktopActivationPolicy.trustedBundleIdentifier, "com.openai.codex")
        XCTAssertEqual(CodexDesktopActivationPolicy.trustedTeamIdentifier, "2DC432GLL2")
        XCTAssertNil(CodexDesktopActivationPolicy.deepLink(for: "contains space"))
        XCTAssertNil(CodexDesktopActivationPolicy.deepLink(
            for: String(repeating: "a", count: CodexDesktopActivationPolicy.maximumThreadIDBytes + 1)
        ))
    }

    func testTargetValidationRequiresExactSnapshotAndKnownUniqueIDs() throws {
        let active = try item(
            "a",
            state: .running,
            event: .userPromptSubmit,
            terminal: false,
            eventAt: 90
        )
        let snapshot = try SessionActivitySnapshot(emittedAt: 100, active: [active])
        let valid = SessionActivityTargets(
            version: 1,
            schemaVersion: 1,
            emittedAt: 100,
            targets: [.init(id: active.id, threadID: "thread-1")]
        )
        XCTAssertEqual(valid.validated(for: snapshot), [active.id: "thread-1"])
        let stale = SessionActivityTargets(
            version: 1,
            schemaVersion: 1,
            emittedAt: 99,
            targets: valid.targets
        )
        XCTAssertTrue(stale.validated(for: snapshot).isEmpty)
        let unknown = SessionActivityTargets(
            version: 1,
            schemaVersion: 1,
            emittedAt: 100,
            targets: [.init(id: String(repeating: "b", count: 24), threadID: "thread-2")]
        )
        XCTAssertTrue(unknown.validated(for: snapshot).isEmpty)

        let grok = try SessionActivityItem(
            id: String(repeating: "b", count: 24),
            state: .running,
            event: .userPromptSubmit,
            eventAt: 91,
            terminal: false,
            provider: .grok
        )
        let mixed = try SessionActivitySnapshot(emittedAt: 101, active: [active, grok])
        let mixedTargets = SessionActivityTargets(
            version: 1,
            schemaVersion: 1,
            emittedAt: 101,
            targets: [
                .init(id: active.id, threadID: "thread-1"),
                .init(id: grok.id, threadID: "thread-grok"),
            ]
        )
        XCTAssertEqual(mixedTargets.validated(for: mixed), [active.id: "thread-1"])
    }

    func testTitleHydrationRejectsStaleCompletionAndClearsRemappedOrUnrenderedRows() throws {
        let active = try item(
            "a",
            state: .running,
            event: .userPromptSubmit,
            terminal: false,
            eventAt: 90
        )
        let completed = try item(
            "b",
            state: .idle,
            event: .sessionEnd,
            terminal: true,
            eventAt: 91
        )
        let stopped = try item(
            "c",
            state: .idle,
            event: .stop,
            terminal: true,
            eventAt: 92
        )
        let snapshot = try SessionActivitySnapshot(
            emittedAt: 100,
            active: [active],
            completed: [completed, stopped]
        )
        let previousTargets = [
            active.id: "thread-a",
            completed.id: "thread-b",
            stopped.id: "thread-c",
        ]
        let remappedTargets = [
            active.id: "thread-new",
            completed.id: "thread-b",
            stopped.id: "thread-c",
        ]
        let renderedIDs = [active.id, completed.id]

        XCTAssertEqual(
            SessionActivityTitleHydrationPolicy.retainingTitles(
                [active.id: "Old active", completed.id: "Completed", stopped.id: "Stopped"],
                previousTargets: previousTargets,
                currentTargets: remappedTargets,
                renderedItemIDs: renderedIDs
            ),
            [completed.id: "Completed"]
        )
        let requested = SessionActivityTitleHydrationPolicy.eligibleTargets(
            targets: remappedTargets,
            renderedItemIDs: renderedIDs,
            panelVisible: true,
            layoutAvailable: true
        )
        XCTAssertEqual(requested, [active.id: "thread-new", completed.id: "thread-b"])
        XCTAssertNil(
            SessionActivityTitleHydrationPolicy.adopting(
                resolvedTitles: [active.id: "Stale title"],
                retainedTitles: [completed.id: "Completed"],
                requestedTargets: requested,
                currentTargets: remappedTargets,
                expectedEmittedAt: snapshot.emittedAt,
                currentEmittedAt: snapshot.emittedAt,
                expectedRenderedItemIDs: renderedIDs,
                currentRenderedItemIDs: renderedIDs,
                panelVisible: true,
                layoutAvailable: true,
                requestGeneration: 4,
                currentGeneration: 5
            )
        )
        XCTAssertNil(
            SessionActivityTitleHydrationPolicy.adopting(
                resolvedTitles: [active.id: "Wrong thread"],
                retainedTitles: [completed.id: "Completed"],
                requestedTargets: requested,
                currentTargets: previousTargets,
                expectedEmittedAt: snapshot.emittedAt,
                currentEmittedAt: snapshot.emittedAt,
                expectedRenderedItemIDs: renderedIDs,
                currentRenderedItemIDs: renderedIDs,
                panelVisible: true,
                layoutAvailable: true,
                requestGeneration: 5,
                currentGeneration: 5
            )
        )
        XCTAssertNil(
            SessionActivityTitleHydrationPolicy.adopting(
                resolvedTitles: [active.id: "Stale snapshot"],
                retainedTitles: [completed.id: "Completed"],
                requestedTargets: requested,
                currentTargets: remappedTargets,
                expectedEmittedAt: snapshot.emittedAt,
                currentEmittedAt: snapshot.emittedAt + 1,
                expectedRenderedItemIDs: renderedIDs,
                currentRenderedItemIDs: renderedIDs,
                panelVisible: true,
                layoutAvailable: true,
                requestGeneration: 5,
                currentGeneration: 5
            )
        )
        XCTAssertNil(
            SessionActivityTitleHydrationPolicy.adopting(
                resolvedTitles: [active.id: "Stale rendered set"],
                retainedTitles: [completed.id: "Completed"],
                requestedTargets: requested,
                currentTargets: remappedTargets,
                expectedEmittedAt: snapshot.emittedAt,
                currentEmittedAt: snapshot.emittedAt,
                expectedRenderedItemIDs: renderedIDs,
                currentRenderedItemIDs: [completed.id],
                panelVisible: true,
                layoutAvailable: true,
                requestGeneration: 5,
                currentGeneration: 5
            )
        )
        XCTAssertEqual(
            SessionActivityTitleHydrationPolicy.adopting(
                resolvedTitles: [:],
                retainedTitles: [completed.id: "Completed"],
                requestedTargets: requested,
                currentTargets: remappedTargets,
                expectedEmittedAt: snapshot.emittedAt,
                currentEmittedAt: snapshot.emittedAt,
                expectedRenderedItemIDs: renderedIDs,
                currentRenderedItemIDs: renderedIDs,
                panelVisible: true,
                layoutAvailable: true,
                requestGeneration: 5,
                currentGeneration: 5
            ),
            [completed.id: "Completed"]
        )
        XCTAssertTrue(
            SessionActivityTitleHydrationPolicy.eligibleTargets(
                targets: remappedTargets,
                renderedItemIDs: renderedIDs,
                panelVisible: false,
                layoutAvailable: true
            ).isEmpty
        )
    }

    func testTitleHydrationRequestsOnlyRowsRenderedByExpandedPresentation() throws {
        let active = try (0..<4).map {
            try item(String($0), state: .running, event: .userPromptSubmit, terminal: false, eventAt: Double($0))
        }
        let completed = try (4..<8).map {
            try item(String($0), state: .idle, event: .sessionEnd, terminal: true, eventAt: Double($0))
        }
        let snapshot = try SessionActivitySnapshot(
            emittedAt: 100,
            active: active,
            completed: completed
        )
        let targets = Dictionary(uniqueKeysWithValues: (active + completed).map {
            ($0.id, "thread-\($0.id)")
        })

        let display = SessionActivityPresentation.displayState(
            snapshot: snapshot,
            acknowledgedIDs: [],
            compact: false
        )
        let renderedIDs = (display.active + display.completed).map(\.id)
        let eligible = SessionActivityTitleHydrationPolicy.eligibleTargets(
            targets: targets,
            renderedItemIDs: renderedIDs,
            panelVisible: true,
            layoutAvailable: true
        )
        XCTAssertEqual(Set(eligible.keys), Set(renderedIDs))
        XCTAssertEqual(eligible.count, 6)
        XCTAssertTrue(
            SessionActivityTitleHydrationPolicy.eligibleTargets(
                targets: targets,
                renderedItemIDs: [],
                panelVisible: true,
                layoutAvailable: true
            ).isEmpty
        )
    }

    func testRejectedEqualTimestampConflictCannotReplaceAcceptedTargets() throws {
        let identifier = String(repeating: "a", count: 24)
        let accepted = try SessionActivitySnapshot(
            emittedAt: 100,
            active: [
                SessionActivityItem(
                    id: identifier,
                    state: .running,
                    event: .userPromptSubmit,
                    eventAt: 90,
                    terminal: false
                )
            ]
        )
        let conflicting = try SessionActivitySnapshot(
            emittedAt: 100,
            active: [
                SessionActivityItem(
                    id: identifier,
                    state: .waiting,
                    event: .permissionRequest,
                    eventAt: 95,
                    terminal: false
                )
            ]
        )
        let application = SessionActivityApplicationPolicy.apply(
            conflicting,
            lastAccepted: accepted,
            currentlyDisplayed: accepted,
            acknowledgementHistory: [],
            now: 100
        )

        XCTAssertEqual(application.decision, .rejectEqualTimestampConflict)
        XCTAssertEqual(application.displayedSnapshot, accepted)
        XCTAssertEqual(
            SessionActivityTargetAdoptionPolicy.apply(
                incomingTargets: [identifier: "wrong-thread"],
                application: application,
                currentlyAcceptedTargets: [identifier: "accepted-thread"]
            ),
            [identifier: "accepted-thread"]
        )
    }

    @MainActor
    func testPanelAppearanceAndPositionStoresRejectInvalidValuesAndRoundTrip() throws {
        let suiteName = "statelet-session-activity-(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let appearance = try SessionActivityPanelAppearance(
            backgroundColor: "#aBc123",
            opacity: 0.41,
            automaticContrast: false
        )
        SessionActivityPanelAppearanceStore.persist(appearance, to: defaults)
        XCTAssertEqual(SessionActivityPanelAppearanceStore.restored(from: defaults), appearance)
        defaults.set(Data("{\"opacity\":99}".utf8), forKey: SessionActivityPanelAppearanceStore.defaultsKey)
        XCTAssertEqual(
            SessionActivityPanelAppearanceStore.restored(from: defaults),
            try SessionActivityPanelAppearance()
        )

        let origin = NSPoint(x: 240, y: 180)
        SessionActivityPanelPositionStore.persist(origin, to: defaults)
        XCTAssertEqual(SessionActivityPanelPositionStore.restored(from: defaults), origin)
        defaults.set(["x": "bad", "y": 10], forKey: SessionActivityPanelPositionStore.defaultsKey)
        XCTAssertNil(SessionActivityPanelPositionStore.restored(from: defaults))

        let clamped = SessionActivityPanelPositionStore.clamped(
            origin: NSPoint(x: -500, y: 1_000),
            size: NSSize(width: 230, height: 150),
            to: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        XCTAssertTrue(
            NSRect(origin: clamped, size: NSSize(width: 230, height: 150))
                .intersection(NSRect(x: 0, y: 0, width: 800, height: 600)).width >= 48
        )

        let secondaryDisplay = NSRect(x: 1_000, y: 0, width: 1_000, height: 800)
        let secondaryOrigin = NSPoint(x: 1_120, y: 180)
        XCTAssertEqual(
            SessionActivityPanelPositionStore.clamped(
                origin: secondaryOrigin,
                size: NSSize(width: 230, height: 150),
                to: [NSRect(x: 0, y: 0, width: 800, height: 600), secondaryDisplay]
            ),
            secondaryOrigin
        )
        let afterDisplayRemoval = SessionActivityPanelPositionStore.clamped(
            origin: secondaryOrigin,
            size: NSSize(width: 230, height: 150),
            to: [NSRect(x: 0, y: 0, width: 800, height: 600)]
        )
        XCTAssertGreaterThanOrEqual(
            NSRect(origin: afterDisplayRemoval, size: NSSize(width: 230, height: 150))
                .intersection(NSRect(x: 0, y: 0, width: 800, height: 600)).width,
            48
        )
    }

    @MainActor
    func testCustomActivityBackgroundResolvesReadableForeground() throws {
        let appearance = try SessionActivityPanelAppearance(
            backgroundColor: "#FFFFFF",
            opacity: 0.4,
            automaticContrast: false
        )
        let resolved = SessionActivityView.resolveAppearance(
            appearance: appearance,
            systemBackgroundColor: .white,
            systemTextColor: .white,
            secondaryTextColor: .white,
            reduceTransparency: false,
            increaseContrast: false
        )

        XCTAssertEqual(resolved.backgroundColor.codexPetHex, "#FFFFFF")
        XCTAssertEqual(resolved.primaryTextColor.codexPetHex, "#000000")
        XCTAssertEqual(resolved.secondaryTextColor.codexPetHex, "#000000")
        XCTAssertGreaterThanOrEqual(resolved.contrastRatio, 4.5)

        let increased = SessionActivityView.resolveAppearance(
            appearance: try SessionActivityPanelAppearance(
                backgroundColor: "#777777",
                opacity: 0.2,
                automaticContrast: false
            ),
            systemBackgroundColor: .white,
            systemTextColor: .white,
            secondaryTextColor: .white,
            reduceTransparency: false,
            increaseContrast: true
        )
        XCTAssertGreaterThanOrEqual(increased.contrastRatio, 7)
        XCTAssertGreaterThanOrEqual(increased.opacity, 0.96)
    }

    @MainActor
    func testActivityContrastClampsZeroOpacityAndSemanticRowsToReadableColors() throws {
        let appearance = try SessionActivityPanelAppearance(
            backgroundColor: "#20242A",
            opacity: 0,
            automaticContrast: true
        )
        let resolved = SessionActivityView.resolveAppearance(
            appearance: appearance,
            systemBackgroundColor: .windowBackgroundColor,
            systemTextColor: .labelColor,
            secondaryTextColor: .secondaryLabelColor,
            reduceTransparency: false,
            increaseContrast: false
        )
        XCTAssertGreaterThan(resolved.opacity, 0)
        XCTAssertGreaterThanOrEqual(resolved.contrastRatio, 4.5)

        let view = SessionActivityView(
            frame: NSRect(x: 0, y: 0, width: 230, height: 150),
            clock: { Date(timeIntervalSince1970: 100) }
        )
        view.applyAppearance(appearance)
        let active = try item(
            "a",
            state: .running,
            event: .userPromptSubmit,
            terminal: false,
            eventAt: 90
        )
        view.update(
            snapshot: try SessionActivitySnapshot(emittedAt: 100, active: [active]),
            acknowledgedIDs: []
        )
        view.layoutSubtreeIfNeeded()
        let rowLabel = try XCTUnwrap(
            allDescendants(of: view).compactMap { $0 as? NSTextField }.first {
                $0.accessibilityLabel()?.contains("active running") == true
            }
        )
        let rowColor = try XCTUnwrap(rowLabel.textColor)
        XCTAssertGreaterThanOrEqual(
            StateletContrast.worstCaseContrast(
                foreground: rowColor,
                background: resolved.backgroundColor,
                opacity: resolved.opacity
            ),
            4.5
        )

        for (secondary, background) in [
            (NSColor(calibratedWhite: 0, alpha: 0.5), NSColor.white),
            (NSColor(calibratedWhite: 1, alpha: 0.5), NSColor.black),
        ] {
            let opaque = StateletContrast.readableForeground(
                requested: secondary,
                background: background,
                minimumContrast: 4.5
            )
            XCTAssertGreaterThanOrEqual(opaque.alphaComponent, 0.999)
            XCTAssertGreaterThanOrEqual(
                StateletContrast.contrastRatio(foreground: opaque, background: background),
                4.5
            )
        }
    }

    @MainActor
    func testPanelAnchorsRightThenFallsBackLeftWithoutLeavingVisibleFrame() {
        let pet = NSRect(x: 600, y: 400, width: 160, height: 160)
        let visible = NSRect(x: 0, y: 0, width: 1_000, height: 800)
        let right = SessionActivityPanel.anchoredFrame(
            beside: pet,
            contentSize: NSSize(width: 200, height: 140),
            visibleFrame: visible
        )
        XCTAssertEqual(right.minX, 770)
        XCTAssertTrue(visible.contains(right))

        let edgePet = NSRect(x: 850, y: 400, width: 140, height: 160)
        let left = SessionActivityPanel.anchoredFrame(
            beside: edgePet,
            contentSize: NSSize(width: 200, height: 140),
            visibleFrame: visible
        )
        XCTAssertEqual(left.maxX, 840)
        XCTAssertTrue(visible.contains(left))
    }

    @MainActor
    func testLayoutPolicyUsesCompactModeForActualSideSpaceAndExpandsOnRequest() {
        let visible = NSRect(x: 0, y: 0, width: 400, height: 300)
        let pet = NSRect(x: 150, y: 80, width: 100, height: 140)
        let automatic = SessionActivityLayoutPolicy.layout(
            beside: pet,
            expandedSize: NSSize(width: 230, height: 150),
            compactSize: NSSize(width: 100, height: 60),
            visibleFrame: visible,
            forceExpanded: false
        )
        XCTAssertTrue(automatic.compact)
        XCTAssertTrue(automatic.available)
        XCTAssertTrue(visible.contains(automatic.frame))
        XCTAssertFalse(automatic.frame.intersects(pet))

        let expanded = SessionActivityLayoutPolicy.layout(
            beside: pet,
            expandedSize: NSSize(width: 230, height: 150),
            compactSize: NSSize(width: 100, height: 60),
            visibleFrame: visible,
            forceExpanded: true
        )
        XCTAssertFalse(expanded.compact)
        XCTAssertTrue(expanded.scrollable)
        XCTAssertTrue(visible.contains(expanded.frame))
        XCTAssertFalse(expanded.frame.intersects(pet))

        let oversized = SessionActivityPanel.anchoredFrame(
            beside: pet,
            contentSize: NSSize(width: 800, height: 600),
            visibleFrame: visible
        )
        XCTAssertTrue(visible.contains(oversized))
        XCTAssertFalse(oversized.intersects(pet))
    }

    @MainActor
    func testProductionSizeCompactAndForcedExpandedLayoutsNeverOverlapPet() {
        let visible = NSRect(x: 0, y: 0, width: 600, height: 400)
        let pet = NSRect(x: 185, y: 120, width: 230, height: 150)
        let automatic = SessionActivityLayoutPolicy.layout(
            beside: pet,
            expandedSize: NSSize(width: 230, height: 150),
            compactSize: NSSize(width: 190, height: 68),
            visibleFrame: visible,
            forceExpanded: false
        )
        XCTAssertTrue(automatic.compact)
        XCTAssertFalse(automatic.scrollable)
        XCTAssertTrue(visible.contains(automatic.frame))
        XCTAssertFalse(automatic.frame.intersects(pet))
        XCTAssertEqual(automatic.frame.size, NSSize(width: 190, height: 68))

        let forced = SessionActivityLayoutPolicy.layout(
            beside: pet,
            expandedSize: NSSize(width: 230, height: 150),
            compactSize: NSSize(width: 190, height: 68),
            visibleFrame: visible,
            forceExpanded: true
        )
        XCTAssertFalse(forced.compact)
        XCTAssertTrue(forced.scrollable)
        XCTAssertTrue(visible.contains(forced.frame))
        XCTAssertFalse(forced.frame.intersects(pet))
        XCTAssertEqual(forced.frame.size, NSSize(width: 190, height: 68))

        let roomyVisible = NSRect(x: 0, y: 0, width: 1_000, height: 700)
        let roomyPet = NSRect(x: 300, y: 250, width: 230, height: 150)
        let fullExpandedSize = NSSize(width: 230, height: 150)
        let fullExpanded = SessionActivityLayoutPolicy.layout(
            beside: roomyPet,
            expandedSize: fullExpandedSize,
            compactSize: NSSize(width: 190, height: 68),
            visibleFrame: roomyVisible,
            forceExpanded: true
        )
        XCTAssertFalse(fullExpanded.compact)
        XCTAssertFalse(fullExpanded.scrollable)
        XCTAssertEqual(fullExpanded.frame.size, fullExpandedSize)
        XCTAssertFalse(fullExpanded.frame.intersects(roomyPet))

        let constrainedVisible = NSRect(x: 0, y: 0, width: 300, height: 200)
        let constrainedPet = NSRect(x: 50, y: 40, width: 200, height: 120)
        let overflow = SessionActivityLayoutPolicy.layout(
            beside: constrainedPet,
            expandedSize: fullExpandedSize,
            compactSize: NSSize(width: 190, height: 68),
            visibleFrame: constrainedVisible,
            forceExpanded: false
        )
        XCTAssertFalse(overflow.compact)
        XCTAssertTrue(overflow.available)
        XCTAssertTrue(overflow.scrollable)
        XCTAssertTrue(constrainedVisible.contains(overflow.frame))
        XCTAssertFalse(overflow.frame.intersects(constrainedPet))

        let coveredVisible = NSRect(x: 0, y: 0, width: 300, height: 200)
        let unavailable = SessionActivityLayoutPolicy.layout(
            beside: coveredVisible,
            expandedSize: fullExpandedSize,
            compactSize: NSSize(width: 190, height: 68),
            visibleFrame: coveredVisible,
            forceExpanded: true
        )
        XCTAssertFalse(unavailable.available)
        XCTAssertFalse(unavailable.scrollable)
        XCTAssertEqual(unavailable.frame, .zero)
    }

    @MainActor
    func testUnavailableLayoutBecomingFeasibleRestoresPanelWithEffectiveWindowLevel() {
        let visible = NSRect(x: 0, y: 0, width: 600, height: 400)
        let unavailable = SessionActivityLayoutPolicy.layout(
            beside: visible,
            expandedSize: NSSize(width: 230, height: 150),
            compactSize: NSSize(width: 190, height: 68),
            visibleFrame: visible,
            forceExpanded: false
        )
        let available = SessionActivityLayoutPolicy.layout(
            beside: NSRect(x: 185, y: 120, width: 230, height: 150),
            expandedSize: NSSize(width: 230, height: 150),
            compactSize: NSSize(width: 190, height: 68),
            visibleFrame: visible,
            forceExpanded: false
        )

        XCTAssertFalse(unavailable.available)
        XCTAssertTrue(available.available)
        XCTAssertTrue(SessionActivityPanelVisibilityPolicy.shouldOrderFront(
            wasAvailable: unavailable.available,
            isAvailable: available.available
        ))
        XCTAssertFalse(SessionActivityPanelVisibilityPolicy.shouldOrderFront(
            wasAvailable: true,
            isAvailable: true
        ))

        let panel = SessionActivityPanel(
            contentRect: available.frame,
            alwaysOnTop: false,
            fullScreenAuxiliary: false
        )
        panel.orderOut(nil)
        panel.apply(alwaysOnTop: false, fullScreenAuxiliary: false)
        panel.orderVisible(alwaysOnTop: false)
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.level, .normal)

        panel.orderOut(nil)
        panel.apply(alwaysOnTop: true, fullScreenAuxiliary: false)
        panel.orderVisible(alwaysOnTop: true)
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.level, .floating)
        panel.orderOut(nil)
    }

    @MainActor
    func testPanelCanReceiveKeyboardFocusWithoutActivatingOnDisplay() {
        let panel = SessionActivityPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            alwaysOnTop: false,
            fullScreenAuxiliary: false
        )
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.becomesKeyOnlyIfNeeded)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        let previousKeyWindow = NSApp.keyWindow
        panel.orderFront(nil)
        XCTAssertTrue(NSApp.keyWindow === previousKeyWindow)
        panel.orderOut(nil)
    }

    @MainActor
    func testActivityReaderOnlyDeliversNewestGenerationOutOfOrder() throws {
        let firstStarted = expectation(description: "first activity read started")
        let newestDelivered = expectation(description: "newest activity read delivered")
        let releaseFirst = DispatchSemaphore(value: 0)
        let state = ActivityReaderState()
        let older = try SessionActivitySnapshot(emittedAt: 100)
        let newer = try SessionActivitySnapshot(emittedAt: 101)
        let reader = SessionActivityFileReader { _ in
            if state.nextCall() == 1 {
                firstStarted.fulfill()
                releaseFirst.wait()
                return .snapshot(older)
            }
            return .snapshot(newer)
        }
        let url = URL(fileURLWithPath: "/tmp/activity-v1.json")
        reader.read(url) { result in
            if case let .snapshot(snapshot) = result {
                state.append(snapshot.emittedAt)
            }
        }
        wait(for: [firstStarted], timeout: 1)
        reader.read(url) { result in
            if case let .snapshot(snapshot) = result {
                state.append(snapshot.emittedAt)
                newestDelivered.fulfill()
            }
        }
        releaseFirst.signal()
        wait(for: [newestDelivered], timeout: 1)
        XCTAssertEqual(state.values, [101])
    }

    func testRejectedSnapshotNeverPrunesAcknowledgements() throws {
        let acknowledgedID = String(repeating: "a", count: 24)
        let completed = try item(
            "a",
            state: .idle,
            event: .sessionEnd,
            terminal: true,
            eventAt: 100
        )
        let accepted = try SessionActivitySnapshot(
            emittedAt: 100,
            completed: [completed]
        )
        let rollback = try SessionActivitySnapshot(emittedAt: 99)
        let application = SessionActivityApplicationPolicy.apply(
            rollback,
            lastAccepted: accepted,
            currentlyDisplayed: accepted,
            acknowledgementHistory: [acknowledgedID],
            now: 100,
            freshnessPolicy: StateFreshnessPolicy.production
        )

        XCTAssertEqual(application.decision, .rejectRollback)
        XCTAssertEqual(application.lastAcceptedSnapshot, accepted)
        XCTAssertEqual(application.displayedSnapshot, accepted)
        XCTAssertEqual(application.acknowledgedIDs, [acknowledgedID])
    }

    func testStaleDisplayedSnapshotHidesWithoutDroppingBarrierAndDuplicateRecovers() throws {
        let freshness = try StateFreshnessPolicy(maximumAge: 10, maximumFutureSkew: 2)
        let accepted = try SessionActivitySnapshot(emittedAt: 100)
        let stale = SessionActivityApplicationPolicy.apply(
            accepted,
            lastAccepted: accepted,
            currentlyDisplayed: accepted,
            acknowledgementHistory: [],
            now: 111,
            freshnessPolicy: freshness
        )
        XCTAssertEqual(stale.decision, .rejectStale)
        XCTAssertEqual(stale.lastAcceptedSnapshot, accepted)
        XCTAssertNil(stale.displayedSnapshot)

        let future = try SessionActivitySnapshot(emittedAt: 104)
        let futureInvalid = SessionActivityApplicationPolicy.apply(
            future,
            lastAccepted: future,
            currentlyDisplayed: future,
            acknowledgementHistory: [],
            now: 100,
            freshnessPolicy: freshness
        )
        XCTAssertEqual(futureInvalid.decision, .rejectFutureSkew)
        XCTAssertEqual(futureInvalid.lastAcceptedSnapshot, future)
        XCTAssertNil(futureInvalid.displayedSnapshot)

        let recovered = SessionActivityApplicationPolicy.apply(
            accepted,
            lastAccepted: stale.lastAcceptedSnapshot,
            currentlyDisplayed: stale.displayedSnapshot,
            acknowledgementHistory: stale.acknowledgementHistory,
            now: 105,
            freshnessPolicy: freshness
        )
        XCTAssertEqual(recovered.decision, .rejectDuplicate)
        XCTAssertEqual(recovered.lastAcceptedSnapshot, accepted)
        XCTAssertEqual(recovered.displayedSnapshot, accepted)
    }

    func testAcknowledgementHistorySurvivesOmissionClearsOnRevivalAndIsBoundedLRU() throws {
        let firstID = String(repeating: "a", count: 24)
        let secondID = String(repeating: "b", count: 24)
        let accepted = try SessionActivitySnapshot(emittedAt: 100)
        let omitted = try SessionActivitySnapshot(emittedAt: 101)
        let retained = SessionActivityApplicationPolicy.apply(
            omitted,
            lastAccepted: accepted,
            currentlyDisplayed: accepted,
            acknowledgementHistory: [firstID, secondID],
            now: 101
        )
        XCTAssertEqual(retained.acknowledgementHistory, [firstID, secondID])

        let revivedItem = try item(
            "a",
            state: .running,
            event: .userPromptSubmit,
            terminal: false,
            eventAt: 102
        )
        let revived = try SessionActivitySnapshot(emittedAt: 102, active: [revivedItem])
        let cleared = SessionActivityApplicationPolicy.apply(
            revived,
            lastAccepted: omitted,
            currentlyDisplayed: omitted,
            acknowledgementHistory: retained.acknowledgementHistory,
            now: 102
        )
        XCTAssertEqual(cleared.acknowledgementHistory, [secondID])

        var history: [String] = []
        for value in 0..<140 {
            history = SessionActivityApplicationPolicy.recordingAcknowledgement(
                String(format: "%024x", value),
                in: history
            )
        }
        XCTAssertEqual(history.count, SessionActivityApplicationPolicy.maximumAcknowledgements)
        XCTAssertEqual(history.first, String(format: "%024x", 12))
        XCTAssertEqual(history.last, String(format: "%024x", 139))
        let touched = SessionActivityApplicationPolicy.recordingAcknowledgement(
            String(format: "%024x", 12),
            in: history
        )
        XCTAssertEqual(touched.last, String(format: "%024x", 12))
    }

    private func allDescendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(allDescendants)
    }
}
