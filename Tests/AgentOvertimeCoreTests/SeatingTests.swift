import XCTest

@testable import AgentOvertimeCore

/// Who sits where: one island a session, its teammates at the three other seats, islands that never move.
final class SeatingTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func event(
        _ kind: HookEvent.Kind, _ session: String, cwd: String = "/Users/me/shop", agent: String? = nil,
        type: String? = nil, pid: Int32? = nil
    ) -> HookEvent {
        HookEvent(kind: kind, session: session, cwd: cwd, agentID: agent, agentType: type, pid: pid)
    }

    /// Each island as "slot: seat, seat, seat, seat" ("-" empty, "+id" a teammate).
    private func plan(_ office: OfficeState) -> [String] {
        office.islands.map { island in
            let seats = island.seats.map { occupant -> String in
                if case .session(let id)? = occupant { return id }
                if case .teammate(let id)? = occupant { return "+" + id }
                return "-"
            }
            return "\(island.slot): " + seats.joined(separator: ", ")
        }
    }

    /// The "+n" on a session's tag: its teammates waiting for a seat.
    private func unseated(_ office: OfficeState, _ session: String) -> Int? {
        for case .session(let shown, let count)? in office.pods.flatMap(\.seats) where shown.id == session {
            return count
        }
        return nil
    }

    func testEachSessionGetsItsOwnIslandFromTheDoor() {
        for sessions in [0, 1, 4, 5, 8] {
            var office = OfficeState()
            for i in 0..<sessions { office.apply(event(.sessionStart, "s\(i)", cwd: "/w/p\(i)"), now: t0) }
            XCTAssertEqual(plan(office), (0..<sessions).map { "\($0): s\($0), -, -, -" }, "\(sessions) sessions")
        }
    }

    /// The room grows by sessions, not people: four sessions with three teammates each fit the default window's
    /// two rows; a fifth session, even alone, starts a third (the room scrolls).
    func testTheRoomGrowsBySessionsNotPeople() {
        let width = RoomLayout.defaultWindow.width / RoomLayout.pointsPerPixel
        func rows(_ office: OfficeState) -> Int {
            RoomLayout(width: width, slots: (office.pods.last?.slot ?? -1) + 1).rows
        }
        var four = OfficeState()
        for i in 0..<4 {
            four.apply(event(.userPromptSubmit, "s\(i)", cwd: "/w/p\(i)"), now: t0)
            for k in 0..<3 { four.apply(event(.subagentStart, "s\(i)", cwd: "/w/p\(i)", agent: "a\(i)\(k)"), now: t0) }
        }
        XCTAssertEqual(four.pods.flatMap(\.seats).compactMap { $0 }.count, 16)
        XCTAssertEqual(rows(four), 2)
        var five = OfficeState()
        for i in 0..<5 { five.apply(event(.userPromptSubmit, "s\(i)", cwd: "/w/p\(i)"), now: t0) }
        XCTAssertEqual(rows(five), 3, "five people, five sessions")
    }

    /// Teammates sit at their session's island as they come, never at another. From the fourth on they wait,
    /// counted on the session's tag and all listed in its panel; the one waiting longest takes the next free seat
    /// and walks in from the door then.
    func testTeammatesPastThreeWaitForASeat() {
        var office = OfficeState()
        office.apply(event(.userPromptSubmit, "s1"), now: t0)
        office.apply(event(.userPromptSubmit, "s2", cwd: "/w/web-app"), now: t0)
        XCTAssertEqual(unseated(office, "s1"), 0)
        for i in 1...3 { office.apply(event(.subagentStart, "s1", agent: "a\(i)"), now: t0 + Double(i)) }
        XCTAssertEqual(unseated(office, "s1"), 0, "three fit")
        for i in 4...5 { office.apply(event(.subagentStart, "s1", agent: "a\(i)"), now: t0 + Double(i)) }
        XCTAssertEqual(plan(office), ["0: s1, +a1, +a2, +a3", "1: s2, -, -, -"], "not at web-app's free seats")
        XCTAssertEqual(unseated(office, "s1"), 2)
        XCTAssertEqual(office.session("s1")?.teammates.map(\.id), ["a1", "a2", "a3", "a4", "a5"])

        office.apply(event(.subagentStop, "s1", agent: "a2"), now: t0 + 60)
        XCTAssertEqual(plan(office)[0], "0: s1, +a1, +a4, +a3", "the longest waiting, at the free seat")
        let arrivals = office.session("s1")?.teammates.map(\.arrived)
        XCTAssertEqual(arrivals, [t0 + 1, t0 + 3, t0 + 60, t0 + 5], "a4 walks in now; a5 still waits")
        XCTAssertEqual(unseated(office, "s1"), 1)
        office.apply(event(.subagentStop, "s1", agent: "a5"), now: t0 + 61)
        XCTAssertEqual(unseated(office, "s1"), 0, "one still waiting can leave too")
        office.apply(event(.subagentStop, "s1", agent: "a1"), now: t0 + 62)
        XCTAssertEqual(plan(office)[0], "0: s1, -, +a4, +a3", "nobody waits: the seat stays free, nobody moves")
        office.apply(event(.subagentStart, "s1", agent: "a6"), now: t0 + 63)
        XCTAssertEqual(plan(office)[0], "0: s1, +a6, +a4, +a3")
    }

    /// A session that ends leaves with its teammates and its island goes; the others keep their places, and a
    /// new session takes the free place nearest the door.
    func testAnEndedSessionsIslandGoesAndTheOthersStay() {
        var office = OfficeState()
        for i in 1...3 { office.apply(event(.sessionStart, "s\(i)", cwd: "/w/p\(i)"), now: t0) }
        for i in 1...4 { office.apply(event(.subagentStart, "s1", cwd: "/w/p1", agent: "a\(i)"), now: t0) }
        office.apply(event(.sessionEnd, "s1", cwd: "/w/p1"), now: t0)
        XCTAssertEqual(plan(office), ["1: s2, -, -, -", "2: s3, -, -, -"])
        XCTAssertNil(office.teammate("a1"), "its teammates went with it")
        XCTAssertNil(office.teammate("a4"), "the one waiting too")

        // A killed terminal (no SessionEnd) goes home the same way.
        office.apply(event(.userPromptSubmit, "s3", cwd: "/w/p3", pid: 42), now: t0)
        office.endSessions { $0 == 42 }
        XCTAssertEqual(plan(office), ["1: s2, -, -, -"])

        office.apply(event(.sessionStart, "n1", cwd: "/w/n1"), now: t0)
        office.apply(event(.sessionStart, "n2", cwd: "/w/n2"), now: t0)
        XCTAssertEqual(plan(office), ["0: n1, -, -, -", "1: s2, -, -, -", "2: n2, -, -, -"])
    }

    /// Two sessions in one folder: two islands, "shop" and "shop 2".
    func testTwoSessionsOfOneFolderGetTwoIslands() {
        var office = OfficeState()
        office.apply(event(.userPromptSubmit, "a"), now: t0)
        office.apply(event(.userPromptSubmit, "b"), now: t0)
        office.apply(event(.subagentStart, "b", agent: "b1"), now: t0)
        XCTAssertEqual(plan(office), ["0: a, -, -, -", "1: b, +b1, -, -"])
        XCTAssertEqual(office.desks.map(\.name), ["shop"])
        XCTAssertEqual(office.desks[0].sessions.map(\.label), ["shop", "shop 2"])
    }

    /// After a restart only the folders are remembered: nobody is seated, nobody's seat is kept.
    func testARestartRemembersOnlyTheFolders() {
        var office = OfficeState()
        office.apply(event(.sessionStart, "s1"), now: t0)
        office.apply(event(.sessionStart, "w1", cwd: "/x/web"), now: t0)
        office.apply(event(.sessionEnd, "s1"), now: t0)
        XCTAssertEqual(plan(office), ["1: w1, -, -, -"])

        var restarted = OfficeState(folders: office.folders)
        XCTAssertEqual(restarted.folders, ["/Users/me/shop", "/x/web"], "kept for Start Work")
        XCTAssertEqual(restarted.islands, [])
        restarted.apply(event(.userPromptSubmit, "w1", cwd: "/x/web"), now: t0)
        XCTAssertEqual(plan(restarted), ["0: w1, -, -, -"])
    }

    func testSeatingShowsWhoIsThere() {
        var office = OfficeState()
        office.apply(event(.userPromptSubmit, "s1"), now: t0)
        office.apply(event(.subagentStart, "s1", agent: "a1", type: "Plan"), now: t0)
        let seats = office.pods[0].seats
        guard case .session(let session, let unseated)? = seats[0], case .teammate(let mate, let of)? = seats[1]
        else { return XCTFail("\(seats)") }
        XCTAssertEqual(session.id, "s1")
        XCTAssertEqual(unseated, 0)
        XCTAssertEqual(mate.name, "Plan")
        XCTAssertEqual(of.id, "s1")
        XCTAssertNil(seats[2])
    }

    /// Past the last island sessions are still counted, with all their teammates.
    func testSessionsPastTheLastIslandAreCounted() {
        var office = OfficeState()
        for i in 0...OfficeState.maxIslands { office.apply(event(.userPromptSubmit, "s\(i)"), now: t0) }
        office.apply(event(.permissionRequest, "s\(OfficeState.maxIslands)"), now: t0)
        for i in 0..<64 { office.apply(event(.subagentStart, "s0", agent: "a\(i)"), now: t0) }
        XCTAssertEqual(office.islands.count, OfficeState.maxIslands)
        XCTAssertEqual(office.liveSessionCount, OfficeState.maxIslands + 1, "all counted")
        XCTAssertEqual(office.count(.waiting), 1, "the one without an island too")
        XCTAssertEqual(unseated(office, "s0"), 61)
        XCTAssertEqual(office.session("s0")?.teammates.count, 64)
    }
}
