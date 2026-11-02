import XCTest

@testable import AgentOvertimeCore

/// A session that hands work to two or more teammates and then goes quiet meets with them; its own work ends the
/// meeting, waiting for the user does not.
final class MeetingTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let delay = OfficeState.meetingDelay

    private func event(
        _ kind: HookEvent.Kind, _ session: String = "s1", cwd: String = "/Users/me/my-project", agent: String? = nil,
        notification: String? = nil, asks: Bool = false
    ) -> HookEvent {
        HookEvent(
            kind: kind, session: session, cwd: cwd, agentID: agent, agentType: agent.map { _ in "Explore" },
            notification: notification, asksUser: asks)
    }

    /// A session at work that calls `teammates` teammates at `at`.
    private func office(teammates: Int, session: String = "s1", at: Date? = nil) -> OfficeState {
        var office = OfficeState()
        let at = at ?? t0
        office.apply(event(.userPromptSubmit, session), now: at - 1)
        for i in 0..<teammates { office.apply(event(.subagentStart, session, agent: "\(session)-\(i)"), now: at) }
        return office
    }

    private func meets(_ office: OfficeState, _ session: String = "s1") -> Bool {
        office.desks.flatMap(\.sessions).first { $0.id == session }!.meets
    }

    func testTwoTeammatesAndTenQuietSecondsMakeAMeeting() {
        var office = office(teammates: 2)
        XCTAssertEqual(office.nextMeeting, t0 + delay)
        office.advance(to: t0 + delay - 0.1)
        XCTAssertFalse(meets(office), "9.9 s")
        XCTAssertNil(office.meeting)
        office.advance(to: t0 + delay)
        XCTAssertTrue(meets(office), "10 s")
        XCTAssertEqual(office.meeting?.session.id, "s1")
        XCTAssertEqual(office.meeting?.members.map(\.id), ["s1-0", "s1-1"])
        XCTAssertNil(office.nextMeeting)
    }

    func testOneTeammateIsNoMeeting() {
        var office = office(teammates: 1)
        XCTAssertNil(office.nextMeeting)
        office.advance(to: t0 + 60)
        XCTAssertFalse(meets(office))
    }

    /// Each newcomer starts the count again, until the meeting has started.
    func testTheCountStartsFromTheLastNewcomer() {
        var office = office(teammates: 2)
        office.apply(event(.subagentStart, agent: "s1-2"), now: t0 + 5)
        XCTAssertEqual(office.nextMeeting, t0 + 5 + delay)
        office.advance(to: t0 + delay)
        XCTAssertFalse(meets(office))
        office.advance(to: t0 + 5 + delay)
        XCTAssertTrue(meets(office))
        office.apply(event(.subagentStart, agent: "s1-3"), now: t0 + 20)
        XCTAssertTrue(meets(office), "a newcomer joins the meeting")
    }

    /// The session's own prompt, tool or stop ends it; so does anything of its own before the 10 s are up.
    func testOwnWorkEndsTheMeeting() {
        for work in [event(.userPromptSubmit), event(.preToolUse), event(.stop)] {
            var office = office(teammates: 2)
            office.advance(to: t0 + delay)
            office.apply(work, now: t0 + 12)
            XCTAssertFalse(meets(office), "\(work.kind)")
            XCTAssertNil(office.nextMeeting, "\(work.kind)")

            var early = self.office(teammates: 2)
            early.apply(work, now: t0 + 3)
            early.advance(to: t0 + 60)
            XCTAssertFalse(meets(early), "\(work.kind) before 10 s")
        }
        // A teammate's own work is not the session's.
        var office = office(teammates: 2)
        office.apply(event(.preToolUse, agent: "s1-0"), now: t0 + 3)
        office.apply(event(.stop, agent: "s1-1"), now: t0 + 4)
        office.advance(to: t0 + delay)
        XCTAssertTrue(meets(office))
    }

    /// Waiting for the user's answer, the session's or a teammate's, keeps the meeting.
    func testWaitingForAnAnswerKeepsTheMeeting() {
        let waits = [
            event(.permissionRequest), event(.notification, notification: "permission_prompt"),
            event(.notification, notification: "idle_prompt"), event(.preToolUse, asks: true),
            event(.permissionRequest, agent: "s1-0"), event(.preToolUse, agent: "s1-1", asks: true),
        ]
        for wait in waits {
            var office = office(teammates: 2)
            office.advance(to: t0 + delay)
            office.apply(wait, now: t0 + 12)
            XCTAssertTrue(meets(office), "\(wait.kind) \(wait.agentID ?? "")")

            var before = self.office(teammates: 2)
            before.apply(wait, now: t0 + 3)
            before.advance(to: t0 + delay)
            XCTAssertTrue(meets(before), "\(wait.kind) \(wait.agentID ?? "") before 10 s")
        }
    }

    /// One teammate left keeps a meeting going, none ends it. Before the meeting, one is not enough.
    func testTheLastTeammateOrTheSessionEndingEndsIt() {
        var office = office(teammates: 2)
        office.advance(to: t0 + delay)
        office.apply(event(.subagentStop, agent: "s1-0"), now: t0 + 12)
        XCTAssertTrue(meets(office), "one teammate is still out")
        XCTAssertEqual(office.meeting?.members.map(\.id), ["s1-1"])
        office.apply(event(.subagentStop, agent: "s1-1"), now: t0 + 13)
        XCTAssertFalse(meets(office))
        XCTAssertNil(office.meeting)

        var early = self.office(teammates: 2)
        early.apply(event(.subagentStop, agent: "s1-0"), now: t0 + 3)
        XCTAssertNil(early.nextMeeting)
        early.advance(to: t0 + 60)
        XCTAssertFalse(meets(early))

        var ended = self.office(teammates: 3)
        ended.advance(to: t0 + delay)
        ended.apply(event(.sessionEnd), now: t0 + 12)
        XCTAssertNil(ended.meeting)
    }

    /// Calling one more teammate (or messaging one) is handing out work, not the session's own: the meeting goes on
    /// and the newcomer joins it. Any other tool ends it.
    func testCallingOneMoreTeammateKeepsTheMeeting() {
        var office = office(teammates: 2)
        office.advance(to: t0 + delay)
        for kind: HookEvent.ToolKind in [.team, .team] {
            office.apply(
                HookEvent(kind: .preToolUse, session: "s1", cwd: "/Users/me/my-project", toolKind: kind), now: t0 + 20)
        }
        office.apply(event(.subagentStart, agent: "s1-2"), now: t0 + 20.1)
        XCTAssertTrue(meets(office))
        XCTAssertEqual(office.meeting?.members.count, 3, "the newcomer joins")
        office.apply(
            HookEvent(kind: .preToolUse, session: "s1", cwd: "/Users/me/my-project", toolKind: .read), now: t0 + 30)
        XCTAssertFalse(meets(office), "reading files is the session's own work")
    }

    /// One meeting room: the session that met first has it. Another session in a meeting stays at its desk.
    func testTheFirstSessionToMeetHasTheRoom() {
        var office = office(teammates: 2, session: "s1", at: t0 + 3)
        for i in 0..<2 {
            office.apply(event(.subagentStart, "s2", cwd: "/Users/me/web-app", agent: "s2-\(i)"), now: t0)
        }
        office.advance(to: t0 + delay)
        XCTAssertEqual(office.meeting?.session.id, "s2")
        office.advance(to: t0 + 3 + delay)
        XCTAssertTrue(meets(office, "s1"), "meets too, at its desk")
        XCTAssertEqual(office.meeting?.session.id, "s2")
        office.apply(event(.userPromptSubmit, "s2", cwd: "/Users/me/web-app"), now: t0 + 20)
        XCTAssertEqual(office.meeting?.session.id, "s1", "the room is free again")
    }

    /// Six seats: the session and five teammates. Anyone more stays at their desk, counted as "+n".
    func testPastSixSeatsTheRestStayOut() {
        var office = office(teammates: 7)
        office.advance(to: t0 + delay)
        XCTAssertEqual(office.meeting?.members.map(\.id), (0..<5).map { "s1-\($0)" })
        XCTAssertEqual(office.meeting?.more, 2)
    }
}
