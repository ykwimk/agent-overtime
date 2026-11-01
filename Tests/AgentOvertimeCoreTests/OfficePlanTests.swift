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

    /// The default window holds four islands (16 people) and the right-hand column without scrolling, inside a
    /// 1280 × 800 screen; the smallest holds one whole island.
    func testWindowSizesFitTheIslands() throws {
        let topBar = 58  // the summary bar and its divider; the capture test measures the real one
        XCTAssertLessThanOrEqual(RoomLayout.defaultWindow.width, 1280)
        XCTAssertLessThanOrEqual(RoomLayout.defaultWindow.height, 800)

        let standard = RoomLayout(points: Double(RoomLayout.defaultWindow.width), slots: 4)
        XCTAssertEqual(standard.columns, 2)
        XCTAssertEqual(standard.rows, 2)
        XCTAssertLessThanOrEqual(
            standard.contentHeight * RoomLayout.pointsPerPixel + topBar, RoomLayout.defaultWindow.height)
        let pillar = try XCTUnwrap(standard.pillar)
        for slot in 0..<4 {
            XCTAssertLessThanOrEqual(standard.origin(of: slot).x + RoomLayout.islandWidth + RoomLayout.gap, pillar)
        }
        XCTAssertEqual(pillar + RoomLayout.pillarWidth + RoomLayout.margin, standard.width)

        let smallest = RoomLayout(points: Double(RoomLayout.minWindow.width), slots: 1)
        XCTAssertEqual(smallest.columns, 1)
        XCTAssertNil(smallest.pillar, "too narrow for the meeting room column")
        XCTAssertLessThanOrEqual(smallest.origin(of: 1).x + RoomLayout.islandWidth, smallest.width - RoomLayout.margin)
        XCTAssertLessThanOrEqual(
            smallest.contentHeight * RoomLayout.pointsPerPixel + topBar, RoomLayout.minWindow.height)

        XCTAssertEqual(
            RoomLayout(points: Double(RoomLayout.defaultWindow.width), slots: 9).rows, 5,
            "more islands only add rows; the art keeps its size")
        XCTAssertEqual(RoomLayout(points: 2000, slots: 9).columns, 4)
        let narrow = RoomLayout(points: 860, slots: 4)
        XCTAssertNil(narrow.pillar)
        XCTAssertEqual(narrow.columns, 2)
    }

    /// The meeting room (and the lounge under it) lives in the right-hand column only, so the smallest window has
    /// none. Its six seats are inside its glass, its door clears the table, and the room is never cut off: the
    /// office is at least as tall as the column.
    func testMeetingRoomOnlyInTheRightHandColumn() throws {
        XCTAssertNil(RoomLayout(points: Double(RoomLayout.minWindow.width), slots: 1).meetingRoom)
        XCTAssertNil(RoomLayout(points: 860, slots: 4).meetingRoom)

        let standard = RoomLayout(points: Double(RoomLayout.defaultWindow.width), slots: 4)
        let room = try XCTUnwrap(standard.meetingRoom)
        XCTAssertEqual(room.left, standard.pillar)
        XCTAssertEqual(room.seats.count, 6)
        for seat in room.seats {
            XCTAssert((room.left + 4..<standard.width).contains(seat.x), "\(seat)")
            XCTAssert((RoomLayout.wall..<MeetingRoom.front).contains(seat.y), "\(seat)")
        }
        XCTAssertLessThanOrEqual(MeetingRoom.doorX + MeetingRoom.doorWidth, MeetingRoom.table.x)
        XCTAssertGreaterThan(room.doorstep.y, MeetingRoom.front, "outside the glass")
        XCTAssertGreaterThanOrEqual(standard.contentHeight, MeetingRoom.columnDepth)
        XCTAssertEqual(
            RoomLayout(points: Double(RoomLayout.defaultWindow.width), slots: 1).contentHeight,
            MeetingRoom.columnDepth, "one island: the lounge still shows whole")
    }

    /// Every other row moves right, so islands don't line up; side by side and row to row, a tile stays clear.
    func testIslandsStaggerAndKeepATileClear() {
        let room = RoomLayout(points: Double(RoomLayout.defaultWindow.width), slots: 4)
        XCTAssertEqual(room.origin(of: 2).x - room.origin(of: 0).x, RoomLayout.stagger)
        XCTAssertEqual(room.origin(of: 3).x - room.origin(of: 2).x, RoomLayout.islandWidth + RoomLayout.gap)
        XCTAssertGreaterThanOrEqual(RoomLayout.gap, 32)
        XCTAssertGreaterThanOrEqual(RoomLayout.stagger - RoomLayout.gap, 32, "a plant's room past the clear tile")
        XCTAssertGreaterThanOrEqual(room.origin(of: 2).y - room.origin(of: 0).y, RoomLayout.islandDepth)
        XCTAssertGreaterThanOrEqual(room.origin(of: 0).x, RoomLayout.lane, "the lane stays clear")
    }

    func testRouteGoesDownTheLaneThenAlongTheAisleToTheSeat() {
        let layout = RoomLayout(points: Double(RoomLayout.defaultWindow.width), slots: 4)
        for (slot, seat) in [(3, 2), (3, 3), (0, 1), (2, 0)] {
            let route = layout.route(slot: slot, seat: seat)
            let stand = layout.standPoint(slot: slot, seat: seat)
            let top = layout.origin(of: slot).y
            XCTAssertEqual(route.count, 4)
            XCTAssertEqual(route[0].x, route[1].x, "straight down from the door")
            XCTAssertLessThan(route[0].x, RoomLayout.lane, "the lane is left of every island")
            XCTAssertEqual(route[1].y, route[2].y, "then along the aisle")
            XCTAssertEqual(route[2].x, stand.x)
            XCTAssertEqual(route[3].x, stand.x, "then straight to the seat")
            XCTAssertEqual(route[3].y, stand.y)
            if RoomLayout.isAcross(seat) {
                XCTAssertLessThan(stand.y, top + RoomLayout.farDesk, "behind the far desk")
                XCTAssertLessThan(route[1].y, stand.y, "the aisle above the island: behind the far heads")
                if slot < layout.columns {
                    XCTAssertEqual(route[1].y, RoomLayout.wall + 2, "the first row: along the foot of the wall")
                } else {
                    XCTAssert((top - 6...top).contains(route[1].y), "between the rows")
                }
            } else {
                XCTAssertGreaterThanOrEqual(route[1].y - stand.y, 20, "below the seated heads, not over them")
                XCTAssertLessThan(route[1].y, top + RoomLayout.islandDepth, "inside the island's own row")
            }
        }
    }

    /// A teammate keeps its seat while others come and go around it.
    func testTeammatesKeepTheirSeats() {
        var office = OfficeState()
        office.apply(HookEvent(kind: .userPromptSubmit, session: "s1", cwd: "/me/shop"), now: t0)
        for id in ["a", "b", "c"] {
            office.apply(HookEvent(kind: .subagentStart, session: "s1", cwd: "/me/shop", agentID: id), now: t0)
        }
        func seats() -> [String?] {
            office.pods[0].seats.map { seat in
                switch seat {
                case .session(let s, _)?: return s.id
                case .teammate(let m, _)?: return m.id
                case .off?, nil: return nil
                }
            }
        }
        XCTAssertEqual(seats(), ["s1", "a", "b", "c"])
        office.apply(HookEvent(kind: .subagentStop, session: "s1", cwd: "/me/shop", agentID: "a"), now: t0)
        XCTAssertEqual(seats(), ["s1", nil, "b", "c"], "b and c stay put")
        office.apply(HookEvent(kind: .subagentStart, session: "s1", cwd: "/me/shop", agentID: "d"), now: t0)
        XCTAssertEqual(seats(), ["s1", "d", "b", "c"], "the next one takes the free seat")
    }
}
