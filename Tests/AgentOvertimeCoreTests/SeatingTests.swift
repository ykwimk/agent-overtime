import XCTest

@testable import AgentOvertimeCore

/// Who sits where: only people at work, four to an island, islands that never move.
final class SeatingTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func event(
        _ kind: HookEvent.Kind, _ session: String, cwd: String = "/Users/me/shop", agent: String? = nil,
        type: String? = nil, pid: Int32? = nil
    ) -> HookEvent {
        HookEvent(kind: kind, session: session, cwd: cwd, agentID: agent, agentType: type, pid: pid)
    }

    /// Each island as "slot: seat, seat, seat, seat" ("-" empty, "~name" went home, "+id" a teammate).
    private func plan(_ office: OfficeState) -> [String] {
        office.islands.map { island in
            let seats = island.seats.map { occupant -> String in
                switch occupant {
                case .session(let id)?: return id
                case .teammate(let id)?: return "+" + id
                case .off(_, let name)?: return "~" + name
                case nil: return "-"
                }
            }
            return "\(island.slot): " + seats.joined(separator: ", ")
        }
    }

    func testSessionsArrivingOneByOneFillIslandsFromTheDoor() {
        for (people, islands) in [(0, 0), (1, 1), (4, 1), (5, 2), (16, 4), (20, 5)] {
            var office = OfficeState()
            for i in 0..<people { office.apply(event(.sessionStart, "s\(i)", cwd: "/w/p\(i)"), now: t0) }
            XCTAssertEqual(office.islands.map(\.slot), Array(0..<islands), "\(people) people")
            XCTAssertEqual(office.islands.flatMap(\.seats).compactMap { $0 }.count, people)
            XCTAssertEqual(office.islands.dropLast().filter { $0.seats.contains(nil) }, [], "full before the next")
        }
        var office = OfficeState()
        for i in 0..<5 { office.apply(event(.sessionStart, "s\(i)", cwd: "/w/p\(i)"), now: t0) }
        XCTAssertEqual(plan(office), ["0: s0, s1, s2, s3", "1: s4, -, -, -"])
    }

    /// A teammate sits at its session's island; when that is full, at the nearest island with room (taking a
    /// seat someone went home from); when none has room, at a new island.
    func testTeammatesOverflowToTheNearestIslandThenANewOne() {
        var office = OfficeState()
        for i in 1...9 { office.apply(event(.sessionStart, "s\(i)"), now: t0) }
        office.apply(event(.sessionEnd, "s5"), now: t0)
        XCTAssertEqual(plan(office), ["0: s1, s2, s3, s4", "1: ~shop 5, s6, s7, s8", "2: s9, -, -, -"])

        office.apply(event(.subagentStart, "s4", agent: "a1", type: "Explore"), now: t0)
        XCTAssertEqual(plan(office)[1], "1: +a1, s6, s7, s8", "island 0 is full: the next island, the seat s5 left")
        office.apply(event(.subagentStart, "s4", agent: "a2"), now: t0)
        office.apply(event(.subagentStart, "s4", agent: "a3"), now: t0)
        office.apply(event(.subagentStart, "s4", agent: "a4"), now: t0)
        XCTAssertEqual(plan(office)[2], "2: s9, +a2, +a3, +a4")
        office.apply(event(.subagentStart, "s4", agent: "a5"), now: t0)
        XCTAssertEqual(plan(office).last, "3: +a5, -, -, -", "no room anywhere: a new island")

        // s9's own teammate: its island is full. Islands 1 and 3 are as near as each other (0 is farther), and
        // the one nearer the door wins.
        office.apply(event(.sessionEnd, "s7"), now: t0)
        office.apply(event(.sessionEnd, "s1"), now: t0)
        office.apply(event(.subagentStart, "s9", agent: "b1"), now: t0)
        XCTAssertEqual(plan(office)[1], "1: +a1, s6, +b1, s8")
    }

    /// An island where nobody works goes; the others stay in their places, and a new island takes the free
    /// place nearest the door.
    func testEmptyIslandGoesAndTheOthersStay() {
        var office = OfficeState()
        for i in 1...9 { office.apply(event(.sessionStart, "s\(i)", cwd: "/w/p\(i)"), now: t0) }
        for i in 1...4 { office.apply(event(.sessionEnd, "s\(i)", cwd: "/w/p\(i)"), now: t0) }
        XCTAssertEqual(office.islands.map(\.slot), [1, 2], "island 0 went, with the names of those who left")
        XCTAssertEqual(plan(office)[0], "1: s5, s6, s7, s8")

        office.apply(event(.sessionStart, "n1", cwd: "/w/n1"), now: t0)
        XCTAssertEqual(plan(office)[1], "2: s9, n1, -, -", "the nearest island with room, not a new one")
        for i in 2...3 { office.apply(event(.sessionStart, "n\(i)", cwd: "/w/n\(i)"), now: t0) }
        office.apply(event(.sessionStart, "n4", cwd: "/w/n4"), now: t0)
        XCTAssertEqual(office.islands.map(\.slot), [0, 1, 2], "a new island by the door")
        XCTAssertEqual(plan(office)[0], "0: n4, -, -, -")

        office.apply(event(.subagentStart, "n4", cwd: "/w/n4", agent: "a1"), now: t0)
        office.apply(event(.sessionEnd, "n4", cwd: "/w/n4"), now: t0)
        XCTAssertEqual(office.islands.map(\.slot), [1, 2], "its teammates leave with the session")
    }

    /// Someone who went home leaves a faded name while others work at the island. A newcomer takes that seat when
    /// it needs one, its own folder's first; an empty seat before a seat of another folder.
    func testWentHomeSeatIsTakenOverOwnFolderFirst() {
        var office = OfficeState()
        office.apply(event(.sessionStart, "s1"), now: t0)
        office.apply(event(.sessionStart, "s2"), now: t0)
        office.apply(event(.sessionStart, "w1", cwd: "/x/web"), now: t0)
        office.apply(event(.sessionEnd, "s1"), now: t0)
        office.apply(event(.sessionEnd, "s2"), now: t0)
        XCTAssertEqual(plan(office), ["0: ~shop, ~shop 2, w1, -"])
        XCTAssertEqual(office.seating[0][0], .off(name: "shop", folder: "/Users/me/shop"))

        office.apply(event(.sessionStart, "w2", cwd: "/x/web"), now: t0)
        XCTAssertEqual(plan(office), ["0: ~shop, ~shop 2, w1, w2"], "an empty seat first")
        office.apply(event(.sessionStart, "s3"), now: t0)
        XCTAssertEqual(plan(office), ["0: s3, ~shop 2, w1, w2"], "its own folder's seat")
        office.apply(event(.sessionStart, "w3", cwd: "/x/web"), now: t0)
        XCTAssertEqual(plan(office), ["0: s3, w3, w1, w2"], "another folder's, when nothing else is free")

        // A killed terminal (no SessionEnd) goes home the same way.
        office.apply(event(.userPromptSubmit, "w1", cwd: "/x/web", pid: 42), now: t0)
        office.endSessions { $0 == 42 }
        XCTAssertEqual(plan(office), ["0: s3, w3, ~web, w2"])

        for id in ["s3", "w3", "w2"] { office.apply(event(.sessionEnd, id), now: t0) }
        XCTAssertEqual(office.islands, [], "nobody at work: the island goes, faded names too")
    }

    /// After a restart only the folders are remembered: nobody is seated and no faded names are drawn.
    func testRestartDrawsNoWentHomeSeats() {
        var office = OfficeState()
        office.apply(event(.sessionStart, "s1"), now: t0)
        office.apply(event(.sessionStart, "w1", cwd: "/x/web"), now: t0)
        office.apply(event(.sessionEnd, "s1"), now: t0)
        XCTAssertEqual(plan(office), ["0: ~shop, w1, -, -"])

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
        guard case .session(let session, let unseated)? = office.seating[0][0],
            case .teammate(let mate, let of)? = office.seating[0][1]
        else { return XCTFail("\(office.seating)") }
        XCTAssertEqual(session.id, "s1")
        XCTAssertEqual(unseated, 0)
        XCTAssertEqual(mate.name, "Plan")
        XCTAssertEqual(of.id, "s1")
        XCTAssertNil(office.seating[0][2])
    }

    /// Past the last island people are still counted, and the session's tag counts its unseated teammates.
    func testUnseatedTeammatesAreCounted() {
        var office = OfficeState()
        office.apply(event(.userPromptSubmit, "s1"), now: t0)
        let seats = OfficeState.maxIslands * Island.size
        for i in 0..<OfficeState.maxTeammates { office.apply(event(.subagentStart, "s1", agent: "a\(i)"), now: t0) }
        for i in 2...60 {
            office.apply(event(.userPromptSubmit, "s\(i)"), now: t0)
            for k in 0..<2 { office.apply(event(.subagentStart, "s\(i)", agent: "b\(i)-\(k)"), now: t0) }
        }
        XCTAssertEqual(office.islands.count, OfficeState.maxIslands)
        XCTAssertEqual(office.islands.flatMap(\.seats).compactMap { $0 }.count, seats)
        guard case .session(_, let unseated)? = office.seating[0][0] else { return XCTFail() }
        XCTAssertEqual(unseated, 0, "s1's 64 teammates came first and all found seats")
        let last = office.islands.last!.seats.compactMap { $0 }
        XCTAssertEqual(last.count, Island.size)
        XCTAssertEqual(office.liveSessionCount, 60, "all counted")
    }
}
