import Foundation
import XCTest
@testable import CodexPetCore

final class CompanionGeometryTests: XCTestCase {
    func testGreatestOverlapWinsInsteadOfFirstIntersectingDisplay() {
        let frames = [CGRect(x: -1000, y: 0, width: 1000, height: 800),
                      CGRect(x: 0, y: -100, width: 1400, height: 900)]
        let pet = CGRect(x: -20, y: 100, width: 240, height: 300)
        let shown = CompanionFramePolicy.beside(pet, size: CGSize(width: 440, height: 640), visibleFrames: frames)
        XCTAssertTrue(frames[1].contains(shown))
        XCTAssertEqual(shown.minX, pet.maxX + 12)
    }

    func testNegativeCoordinatesSmallScreensAndMissingDisplayFitEntirePanel() {
        let visible = CGRect(x: -900, y: -600, width: 360, height: 280)
        let frame = CGRect(x: 1500, y: 1200, width: 900, height: 800)
        let fitted = CompanionFramePolicy.fitting(frame, visibleFrames: [visible])
        XCTAssertEqual(fitted, visible)
        let mini = CompanionFramePolicy.beside(frame, size: CGSize(width: 440, height: 56), visibleFrames: [visible])
        XCTAssertTrue(visible.contains(mini))
        XCTAssertEqual(mini.height, 56)
        XCTAssertEqual(CompanionFramePolicy.fitting(frame, visibleFrames: []), frame)
    }

    func testVisiblePositionIsRetainedAndRemovedDisplayUsesNearestScreen() {
        let screens = [CGRect(x: -1000, y: 0, width: 1000, height: 800),
                       CGRect(x: 0, y: 0, width: 1200, height: 800)]
        let existing = CGRect(x: -800, y: 40, width: 440, height: 640)
        XCTAssertEqual(CompanionFramePolicy.fitting(existing, visibleFrames: screens), existing)
        let displaced = CGRect(x: -1400, y: -200, width: 440, height: 640)
        XCTAssertTrue(screens[0].contains(CompanionFramePolicy.fitting(displaced, visibleFrames: screens)))
        XCTAssertTrue(screens[1].contains(CompanionFramePolicy.fitting(existing, visibleFrames: [screens[1]])))
    }
}
