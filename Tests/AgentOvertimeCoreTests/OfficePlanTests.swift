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

    /// Zoom is a magnification only: settling on the nearest sharp step (0.5, 1, 1.5), a step at a time from the
    /// menu, kept within the range, the point under the pointer kept in place. The layout is the window's at normal
    /// size whatever the zoom.
    func testZoomLikeAMap() {
        XCTAssertEqual(Zoom.steps, [0.5, 1, 1.5])
        for step in Zoom.steps {
            XCTAssertEqual((4 * step).truncatingRemainder(dividingBy: 1), 0, "room pixels whole at \(step)")
            XCTAssertEqual((6 * step).truncatingRemainder(dividingBy: 1), 0, "people pixels whole at \(step)")
        }
        XCTAssertEqual([0.5, 0.74, 0.76, 1.2, 1.3, 1.5].map(Zoom.nearest), [0.5, 0.5, 1, 1, 1.5, 1.5])
        XCTAssertEqual(Zoom.step(from: 1, by: 1), 1.5)
        XCTAssertNil(Zoom.step(from: 1.5, by: 1), "the end")
        XCTAssertEqual(Zoom.step(from: 1, by: -1), 0.5)
        XCTAssertNil(Zoom.step(from: 0.5, by: -1), "the end")
        XCTAssertEqual(Zoom.step(from: 0.8, by: 1), 1, "from between steps, the next one")
        XCTAssertEqual([0.1, 0.7, 9, .infinity, .nan].map(Zoom.clamped), [0.5, 0.7, 1.5, 1, 1])

        // A pinch from 1 to 1.5 at (100, 50) in the view, scrolled to (40, 0): that spot of the room stays there.
        let origin = Zoom.origin(CGPoint(x: 40, y: 0), keeping: CGPoint(x: 100, y: 50), from: 1, to: 1.5)
        XCTAssertEqual(origin, CGPoint(x: 110, y: 25))
        XCTAssertEqual((origin.x + 100) / 1.5, 40 + 100)
        XCTAssertEqual((origin.y + 50) / 1.5, 0 + 50)

        let normal = RoomLayout(points: Double(RoomLayout.defaultWindow.width), slots: 9)
        XCTAssertEqual(normal.columns, 2, "two islands a row in the default window, at any zoom")
        XCTAssertEqual(normal.width, RoomLayout.defaultWindow.width / RoomLayout.pointsPerPixel)
    }

    /// The saved zoom is a step in percent; the earlier 1, 2 and 3 read as the same small, normal and large; anything
    /// else (out of range, not a step, not a number, nothing) is normal, so no setting can draw the room bigger.
    func testStoredZoom() {
        XCTAssertEqual([50, 100, 150].map { Zoom.stored($0) }, [0.5, 1, 1.5])
        XCTAssertEqual([1, 2, 3].map { Zoom.stored($0) }, [0.5, 1, 1.5])
        XCTAssertEqual([0, 4, 75, 400, -100, 1_000_000].map { Zoom.stored($0) }, Array(repeating: 1, count: 6))
        XCTAssertEqual(Zoom.stored("150"), 1)
        XCTAssertEqual(Zoom.stored(nil), 1)
        XCTAssertEqual(Zoom.stored(1.5), 1)
        XCTAssertEqual(Zoom.steps.map(Zoom.percent), [50, 100, 150])
    }

    /// "1 more team below": the islands whose middle is out of the view, nearest first; pressing it scrolls to the
    /// first. Three sessions in a window a little narrower than the default (one island a row), five and nine in
    /// the default window, at two heights and scrolled down a row.
    func testIslandsOutOfSight() {
        let narrow = RoomLayout(points: 1176, slots: 3)
        XCTAssertEqual(narrow.columns, 1)
        XCTAssertEqual(narrow.outOfSight([0, 1, 2], top: 0, height: 702 / 2).below, [2])
        XCTAssertEqual(narrow.outOfSight([0, 1, 2], top: 0, height: 942 / 2).below, [])
        // Shown at half size, the same three islands all fit: the view holds twice the art.
        XCTAssertEqual(narrow.outOfSight([0, 1, 2], top: 0, height: Int(702 / (2 * 0.5))).below, [])

        let five = RoomLayout(points: 1216, slots: 5)
        XCTAssertEqual(five.outOfSight(Array(0..<5), top: 0, height: 351).below, [4])
        XCTAssertEqual(five.outOfSight(Array(0..<5), top: 0, height: 942 / 2).below, [])

        let nine = RoomLayout(points: 1216, slots: 9)
        XCTAssertEqual(nine.outOfSight(Array(0..<9), top: 0, height: 351).below, [4, 5, 6, 7, 8])
        let scrolled = nine.outOfSight(Array(0..<9), top: RoomLayout.rowPitch, height: 351)
        XCTAssertEqual(scrolled.above, [1, 0], "nearest first")
        XCTAssertEqual(scrolled.below, [6, 7, 8])
        XCTAssertEqual(nine.outOfSight([0, 3, 8], top: 0, height: 351).below, [8], "only islands in use")
        // The same nine at each step in the default window (702 points under the top bar).
        let below = Zoom.steps.map { nine.outOfSight(Array(0..<9), top: 0, height: Int(702 / (2 * $0))).below.count }
        XCTAssertEqual(below, [1, 5, 7])
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

    /// The pots along the meeting room's glass keep clear of every walk to a seat, of the islands, and of the glass
    /// door and the floor in front of it, at any window width with a right-hand column.
    func testPlantersKeepWalksIslandsAndTheDoorClear() throws {
        typealias Box = (x: Int, y: Int, width: Int, height: Int)
        func overlap(_ a: Box, _ b: Box) -> Bool {
            a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height
        }
        for points in [Double(RoomLayout.defaultWindow.width), 1440, 2000] {
            let layout = RoomLayout(points: points, slots: 9)
            let room = try XCTUnwrap(layout.meetingRoom, "\(points)")
            let pots = room.planters.map(MeetingRoom.footprint)
            XCTAssertGreaterThanOrEqual(pots.count, 4)
            var clear: [Box] = [
                (
                    room.left + MeetingRoom.doorX, MeetingRoom.front, MeetingRoom.doorWidth,
                    room.doorstep.y + 8 - MeetingRoom.front
                )
            ]
            for slot in 0..<9 {
                let o = layout.origin(of: slot)
                clear.append((o.x, o.y, RoomLayout.islandWidth, RoomLayout.islandDepth))
                for seat in 0..<Island.size {
                    let route = layout.route(slot: slot, seat: seat)
                    // Each leg of a walk, as wide as the walker's feet and shadow.
                    for (a, b) in zip(route, route.dropFirst()) {
                        clear.append((min(a.x, b.x) - 8, min(a.y, b.y) - 2, abs(a.x - b.x) + 16, abs(a.y - b.y) + 4))
                    }
                }
            }
            for pot in pots {
                for box in clear { XCTAssertFalse(overlap(pot, box), "\(points) pt: pot \(pot) blocks \(box)") }
            }
        }
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
        for slot in 0..<4 {
            for seat in 0..<Island.size {
                let route = layout.route(slot: slot, seat: seat)
                let stand = layout.standPoint(slot: slot, seat: seat)
                let o = layout.origin(of: slot)
                let name = "island \(slot) seat \(seat): \(route)"
                XCTAssertEqual(route[0].x, route[1].x, "straight down from the door")
                XCTAssertLessThan(route[0].x, RoomLayout.lane, "the lane is left of every island")
                XCTAssertEqual(route.last!.x, stand.x)
                XCTAssertEqual(route.last!.y, stand.y)
                for (p, q) in zip(route, route.dropFirst()) { XCTAssert(p.x == q.x || p.y == q.y, name) }
                XCTAssertFalse(
                    route.dropFirst().contains { $0.y == RoomLayout.wall + 2 },
                    "never along the foot of the wall, under the first row's name tags: \(name)")
                if RoomLayout.isAcross(seat) {
                    XCTAssertLessThan(stand.y, o.y + RoomLayout.farDesk, "behind the far desk")
                    let end = route[route.count - 2]
                    XCTAssertEqual(end.y, stand.y, "in from the island's end: \(name)")
                    XCTAssert(end.x < o.x || end.x > o.x + RoomLayout.islandWidth, "past the island's end: \(name)")
                    if slot >= layout.columns {
                        XCTAssert((o.y - 6...o.y).contains(route[1].y), "between the rows: \(name)")
                    } else {
                        XCTAssert(
                            route.dropFirst().allSatisfy { $0.y >= stand.y }, "the first row: from below: \(name)")
                    }
                } else {
                    XCTAssertEqual(route.count, 4, name)
                    XCTAssertGreaterThanOrEqual(route[1].y - stand.y, 20, "below the seated heads, not over them")
                    XCTAssertLessThan(route[1].y, o.y + RoomLayout.islandDepth, "inside the island's own row")
                }
            }
        }
        // The first island's end is the lane: straight down to the seat's line, not down and back up.
        XCTAssertEqual(layout.route(slot: 0, seat: 1).count, 3)
    }

    /// Talking with someone across the desks: standing at the island's end, on clear floor. The body and the
    /// speaking mark over the head stay off every name tag (a tag can be as wide as its desk, three lines tall).
    func testVisitsAcrossTheDesksStandClearOfNameTags() {
        typealias Box = (x: Int, y: Int, width: Int, height: Int)
        func overlap(_ a: Box, _ b: Box) -> Bool {
            a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height
        }
        let layout = RoomLayout(points: Double(RoomLayout.defaultWindow.width), slots: 4)
        let tags: [Box] = (0..<4).flatMap { slot in
            (0..<Island.size).map { seat -> Box in
                let o = layout.origin(of: slot)
                let x = o.x + RoomLayout.deskX(seat)
                let y = RoomLayout.isAcross(seat) ? o.y : o.y + RoomLayout.islandDepth - 23
                return (x, y, RoomLayout.deskWidth, 23)
            }
        }
        for slot in 0..<4 {
            for seat in [1, 3] {
                let spot = layout.besideSpot(slot: slot, seat: seat)
                let feet = spot.tail.last!
                let o = layout.origin(of: slot)
                XCTAssert(feet.x < o.x || feet.x > o.x + RoomLayout.islandWidth, "at the island's end")
                XCTAssertLessThan(abs(feet.y - 41 - (o.y + 24)), 12, "heads about level")
                let standing: Box = (feet.x - 16, feet.y - 53, 32, 53)
                for tag in tags { XCTAssertFalse(overlap(standing, tag), "island \(slot) seat \(seat): \(tag)") }
                let walk = layout.path(from: layout.deskSpot(slot: 0, seat: 0), to: spot)
                XCTAssertFalse(walk.contains { $0.y == RoomLayout.wall + 2 }, "not along the foot of the wall")
            }
        }
    }

    /// From any seat to beside any other: straight lines only, along aisles (never across an island), between
    /// rows by the lane or the passage beside the right-hand column, whichever is shorter. Only the step behind
    /// a far desk to or from a seat across the desks leaves the aisles.
    func testWalksBetweenSeatsKeepToTheAislesAndPassages() {
        let layout = RoomLayout(points: Double(RoomLayout.defaultWindow.width), slots: 4)
        let passage = layout.pillar! - 20
        let aisles = Set((0..<4).flatMap { slot in (0..<Island.size).map { layout.aisle(slot: slot, seat: $0) } })
        for a in 0..<16 {
            for b in 0..<16 where a != b {
                let from = layout.deskSpot(slot: a / 4, seat: a % 4)
                let to = layout.besideSpot(slot: b / 4, seat: b % 4)
                let path = layout.path(from: from, to: to)
                let end = to.tail.last ?? (to.x, to.aisle)
                XCTAssertEqual(path.first!.x, from.tail.last!.x)
                XCTAssertEqual(path.first!.y, from.tail.last!.y)
                XCTAssertEqual(path.last!.x, end.x)
                XCTAssertEqual(path.last!.y, end.y)
                for (index, (p, q)) in zip(path, path.dropFirst()).enumerated() {
                    XCTAssert(p.x == q.x || p.y == q.y, "\(a) → \(b): \(path)")
                    if p.y == q.y, index > 0 || from.tail.count < 2 {
                        XCTAssert(aisles.contains(p.y), "along an aisle: \(a) → \(b): \(path)")
                    }
                    if p.x == q.x, p.x != from.x, p.x != to.x {
                        XCTAssert([RoomLayout.laneX, passage].contains(p.x), "\(a) → \(b): \(path)")
                    }
                }
            }
        }
        let far = layout.path(from: layout.deskSpot(slot: 3, seat: 2), to: layout.besideSpot(slot: 1, seat: 3))
        XCTAssert(far.contains { $0.x == passage }, "the right-hand islands use the passage, not the lane")
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
                case nil: return nil
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
