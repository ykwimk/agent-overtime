import XCTest

@testable import AgentOvertimeCore

final class OfficeStateTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let shop = "/Users/me/shop"

    private func event(
        _ kind: HookEvent.Kind, _ session: String = "s1", cwd: String? = nil, agent: String? = nil,
        type: String? = nil, notification: String? = nil, asks: Bool = false, pid: Int32? = nil
    ) -> HookEvent {
        HookEvent(
            kind: kind, session: session, cwd: cwd ?? shop, agentID: agent, agentType: type,
            notification: notification, asksUser: asks, pid: pid)
    }

    func testStateTable() {
        let cases: [(HookEvent, WorkState)] = [
            (event(.sessionStart), .resting),
            (event(.userPromptSubmit), .working),
            (event(.preToolUse), .working),
            (event(.preToolUse, asks: true), .waiting),
            (event(.permissionRequest), .waiting),
            (event(.notification, notification: "permission_prompt"), .waiting),
            (event(.notification, notification: "elicitation_dialog"), .waiting),
            (event(.notification, notification: "agent_needs_input"), .waiting),
            (event(.notification, notification: "idle_prompt"), .resting),
            (event(.stop), .resting),
        ]
        for (e, expected) in cases {
            var office = OfficeState()
            office.apply(e, now: t0)
            XCTAssertEqual(office.desks.first?.sessions.first?.state, expected, "\(e.kind) \(e.notification ?? "")")
        }
    }

    func testFirstEventSeatsSessionStartedBeforeTheApp() {
        var office = OfficeState()
        XCTAssertTrue(office.apply(event(.preToolUse, pid: 99), now: t0), "a new desk must be saved")
        XCTAssertEqual(office.desks.map(\.name), ["shop"])
        XCTAssertEqual(office.desks[0].sessions.first?.pid, 99)
        XCTAssertFalse(office.apply(event(.stop), now: t0), "same desk, nothing to save")
    }

    /// idle_prompt while a question or permission prompt is open keeps the wait (and its minutes); after Stop it
    /// still means resting. A teammate follows the same rule.
    func testIdlePromptDoesNotEndAWait() {
        let cases: [(HookEvent, WorkState)] = [
            (event(.preToolUse, asks: true), .waiting),
            (event(.notification, notification: "permission_prompt"), .waiting),
            (event(.stop), .resting),
            (event(.preToolUse, agent: "a1", asks: true), .waiting),
        ]
        for (first, expected) in cases {
            var office = OfficeState()
            office.apply(first, now: t0)
            office.apply(event(.notification, agent: first.agentID, notification: "idle_prompt"), now: t0 + 60)
            let session = office.desks[0].sessions[0]
            XCTAssertEqual(session.shown.state, expected, "\(first.kind) \(first.agentID ?? "")")
            if expected == .waiting { XCTAssertEqual(session.shown.since, t0, "minutes count from the first wait") }
        }
        var office = OfficeState()
        office.apply(event(.preToolUse, asks: true), now: t0)
        office.apply(event(.notification, notification: "idle_prompt"), now: t0 + 60)
        office.apply(event(.preToolUse), now: t0 + 90)
        XCTAssertEqual(office.desks[0].sessions[0].state, .working, "the next step ends the wait")
    }

    func testArrivedOnlyForThoseWhoStartWhileTheAppListens() {
        var office = OfficeState()
        office.apply(event(.sessionStart, "new"), now: t0)
        office.apply(event(.preToolUse, "old"), now: t0)
        office.apply(event(.subagentStart, "new", agent: "a1"), now: t0 + 1)
        office.apply(event(.preToolUse, "new", agent: "a2"), now: t0 + 1)
        XCTAssertEqual(office.desks[0].sessions.map(\.arrived), [t0, nil])
        XCTAssertEqual(office.desks[0].sessions[0].teammates.map(\.arrived), [t0 + 1, nil])
    }

    func testSecondSessionSitsAtTheSameDesk() {
        var office = OfficeState()
        office.apply(event(.sessionStart, "s1"), now: t0)
        office.apply(event(.sessionStart, "s2"), now: t0)
        XCTAssertEqual(office.desks.count, 1)
        XCTAssertEqual(office.desks[0].sessions.map(\.id), ["s1", "s2"])
    }

    /// Same names get numbers in arrival order. Nobody is renumbered when someone leaves; a newcomer takes the
    /// smallest free number. Folders elsewhere with the same name count as the same name.
    func testSameNamesGetNumbersInArrivalOrder() {
        var office = OfficeState()
        office.apply(event(.sessionStart, "s1"), now: t0)
        office.apply(event(.sessionStart, "s2"), now: t0)
        office.apply(event(.sessionStart, "s3", cwd: "/elsewhere/shop"), now: t0)
        func names() -> [String] { office.desks.flatMap(\.sessions).map(\.name) }
        XCTAssertEqual(names(), ["shop", "shop 2", "shop 3"])
        office.apply(event(.sessionEnd, "s1"), now: t0)
        XCTAssertEqual(names(), ["shop 2", "shop 3"], "the others keep their numbers")
        office.apply(event(.sessionStart, "s4"), now: t0)
        office.apply(event(.sessionStart, "s5"), now: t0)
        XCTAssertEqual(names(), ["shop 2", "shop", "shop 4", "shop 3"], "smallest free number first")

        for (id, type) in [("a1", "Plan"), ("a2", "Plan"), ("a3", nil), ("a4", nil)] {
            office.apply(event(.subagentStart, "s2", agent: id, type: type), now: t0)
        }
        office.apply(event(.subagentStart, "s4", agent: "a5", type: "Plan"), now: t0)
        func mates() -> [String] { office.desks.flatMap(\.teammates).map { "\($0.name ?? "helper") \($0.number)" } }
        XCTAssertEqual(mates(), ["Plan 1", "Plan 2", "helper 1", "helper 2", "Plan 3"], "across sessions too")
        office.apply(event(.subagentStop, "s2", agent: "a1"), now: t0)
        office.apply(event(.subagentStart, "s2", agent: "a6", type: "Plan"), now: t0)
        XCTAssertEqual(mates(), ["Plan 2", "helper 1", "helper 2", "Plan 1", "Plan 3"])
    }

    func testWaitingSinceCountsFromTheFirstPrompt() {
        var office = OfficeState()
        office.apply(event(.permissionRequest), now: t0)
        office.apply(event(.notification, notification: "permission_prompt"), now: t0 + 6)
        XCTAssertEqual(office.desks[0].sessions[0].since, t0)
        office.apply(event(.preToolUse), now: t0 + 60)
        XCTAssertEqual(office.desks[0].sessions[0].since, t0 + 60)
    }

    func testTeammatesComeAndGo() {
        var office = OfficeState()
        office.apply(event(.userPromptSubmit), now: t0)
        office.apply(event(.subagentStart, agent: "a1", type: "Explore"), now: t0)
        office.apply(event(.subagentStart, agent: "a2"), now: t0)
        XCTAssertEqual(office.desks[0].teammates.map(\.name), ["Explore", nil])
        XCTAssertEqual(office.desks[0].teammates.map(\.state), [.working, .working])

        office.apply(event(.permissionRequest, agent: "a1", type: "Explore"), now: t0 + 1)
        XCTAssertEqual(office.desks[0].teammates[0].state, .waiting)
        XCTAssertEqual(office.desks[0].sessions[0].state, .working, "the session's own pose does not change")

        office.apply(event(.preToolUse, agent: "a2"), now: t0 + 2)
        XCTAssertEqual(office.desks[0].teammates[1].state, .working)

        office.apply(event(.subagentStop, agent: "a1", type: "Explore"), now: t0 + 3)
        XCTAssertEqual(office.desks[0].teammates.map(\.id), ["a2"])
    }

    /// Summary, menu rows and the menu bar "! n" all read `count`/`shown`, so this is the rule for all three.
    func testWaitingTeammateCountsTheSessionAsWaiting() {
        var office = OfficeState()
        office.apply(event(.userPromptSubmit), now: t0)
        office.apply(event(.subagentStart, agent: "a1", type: "Plan"), now: t0)
        XCTAssertEqual(office.count(.waiting), 0)
        XCTAssertEqual(office.count(.working), 1)

        office.apply(event(.permissionRequest, agent: "a1", type: "Plan"), now: t0 + 30)
        XCTAssertEqual(office.count(.waiting), 1)
        XCTAssertEqual(office.count(.working), 0)
        XCTAssertEqual(office.desks[0].sessions[0].shown.since, t0 + 30, "minutes count from the teammate's prompt")

        office.apply(event(.preToolUse, agent: "a1", type: "Plan"), now: t0 + 60)
        XCTAssertEqual(office.count(.waiting), 0, "answered: back to work, nothing stays stuck")
        XCTAssertEqual(office.count(.working), 1)

        office.apply(event(.permissionRequest), now: t0 + 90)
        office.apply(event(.permissionRequest, agent: "a1", type: "Plan"), now: t0 + 100)
        XCTAssertEqual(office.count(.waiting), 1, "one session, counted once")
        XCTAssertEqual(office.desks[0].sessions[0].shown.since, t0 + 90, "the earliest wait")
    }

    func testEndedSessionLeavesAnOffDutyDesk() {
        var office = OfficeState()
        office.apply(event(.sessionStart), now: t0)
        office.apply(event(.subagentStart, agent: "a1"), now: t0)
        office.apply(event(.sessionEnd), now: t0)
        XCTAssertEqual(office.desks.count, 1)
        XCTAssertTrue(office.desks[0].isOff)
        XCTAssertTrue(office.desks[0].teammates.isEmpty)

        // /clear sends SessionEnd then SessionStart with a new id: same desk again.
        office.apply(event(.sessionStart, "s2"), now: t0)
        XCTAssertEqual(office.desks.count, 1)
        XCTAssertFalse(office.desks[0].isOff)
    }

    func testStrayStopForUnknownSubagentSeatsNobody() {
        var office = OfficeState()
        office.apply(event(.subagentStop, agent: "ghost"), now: t0)
        XCTAssertTrue(office.desks.isEmpty)
    }

    /// The order a real session sends (PostToolUse left out, the plugin does not ask for it): a question, then a
    /// SubagentStop after Stop for an agent id never seen before, with no SubagentStart.
    func testRealSessionOrderWithQuestionAndLateUnknownSubagentStops() {
        var office = OfficeState()
        office.apply(event(.sessionStart), now: t0)
        office.apply(event(.userPromptSubmit), now: t0 + 1)
        office.apply(event(.preToolUse, asks: true), now: t0 + 2)
        office.apply(event(.permissionRequest), now: t0 + 3)
        office.apply(event(.notification, notification: "permission_prompt"), now: t0 + 9)
        XCTAssertEqual(office.desks[0].sessions[0].shown.state, .waiting, "asking")
        XCTAssertEqual(office.desks[0].sessions[0].shown.since, t0 + 2, "minutes count from the question")

        office.apply(event(.stop), now: t0 + 30)
        XCTAssertEqual(office.desks[0].sessions[0].state, .resting)
        office.apply(event(.subagentStop, agent: "unseen-1"), now: t0 + 33)
        XCTAssertTrue(office.desks[0].teammates.isEmpty, "an unknown SubagentStop seats nobody")
        XCTAssertEqual(office.desks[0].sessions[0].shown.state, .resting)
        XCTAssertEqual(office.desks[0].sessions[0].since, t0 + 30, "and leaves the session alone")

        office.apply(event(.userPromptSubmit), now: t0 + 40)
        office.apply(event(.preToolUse), now: t0 + 41)
        office.apply(event(.stop), now: t0 + 50)
        office.apply(event(.subagentStop, agent: "unseen-2"), now: t0 + 51)
        XCTAssertTrue(office.desks[0].teammates.isEmpty)
        XCTAssertEqual(office.desks[0].sessions[0].state, .resting)
        XCTAssertEqual(office.desks[0].sessions[0].since, t0 + 50)

        office.apply(event(.sessionEnd), now: t0 + 60)
        XCTAssertTrue(office.desks[0].isOff, "off duty")
    }

    func testDeadProcessEndsTheSession() {
        var office = OfficeState()
        office.apply(event(.sessionStart, "s1", pid: 10), now: t0)
        office.apply(event(.sessionStart, "s2", cwd: "/x/other", pid: 20), now: t0)
        office.apply(event(.sessionStart, "s3", cwd: "/x/third"), now: t0)
        office.endSessions { $0 == 10 }
        XCTAssertEqual(office.desks.map(\.isOff), [true, false, false], "no pid means no guess")
    }

    /// Recent folders (for Start Work) can be cleared; a folder with a session running stays.
    func testRecentFoldersCanBeCleared() {
        var office = OfficeState(folders: ["/a/one", "/a/two"])
        XCTAssertEqual(office.desks.map(\.isOff), [true, true])
        office.apply(event(.sessionStart, cwd: "/a/two"), now: t0)
        office.forgetIdleFolders()
        XCTAssertEqual(office.folders, ["/a/two"])
        XCTAssertEqual(office.islands.count, 1, "seats are untouched")
    }

    /// A new folder sits where it is seen first, not below every remembered desk.
    func testNewFolderTakesTheOffDutyDeskNearestTheDoor() {
        var office = OfficeState(folders: ["/a/one", "/a/two", "/a/three"])
        office.apply(event(.sessionStart, "s1", cwd: "/a/two"), now: t0)
        XCTAssertFalse(office.apply(event(.sessionStart, "s2", cwd: "/a/two"), now: t0), "a remembered folder")

        XCTAssertTrue(office.apply(event(.sessionStart, "n1", cwd: "/new/one"), now: t0))
        XCTAssertEqual(office.folders, ["/new/one", "/a/two", "/a/three"])
        office.apply(event(.sessionStart, "n2", cwd: "/new/two"), now: t0)
        XCTAssertEqual(office.folders, ["/new/one", "/a/two", "/new/two"], "/a/two keeps its place")
        office.apply(event(.sessionStart, "n3", cwd: "/new/three"), now: t0)
        XCTAssertEqual(office.folders, ["/new/one", "/a/two", "/new/two", "/new/three"], "no off-duty desk left")
    }

    func testCaps() {
        var office = OfficeState(folders: (0..<OfficeState.maxDesks).map { "/old/\($0)" })
        office.apply(event(.sessionStart, cwd: "/new/one"), now: t0)
        XCTAssertEqual(office.desks.count, OfficeState.maxDesks)
        XCTAssertEqual(office.folders.first, "/new/one", "takes the off-duty desk nearest the door")
        XCTAssertEqual(office.folders.last, "/old/23")

        var full = OfficeState()
        for i in 0..<OfficeState.maxDesks { full.apply(event(.sessionStart, "s\(i)", cwd: "/busy/\(i)"), now: t0) }
        full.apply(event(.sessionStart, "late", cwd: "/busy/late"), now: t0)
        XCTAssertFalse(full.folders.contains("/busy/late"), "never evicts a desk with someone at it")

        var crowded = OfficeState()
        for i in 0..<100 { crowded.apply(event(.sessionStart, "s\(i)"), now: t0) }
        XCTAssertEqual(crowded.liveSessionCount, OfficeState.maxSessions)
        for i in 0..<100 { crowded.apply(event(.subagentStart, "s0", agent: "a\(i)"), now: t0) }
        XCTAssertEqual(crowded.desks[0].sessions[0].teammates.count, OfficeState.maxTeammates)
    }

    /// v0.1 seated 4 sessions per folder and 8 teammates; the 5th session and the 9th teammate went uncounted.
    func testFifthSessionAndNinthTeammateAreCounted() {
        var office = OfficeState()
        for i in 1...5 { office.apply(event(.userPromptSubmit, "s\(i)"), now: t0) }
        office.apply(event(.permissionRequest, "s5"), now: t0)
        XCTAssertEqual(office.liveSessionCount, 5)
        XCTAssertEqual(office.count(.waiting), 1, "the 5th session's wait reaches the summary and menu bar")

        for i in 1...9 { office.apply(event(.subagentStart, "s1", agent: "a\(i)"), now: t0) }
        office.apply(event(.permissionRequest, "s1", agent: "a9"), now: t0)
        XCTAssertEqual(office.count(.waiting), 2, "so does the 9th teammate's")
        XCTAssertEqual(office.desks[0].sessions.map(\.name), ["shop", "shop 2", "shop 3", "shop 4", "shop 5"])
        XCTAssertEqual(office.islands.flatMap(\.seats).compactMap { $0 }.count, 14, "everyone has a seat")
    }

    func testCounts() {
        var office = OfficeState()
        for e in FakeScenario.events { office.apply(e, now: t0) }
        XCTAssertEqual(office.desks.map(\.name), ["my-project", "web-app", "blog", "prototype"])
        XCTAssertEqual(office.count(.working), 1)
        XCTAssertEqual(office.count(.waiting), 2, "my-project works, but its Plan teammate waits")
        XCTAssertEqual(office.count(.resting), 1)
        XCTAssertEqual(office.liveSessionCount, 4)
        XCTAssertEqual(office.desks[0].sessions[0].state, .working)
        XCTAssertEqual(office.desks[0].teammates.map(\.state), [.working, .waiting, .resting])
        XCTAssertEqual(office.desks[2].teammates.map(\.name), [nil])
        XCTAssertTrue(office.desks[3].isOff)
        XCTAssertTrue(office.hasLiveSession(in: FakeScenario.root + "/blog"))
        XCTAssertFalse(office.hasLiveSession(in: FakeScenario.root + "/prototype"))
        XCTAssertTrue(office.hasLiveSession(in: FakeScenario.root), "a start script may open sessions in subfolders")
        XCTAssertFalse(office.hasLiveSession(in: FakeScenario.root + "/web"), "a name prefix is not a subfolder")
    }

    /// The latest kind of tool stays in memory for the side panel until the turn ends, and goes with the session or
    /// teammate. It changes nothing drawn, so the office stays equal.
    func testTheLatestToolKindIsKeptInMemoryOnly() {
        var office = OfficeState()
        office.apply(event(.userPromptSubmit), now: t0)
        let before = office
        office.apply(HookEvent(kind: .preToolUse, session: "s1", cwd: shop, toolKind: .edit), now: t0 + 1)
        office.apply(HookEvent(kind: .preToolUse, session: "s1", cwd: shop, toolKind: .command), now: t0 + 2)
        XCTAssertEqual(office.toolKind(session: "s1"), .command)
        XCTAssertEqual(office, before, "the same picture")
        office.apply(
            HookEvent(kind: .preToolUse, session: "s1", cwd: shop, agentID: "a1", toolKind: .read), now: t0 + 3)
        XCTAssertEqual(office.toolKind(teammate: "a1"), .read)
        office.apply(event(.permissionRequest), now: t0 + 4)
        XCTAssertEqual(office.toolKind(session: "s1"), .command, "a wait keeps it")
        office.apply(event(.stop), now: t0 + 5)
        XCTAssertNil(office.toolKind(session: "s1"), "the turn ended")
        office.apply(event(.subagentStop, agent: "a1"), now: t0 + 6)
        XCTAssertNil(office.toolKind(teammate: "a1"))
        office.apply(HookEvent(kind: .preToolUse, session: "s1", cwd: shop, toolKind: .web), now: t0 + 7)
        office.apply(event(.sessionEnd), now: t0 + 8)
        XCTAssertNil(office.toolKind(session: "s1"))
    }
}
