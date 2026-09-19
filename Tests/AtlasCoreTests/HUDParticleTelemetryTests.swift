import XCTest
@testable import AtlasCore

final class HUDParticleTelemetryTests: XCTestCase {

    override func setUp() {
        super.setUp()
        SovereignPresenceStateManager.shared.resetForTesting()
    }

    override func tearDown() {
        SovereignPresenceStateManager.shared.resetForTesting()
        super.tearDown()
    }

    func testHUDPayloadSerializesSovereignStateAndAudioEnergy() throws {
        let feed = HUDFeed.shared
        SovereignPresenceStateManager.shared.setRestingState(.processing)

        feed.tick(
            events: [],
            overdueTasks: 0,
            calendarAuthorized: true,
            remindersAuthorized: true,
            projects: [],
            notes: [],
            pendingApprovals: 2,
            services: [],
            loaded: true
        )

        guard let payload = feed.payload else {
            XCTFail("HUDFeed payload must not be nil")
            return
        }

        XCTAssertEqual(payload.sovereignState, "processing")
        XCTAssertEqual(payload.workspace.pendingApprovals, 2)
        XCTAssertGreaterThanOrEqual(payload.audioEnergy.rms, 0.0)
        XCTAssertLessThanOrEqual(payload.audioEnergy.rms, 1.0)

        let json = payload.jsonString()
        XCTAssertTrue(json.contains("\"sovereignState\":\"processing\""))
        XCTAssertTrue(json.contains("\"audioEnergy\":"))
        XCTAssertTrue(json.contains("\"pendingApprovals\":2"))
    }

    func testHUDPayloadReflectsStateTransitions() throws {
        let feed = HUDFeed.shared

        SovereignPresenceStateManager.shared.setRestingState(.idle)
        feed.tick(events: [], overdueTasks: 0, calendarAuthorized: true, remindersAuthorized: true, projects: [], notes: [], pendingApprovals: 0, services: [], loaded: true)
        XCTAssertEqual(feed.payload?.sovereignState, "idle")

        SovereignPresenceStateManager.shared.setRestingState(.speaking)
        feed.tick(events: [], overdueTasks: 0, calendarAuthorized: true, remindersAuthorized: true, projects: [], notes: [], pendingApprovals: 0, services: [], loaded: true)
        XCTAssertEqual(feed.payload?.sovereignState, "speaking")
    }
}
