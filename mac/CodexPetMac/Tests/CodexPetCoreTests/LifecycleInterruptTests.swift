import Foundation
import XCTest
@testable import CodexPetCore

final class LifecycleInterruptTests: XCTestCase {
    func testCurrentStateDecodesInterruptedTurnAsIdleLifecycle() throws {
        let data = #"{"version":1,"schema_version":1,"state":"idle","active_sessions":0,"emitted_at":100,"publication_revision":7,"latest_event":"Interrupt","latest_event_at":99}"#.data(using: .utf8)!
        let state = try JSONDecoder.codexPet.decode(CurrentState.self, from: data)

        XCTAssertEqual(state.state, .idle)
        XCTAssertEqual(state.activeSessions, 0)
        XCTAssertEqual(state.latestEvent, "Interrupt")
        XCTAssertEqual(state.latestEventAt, 99)
        XCTAssertEqual(CurrentStateHookEvent(rawValue: "Interrupt"), .interrupt)
        XCTAssertEqual(SessionActivityCategory.inferred(from: .interrupt), .codex)
    }

    func testInterruptedTurnCannotBeProjectedAsCompletedOrIdleActiveActivity() throws {
        let identifier = String(repeating: "a", count: 24)
        for (group, terminal) in [("completed", true), ("active", false)] {
            let data = """
            {"version":1,"emitted_at":100,"\(group)":[{
              "id":"\(identifier)","state":"idle","event":"Interrupt",
              "event_at":99,"terminal":\(terminal)
            }]}
            """.data(using: .utf8)!
            XCTAssertThrowsError(
                try JSONDecoder.codexPet.decode(SessionActivitySnapshot.self, from: data),
                group
            )
        }

        let projection = #"{"version":1,"emitted_at":100,"active":[],"completed":[]}"#.data(using: .utf8)!
        let snapshot = try JSONDecoder.codexPet.decode(SessionActivitySnapshot.self, from: projection)
        XCTAssertTrue(snapshot.active.isEmpty)
        XCTAssertTrue(snapshot.completed.isEmpty)
    }
}
