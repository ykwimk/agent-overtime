import XCTest

@testable import AgentOvertimeCore

final class OfficePlanTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let seoul: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }()

    private func at(_ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        seoul.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: hour, minute: minute, second: second))!
    }

    func testDayAndNightFollowThisMacsClock() {
        XCTAssertEqual(Daylight.at(at(18, 59, 59), calendar: seoul), .day)
        XCTAssertEqual(Daylight.at(at(19, 0), calendar: seoul), .night)
        XCTAssertEqual(Daylight.at(at(6, 59, 59), calendar: seoul), .night)
        XCTAssertEqual(Daylight.at(at(7, 0), calendar: seoul), .day)
        XCTAssertEqual(Daylight.at(at(0, 0), calendar: seoul), .night)
        XCTAssertEqual(Daylight.at(at(12, 0), calendar: seoul), .day)
    }

    func testDarknessFadesForThreeSecondsAtTheChange() {
        XCTAssertEqual(Daylight.darkness(at: at(18, 59, 59), calendar: seoul), 0)
        XCTAssertEqual(Daylight.darkness(at: at(19, 0, 0), calendar: seoul), 0)
        XCTAssertEqual(Daylight.darkness(at: at(19, 0, 0) + 1.5, calendar: seoul), 0.5, accuracy: 0.001)
        XCTAssertEqual(Daylight.darkness(at: at(19, 0, 3), calendar: seoul), 1)
        XCTAssertEqual(Daylight.darkness(at: at(6, 59, 59), calendar: seoul), 1)
        XCTAssertEqual(Daylight.darkness(at: at(7, 0, 0) + 1.5, calendar: seoul), 0.5, accuracy: 0.001)
        XCTAssertEqual(Daylight.darkness(at: at(7, 0, 3), calendar: seoul), 0)
    }

    /// The default window holds four pods without scrolling; the smallest holds one whole pod.
    func testWindowSizesFitThePods() {
        let topBar = 64  // the summary bar is about 57 pt; the capture test measures the real one
        let standard = RoomLayout(points: Double(RoomLayout.defaultWindow.width), podCount: 4)
        XCTAssertEqual(standard.columns, 2)
        XCTAssertEqual(standard.rows, 2)
        XCTAssertLessThanOrEqual(
            standard.contentHeight * RoomLayout.pointsPerPixel + topBar, RoomLayout.defaultWindow.height)
        let right = standard.origin(of: 3).x + RoomLayout.podWidth
        XCTAssertLessThanOrEqual(right, standard.width - RoomLayout.margin)

        let smallest = RoomLayout(points: Double(RoomLayout.minWindow.width), podCount: 1)
        XCTAssertEqual(smallest.columns, 1)
        XCTAssertLessThanOrEqual(smallest.origin(of: 0).x + RoomLayout.podWidth, smallest.width)
        XCTAssertLessThanOrEqual(
            smallest.contentHeight * RoomLayout.pointsPerPixel + topBar, RoomLayout.minWindow.height)

        let many = RoomLayout(points: Double(RoomLayout.defaultWindow.width), podCount: 9)
        XCTAssertEqual(many.rows, 5, "more pods only add rows; the art keeps its size")
        XCTAssertEqual(RoomLayout(points: 2000, podCount: 9).columns, 3)
    }

    func testRouteGoesDownTheLaneThenAlongTheRowBehindTheChairs() {
        let layout = RoomLayout(points: 1080, podCount: 4)
        let route = layout.route(pod: 3, desk: 2)
        let stand = layout.standPoint(pod: 3, desk: 2)
        XCTAssertEqual(route.count, 4)
        XCTAssertEqual(route[0].x, route[1].x, "straight down from the door")
        XCTAssertLessThan(route[0].x, RoomLayout.lane, "the lane is left of every pod")
        XCTAssertEqual(route[1].y, route[2].y, "then along the row")
        XCTAssertGreaterThanOrEqual(route[1].y - stand.y, 24, "below the seated heads, not over them")
        XCTAssertLessThan(route[1].y, layout.origin(of: 3).y + RoomLayout.podDepth, "inside the pod's own row")
        XCTAssertEqual(route[2].x, stand.x)
        XCTAssertEqual(route[3].x, stand.x, "then up to the chair")
        XCTAssertEqual(route[3].y, stand.y)
    }

    private func event(
        _ kind: HookEvent.Kind, _ session: String, cwd: String = "/Users/me/my-project", agent: String? = nil,
        type: String? = nil
    ) -> HookEvent {
        HookEvent(kind: kind, session: session, cwd: cwd, agentID: agent, agentType: type)
    }

    /// A folder's second session gets its own pod, and teammates sit only with the session that called them.
    func testEachSessionHasItsOwnPodAndTeammates() {
        var office = OfficeState()
        office.apply(event(.userPromptSubmit, "s1"), now: t0)
        office.apply(event(.userPromptSubmit, "s2"), now: t0)
        office.apply(event(.subagentStart, "s2", agent: "a1", type: "Explore"), now: t0)
        office.apply(event(.sessionStart, "s3", cwd: "/Users/me/web-app"), now: t0)
        office.apply(event(.sessionEnd, "s3", cwd: "/Users/me/web-app"), now: t0)
        var plan = SeatPlan()
        let pods = plan.pods(for: office)
        XCTAssertEqual(pods.map(\.name), ["my-project", "my-project 2", "web-app"])
        XCTAssertEqual(pods[0].mates.compactMap { $0?.name }, [])
        XCTAssertEqual(pods[1].mates.compactMap { $0?.name }, ["Explore"])
        XCTAssertTrue(pods[2].isOff)
        XCTAssertEqual(pods[2].occupied, [false, false, false, false], "no lamp at an empty desk")
        XCTAssertEqual(pods[1].occupied, [true, true, false, false], "lamps only where someone is")
    }

    func testTeammatesKeepTheirDesksAndExtrasCount() {
        var office = OfficeState()
        var plan = SeatPlan()
        office.apply(event(.userPromptSubmit, "s1"), now: t0)
        for id in ["a", "b", "c", "d", "e"] { office.apply(event(.subagentStart, "s1", agent: id), now: t0) }
        var pod = plan.pods(for: office)[0]
        XCTAssertEqual(pod.mates.map { $0?.id }, ["a", "b", "c"])
        XCTAssertEqual(pod.extra, 2)

        office.apply(event(.subagentStop, "s1", agent: "a"), now: t0)
        pod = plan.pods(for: office)[0]
        XCTAssertEqual(pod.mates.map { $0?.id }, ["d", "b", "c"], "b and c stay put; the next one takes the free desk")
        XCTAssertEqual(pod.extra, 1)

        office.apply(event(.subagentStop, "s1", agent: "b"), now: t0)
        office.apply(event(.subagentStop, "s1", agent: "e"), now: t0)
        pod = plan.pods(for: office)[0]
        XCTAssertEqual(pod.mates.map { $0?.id }, ["d", nil, "c"])
        XCTAssertEqual(pod.extra, 0)
    }

    /// The main desk says "working", but the summary counts a waiting teammate: the name tag says so too.
    func testTeammateWaitingIsShownOnTheMainDesk() {
        var office = OfficeState()
        var plan = SeatPlan()
        office.apply(event(.userPromptSubmit, "s1"), now: t0)
        office.apply(event(.subagentStart, "s1", agent: "a1", type: "Plan"), now: t0)
        XCTAssertFalse(plan.pods(for: office)[0].teammateWaiting)
        office.apply(event(.permissionRequest, "s1", agent: "a1", type: "Plan"), now: t0)
        XCTAssertTrue(plan.pods(for: office)[0].teammateWaiting)
        XCTAssertEqual(office.count(.waiting), 1)
        office.apply(event(.permissionRequest, "s1"), now: t0)
        XCTAssertFalse(plan.pods(for: office)[0].teammateWaiting, "the session waits itself: its own label says so")
    }
}
