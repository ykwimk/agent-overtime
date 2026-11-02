import XCTest

@testable import AgentOvertimeCore

/// Teammates called by teammates: a newcomer goes with the first teammate call still open in its session (a
/// SubagentStart doesn't say who called), and sits at its caller's island.
final class TeamTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let folder = "/Users/me/my-project"

    private func call(
        _ office: inout OfficeState, from agent: String? = nil, tool: HookEvent.ToolKind = .team, message: Bool = false
    ) {
        office.apply(
            HookEvent(
                kind: .preToolUse, session: "s1", cwd: folder, agentID: agent, toolKind: tool, sendsMessage: message),
            now: t0)
    }

    private func start(_ office: inout OfficeState, _ id: String, _ type: String = "Explore") {
        office.apply(HookEvent(kind: .subagentStart, session: "s1", cwd: folder, agentID: id, agentType: type), now: t0)
    }

    private func callers(_ office: OfficeState) -> [String: String] {
        Dictionary(uniqueKeysWithValues: office.desks[0].sessions[0].teammates.map { ($0.id, $0.calledBy ?? "-") })
    }

    func testANewcomerGoesWithTheFirstOpenCall() {
        var office = OfficeState()
        office.apply(HookEvent(kind: .userPromptSubmit, session: "s1", cwd: folder), now: t0)
        call(&office)
        start(&office, "a1")
        XCTAssertEqual(callers(office), ["a1": "-"], "the session called")

        // a1 calls two in a row, then the session one: they come in that order.
        call(&office, from: "a1")
        call(&office, from: "a1")
        call(&office)
        start(&office, "b1", "Plan")
        start(&office, "b2", "Plan")
        start(&office, "c1")
        XCTAssertEqual(callers(office), ["a1": "-", "b1": "a1", "b2": "a1", "c1": "-"])

        // No call open: the session. A SendMessage or another tool is no call.
        call(&office, from: "a1", message: true)
        call(&office, from: "a1", tool: .read)
        start(&office, "d1")
        XCTAssertEqual(callers(office)["d1"], "-")

        // Meetings count the session's own teammates only.
        XCTAssertEqual(office.desks[0].sessions[0].direct.map(\.id), ["a1", "c1", "d1"])

        // a1 leaves: whoever it called now counts as the session's.
        office.apply(HookEvent(kind: .subagentStop, session: "s1", cwd: folder, agentID: "a1"), now: t0)
        XCTAssertEqual(callers(office), ["b1": "-", "b2": "-", "c1": "-", "d1": "-"])
    }

    private func work(
        _ office: inout OfficeState, _ agent: String? = nil, _ kind: HookEvent.ToolKind = .read, at: TimeInterval = 0
    ) {
        office.apply(
            HookEvent(kind: .preToolUse, session: "s1", cwd: folder, agentID: agent, toolKind: kind), now: t0 + at)
    }

    private func wearing(_ office: OfficeState) -> [String] {
        office.desks[0].sessions[0].teammates.filter(\.headphones).map(\.id)
    }

    /// The caller goes on with work of its own after a teammate came: that teammate works on its own and puts on
    /// headphones, until it leaves. Calling or messaging teammates is no such work. Headphones don't meet.
    func testHeadphonesWhenTheCallerWorksOn() {
        var office = OfficeState()
        office.apply(HookEvent(kind: .userPromptSubmit, session: "s1", cwd: folder), now: t0)
        start(&office, "a1")
        start(&office, "a2")
        work(&office, nil, .team, at: 1)
        office.apply(
            HookEvent(kind: .preToolUse, session: "s1", cwd: folder, toolKind: .team, sendsMessage: true), now: t0 + 1)
        XCTAssertEqual(wearing(office), [], "calling and messaging teammates")
        work(&office, nil, .edit, at: 2)
        XCTAssertEqual(wearing(office), ["a1", "a2"])
        XCTAssertEqual(office.desks[0].sessions[0].direct, [], "nobody to meet with")
        office.advance(to: t0 + 60)
        XCTAssertNil(office.meeting)

        // A newcomer after that is waited on again; two of them meet.
        start(&office, "a3")
        start(&office, "a4")
        office.advance(to: t0 + 60 + OfficeState.meetingDelay)
        XCTAssertEqual(office.meeting?.members.map(\.id), ["a3", "a4"], "those with headphones stay at their desks")
        // The session works again: the meeting ends and they put headphones on too, never both at once.
        work(&office, nil, .command, at: 80)
        XCTAssertNil(office.meeting)
        XCTAssertEqual(wearing(office), ["a1", "a2", "a3", "a4"])
    }

    /// A teammate's own teammates: their caller's work puts headphones on them, not the session's.
    func testATeammatesWorkPutsHeadphonesOnItsOwnTeammates() {
        var office = OfficeState()
        start(&office, "a1")
        call(&office, from: "a1")
        start(&office, "b1", "Plan")
        work(&office, nil, .edit)
        XCTAssertEqual(wearing(office), ["a1"], "the session's work: its own teammate")
        work(&office, "a1", .read)
        XCTAssertEqual(wearing(office), ["a1", "b1"])
    }

    /// A caller that has already left when its newcomer comes: the session.
    func testACallerGoneBeforeItsNewcomerComesLeavesItToTheSession() {
        var office = OfficeState()
        start(&office, "a1")
        call(&office, from: "a1")
        office.apply(HookEvent(kind: .subagentStop, session: "s1", cwd: folder, agentID: "a1"), now: t0)
        start(&office, "b1")
        XCTAssertEqual(callers(office), ["b1": "-"])
    }

    /// A teammate's newcomer sits at that teammate's island (the nearest with room when it is full).
    func testANewcomerSitsAtItsCallersIsland() {
        var office = OfficeState()
        for i in 0..<4 {
            office.apply(HookEvent(kind: .userPromptSubmit, session: "o\(i)", cwd: "/w/p\(i)"), now: t0)
        }
        // s1 sits at the second island; its teammate a1 there too.
        office.apply(HookEvent(kind: .userPromptSubmit, session: "s1", cwd: folder), now: t0)
        start(&office, "a1")
        let island = { (id: String) in office.islands.first { $0.seats.contains(.teammate(id)) }?.slot }
        XCTAssertEqual(island("a1"), 1)
        call(&office, from: "a1")
        start(&office, "b1", "Plan")
        XCTAssertEqual(island("b1"), 1, "next to its caller")
    }
}
