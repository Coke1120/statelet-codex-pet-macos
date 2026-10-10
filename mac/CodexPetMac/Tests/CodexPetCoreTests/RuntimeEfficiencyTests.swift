import XCTest
@testable import CodexPetCore

final class RuntimeEfficiencyTests: XCTestCase {
    func testReduceMotionComposesWithDisplaySuspensionAndPreservesPlaybackIntent() {
        var policy = PlaybackSuspensionPolicy()
        XCTAssertEqual(policy.replacePlayback(rate: 0.75), .resume(rate: 0.75))
        XCTAssertEqual(policy.setSuspended(true, for: .reduceMotion), .pause)
        XCTAssertFalse(policy.canStartReadinessDeadline)

        XCTAssertEqual(policy.setSuspended(true, for: .windowOccluded), .pause)
        XCTAssertEqual(policy.setSuspended(true, for: .screenAsleep), .pause)
        XCTAssertEqual(policy.setSuspended(false, for: .windowOccluded), .none)
        XCTAssertEqual(policy.setSuspended(false, for: .screenAsleep), .none)
        XCTAssertEqual(policy.reasons, [.reduceMotion])
        XCTAssertFalse(policy.canStartReadinessDeadline)
        XCTAssertEqual(policy.setSuspended(false, for: .reduceMotion), .resume(rate: 0.75))

        XCTAssertEqual(policy.setSuspended(true, for: .reduceMotion), .pause)
        XCTAssertEqual(policy.replacePlayback(rate: 1.25), .pause)
        XCTAssertEqual(policy.setSuspended(true, for: .windowOccluded), .pause)
        XCTAssertEqual(policy.setSuspended(false, for: .reduceMotion), .none)
        XCTAssertFalse(policy.canStartReadinessDeadline)
        XCTAssertEqual(policy.setSuspended(false, for: .windowOccluded), .resume(rate: 1.25))
        XCTAssertTrue(policy.canStartReadinessDeadline)
    }
}
