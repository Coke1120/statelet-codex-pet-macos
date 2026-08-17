import AppKit
import CodexPetCore
import XCTest
@testable import Statelet

final class PetPlayerDialogueLayoutTests: XCTestCase {
    @MainActor
    func testCustomWhiteOnWhiteDialogueFallsBackToReadableText() throws {
        let appearance = try PetAppearanceConfiguration(
            dialogueBackgroundColor: "#FFFFFF",
            dialogueTextColor: "#FFFFFF",
            dialogueBackgroundOpacity: 1,
            dialogueContrastMode: .custom
        )

        let resolved = PetPlayerView.resolveDialogueAppearance(
            configuration: appearance,
            systemBackgroundColor: .black,
            systemTextColor: .white,
            reduceTransparency: false,
            increaseContrast: false
        )

        XCTAssertEqual(resolved.backgroundColor.codexPetHex, "#FFFFFF")
        XCTAssertEqual(resolved.textColor.codexPetHex, "#000000")
        XCTAssertGreaterThanOrEqual(resolved.contrastRatio, 4.5)
        XCTAssertEqual(resolved.backgroundOpacity, 1)

        let view = PetPlayerView(frame: NSRect(x: 0, y: 0, width: 320, height: 480))
        view.applyAppearance(appearance)
        let bubble = try XCTUnwrap(
            view.subviews.first { $0.accessibilityLabel() == "Statelet message" }
        )
        let label = try XCTUnwrap(bubble.subviews.compactMap { $0 as? NSTextField }.first)
        XCTAssertEqual(label.textColor?.codexPetHex, "#000000")
    }

    @MainActor
    func testAutomaticDialogueUsesReadableDynamicSystemColorsInLightAndDarkAppearances() throws {
        let appearance = try PetAppearanceConfiguration(
            dialogueBackgroundColor: "#FFFFFF",
            dialogueTextColor: "#FFFFFF",
            dialogueContrastMode: .automatic
        )

        for (background, text) in [(NSColor.white, NSColor.black), (.black, .white)] {
            let resolved = PetPlayerView.resolveDialogueAppearance(
                configuration: appearance,
                systemBackgroundColor: background,
                systemTextColor: text,
                reduceTransparency: false,
                increaseContrast: false
            )
            XCTAssertEqual(resolved.backgroundColor.codexPetHex, background.codexPetHex)
            XCTAssertEqual(resolved.textColor.codexPetHex, text.codexPetHex)
            XCTAssertGreaterThanOrEqual(resolved.contrastRatio, 4.5)
        }
    }

    @MainActor
    func testDialogueAccessibilityOptionsRaiseOpacityAndContrast() throws {
        let appearance = try PetAppearanceConfiguration(
            dialogueBackgroundColor: "#777777",
            dialogueTextColor: "#888888",
            dialogueBackgroundOpacity: 0.2,
            dialogueContrastMode: .custom
        )
        let increasedContrast = PetPlayerView.resolveDialogueAppearance(
            configuration: appearance,
            systemBackgroundColor: .white,
            systemTextColor: .black,
            reduceTransparency: false,
            increaseContrast: true
        )
        XCTAssertGreaterThanOrEqual(increasedContrast.contrastRatio, 7)
        XCTAssertGreaterThanOrEqual(increasedContrast.backgroundOpacity, 0.92)

        let reducedTransparency = PetPlayerView.resolveDialogueAppearance(
            configuration: appearance,
            systemBackgroundColor: .white,
            systemTextColor: .black,
            reduceTransparency: true,
            increaseContrast: false
        )
        XCTAssertEqual(reducedTransparency.backgroundOpacity, 1)
        XCTAssertGreaterThanOrEqual(reducedTransparency.contrastRatio, 4.5)
    }

    @MainActor
    func testDialogueBubbleAvoidsOverlaysWithTopLeftStateLabel() throws {
        try assertDialogueBubbleAvoidsOverlays(stateLabelPosition: .topLeft)
    }

    @MainActor
    func testDialogueBubbleAvoidsOverlaysWithTopRightStateLabel() throws {
        try assertDialogueBubbleAvoidsOverlays(stateLabelPosition: .topRight)
    }

    @MainActor
    func testDialogueBubbleAvoidsOverlaysWithBottomLeftStateLabel() throws {
        try assertDialogueBubbleAvoidsOverlays(stateLabelPosition: .bottomLeft)
    }

    @MainActor
    func testDialogueBubbleAvoidsOverlaysWithBottomRightStateLabel() throws {
        try assertDialogueBubbleAvoidsOverlays(stateLabelPosition: .bottomRight)
    }

    @MainActor
    private func assertDialogueBubbleAvoidsOverlays(
        stateLabelPosition: StateLabelPosition,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let view = PetPlayerView(frame: NSRect(x: 0, y: 0, width: 160, height: 240))
        let appearance = try PetAppearanceConfiguration(
            showStateLabel: true,
            stateLabelPosition: stateLabelPosition,
            stateLabelSize: .large,
            showFPS: true,
            fpsLabelSize: .large
        )
        view.applyAppearance(appearance)
        view.updateStateBadge(state: .waiting, publisherStatus: .unavailable)
        view.updateFPSBadge(
            nominalFramesPerSecond: 29.97,
            intendedFramesPerSecond: 14.985,
            reducedMotion: false
        )
        view.showDialogueMessage(
            "First long lifecycle message line\n"
                + "Second long lifecycle message line\n"
                + "Third long lifecycle message line\n"
                + "Fourth long lifecycle message line"
        )
        view.layoutSubtreeIfNeeded()

        let bubble = try XCTUnwrap(
            view.subviews.first { $0.accessibilityLabel() == "Statelet message" },
            file: file,
            line: line
        )
        let quickControls = try XCTUnwrap(
            view.subviews.first { $0.accessibilityLabel() == "Pet quick controls" },
            file: file,
            line: line
        )
        let stateBadge = try XCTUnwrap(
            view.subviews.compactMap { $0 as? PetStateBadgeView }.first,
            file: file,
            line: line
        )
        let fpsBadge = try XCTUnwrap(
            view.subviews.first { $0.accessibilityLabel() == "Video frame rate" },
            file: file,
            line: line
        )

        XCTAssertFalse(bubble.isHidden, file: file, line: line)
        XCTAssertGreaterThan(bubble.frame.width, 0, file: file, line: line)
        XCTAssertGreaterThan(bubble.frame.height, 0, file: file, line: line)
        XCTAssertTrue(view.bounds.contains(bubble.frame), file: file, line: line)
        for occupiedView in [stateBadge, quickControls, fpsBadge] where !occupiedView.isHidden {
            XCTAssertFalse(
                bubble.frame.intersects(occupiedView.frame),
                "Dialogue bubble overlaps \(occupiedView.accessibilityLabel() ?? String(describing: type(of: occupiedView))) for \(stateLabelPosition.rawValue)",
                file: file,
                line: line
            )
        }
    }
}
