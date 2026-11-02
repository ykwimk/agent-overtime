import XCTest

@testable import AgentOvertime

/// Who walks where and when: ① a session visits a newcomer's desk, ② a teammate reports before it leaves, ③ a
/// meeting gathers in the meeting room and goes back. Times are passed in, so nothing waits on the clock.
final class WalkTests: XCTestCase {
    let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let width = Int(OfficeView.defaultSize.width) / RoomLayout.pointsPerPixel
    let folder = FakeScenario.root + "/my-project"
    let session = Look.pick("my-project")
    let explore = Look.pick("Explore 1")
    let plan = Look.pick("Plan 1")

    private var office = OfficeState()
    private var stage = Stage()

    override func setUp() {
        office = OfficeState()
        stage = Stage()
        XCTAssertEqual(Set(["\(session)", "\(explore)", "\(plan)"]).count, 3, "three people told apart by looks")
    }

    private func send(
        _ kind: HookEvent.Kind, _ id: String = "s1", agent: String? = nil, type: String? = nil, asks: Bool = false,
        at time: TimeInterval, animate: Bool = true
    ) {
        office.apply(
            HookEvent(kind: kind, session: id, cwd: folder, agentID: agent, agentType: type, asksUser: asks),
            now: t0 + time)
        _ = stage.sync(office, width: width, now: t0 + time, animate: animate)
    }

    private func meet(at time: TimeInterval, animate: Bool = true) {
        office.advance(to: t0 + time)
        _ = stage.sync(office, width: width, now: t0 + time, animate: animate)
    }

    /// Where `look` is every 0.05 s from `from` to `to`: walking, standing to talk, or nil (sitting somewhere).
    private func track(_ look: Look, from: TimeInterval, to: TimeInterval) -> [(
        t: TimeInterval, at: Walker, talks: Bool
    )?] {
        stride(from: from, to: to, by: 0.05).map { time in
            let moment = stage.moment(at: t0 + time)
            if let walker = moment.standing.first(where: { $0.look == look }) { return (time, walker, true) }
            if let walker = moment.walkers.first(where: { $0.look == look }) { return (time, walker, false) }
            return nil
        }
    }

    private func talkSeconds(_ track: [(t: TimeInterval, at: Walker, talks: Bool)?]) -> Double {
        Double(track.compactMap { $0 }.filter(\.talks).count) * 0.05
    }

    /// ① The newcomer sits down; then the session walks to its desk, talks 2 s with the speaking mark beside its
    /// head, and walks back to its own desk.
    func testSessionVisitsANewcomerAndTalksTwoSeconds() {
        send(.userPromptSubmit, at: 0)
        send(.subagentStart, agent: "a1", type: "Explore", at: 1)
        let path = track(session, from: 1, to: 30)
        XCTAssertNil(path[0], "seated while the newcomer walks in")
        XCTAssertEqual(talkSeconds(path), Stage.talkTime, accuracy: 0.11)
        let firstWalk = path.firstIndex { $0 != nil }!
        let explorerSits = track(explore, from: 1, to: 30).firstIndex { $0 == nil }!
        XCTAssertGreaterThanOrEqual(firstWalk, explorerSits, "after the newcomer sat down")
        XCTAssertGreaterThanOrEqual(Double(firstWalk) * 0.05, Stage.together - 0.05)
        XCTAssertNil(path.last!, "back at its desk")
        let talking = stage.moment(at: t0 + 1 + Double(path.firstIndex { $0?.talks == true }!) * 0.05)
        XCTAssertEqual(talking.talks.count, 1)
        XCTAssertLessThan(abs(talking.talks[0].x - talking.standing[0].x), 24, "beside the head")
        XCTAssertTrue(talking.out.contains("p:s1"), "its desk keeps the laptop on")
    }

    /// ② A teammate that worked a while walks to the session's desk, talks 2 s, and leaves by the door. One done
    /// within 5 s goes straight out.
    func testTeammateReportsBeforeLeavingUnlessItWasQuick() {
        let door = RoomLayout(width: width, slots: 1).doorSpot
        for (worked, talks) in [(60.0, Stage.talkTime), (Stage.quick - 1, 0)] {
            office = OfficeState()
            stage = Stage()
            send(.userPromptSubmit, at: -100)
            send(.subagentStart, agent: "a1", type: "Explore", at: -worked)
            send(.subagentStop, agent: "a1", type: "Explore", at: 0)
            let path = track(explore, from: 0, to: 30)
            XCTAssertEqual(talkSeconds(path), talks, accuracy: 0.11, "worked \(worked) s")
            let last = path.compactMap { $0 }.last!.at
            XCTAssertLessThan(abs(last.x - door.x) + abs(last.y - door.aisle), 10, "out by the door")
            XCTAssertNil(path.last!)
        }
    }

    /// Two or more newcomers within 2 s: no visit, they may meet instead (③). Also when the second comes after
    /// the first was already planned.
    func testTwoNewcomersWithinTwoSecondsGetNoVisit() {
        send(.userPromptSubmit, at: 0)
        send(.subagentStart, agent: "a1", type: "Explore", at: 1)
        send(.subagentStart, agent: "a2", type: "Plan", at: 2.5)
        XCTAssertTrue(track(session, from: 1, to: 30).allSatisfy { $0 == nil })

        office = OfficeState()
        stage = Stage()
        send(.userPromptSubmit, at: 0)
        send(.subagentStart, agent: "a1", type: "Explore", at: 1)
        send(.subagentStart, agent: "a2", type: "Plan", at: 3.5)
        // 2.5 s apart: the first keeps its visit. The second comes while the session is on its way, so it gets
        // none (a shortcut in Stage.visit).
        XCTAssertEqual(talkSeconds(track(session, from: 1, to: 60)), Stage.talkTime, accuracy: 0.11)
    }

    /// No visit while the session waits for an answer or is in a meeting.
    func testNoVisitWhileWaitingOrMeeting() {
        send(.userPromptSubmit, at: 0)
        send(.permissionRequest, at: 0.5)
        send(.subagentStart, agent: "a1", type: "Explore", at: 1)
        XCTAssertTrue(track(session, from: 1, to: 30).allSatisfy { $0 == nil }, "waiting")

        office = OfficeState()
        stage = Stage()
        send(.userPromptSubmit, at: 0)
        send(.subagentStart, agent: "a1", type: "Explore", at: 1)
        send(.subagentStart, agent: "a2", type: "Plan", at: 1)
        meet(at: 11)
        send(.subagentStart, agent: "a3", type: "code-reviewer", at: 30)
        XCTAssertEqual(talkSeconds(track(session, from: 30, to: 60)), 0, "meeting")
    }

    /// The newcomer leaves while the session is on its way: it turns back at once, without talking.
    func testVisitTurnsBackWhenTheNewcomerLeaves() {
        send(.userPromptSubmit, at: 0)
        send(.subagentStart, agent: "a1", type: "Explore", at: 1)
        let start = 1 + Double(track(session, from: 1, to: 30).firstIndex { $0 != nil }!) * 0.05
        let home = RoomLayout(width: width, slots: 1).standPoint(slot: 0, seat: 0)
        let out = track(session, from: start, to: start + 1).compactMap { $0?.at }
        send(.subagentStop, agent: "a1", type: "Explore", at: start + 1)
        let back = track(session, from: start + 1, to: start + 10).compactMap { $0?.at }
        XCTAssertEqual(talkSeconds(track(session, from: start + 1, to: start + 10)), 0, "no talk")
        XCTAssertLessThanOrEqual(back.count, out.count + 1, "back as fast as it came")
        XCTAssertLessThanOrEqual(abs(back.last!.x - home.x) + abs(back.last!.y - home.y), 6, "to its own desk")
        for step in back {
            XCTAssert(out.contains { abs($0.x - step.x) + abs($0.y - step.y) <= 6 }, "the same way: \(step)")
        }
    }

    /// ③ They walk through the glass door to the table and sit; the session's own work sends them back to their
    /// desks. A teammate that finishes in the meeting leaves from the table, without reporting.
    func testMeetingGathersAndGoesBack() {
        send(.userPromptSubmit, at: 0)
        send(.subagentStart, agent: "a1", type: "Explore", at: 1)
        send(.subagentStart, agent: "a2", type: "Plan", at: 1)
        meet(at: 11)
        XCTAssertEqual(stage.moment(at: t0 + 11.5).walkers.count, 3)
        XCTAssert(stride(from: 11.0, to: 25, by: 0.05).contains { stage.moment(at: t0 + $0).meetingDoorOpen })
        let seated = stage.moment(at: t0 + 25)
        XCTAssertEqual(seated.walkers.count, 0)
        XCTAssertEqual(seated.room.map(\.seat).sorted(), [0, 1, 2], "the session in the middle, facing the room")
        XCTAssertEqual(seated.out, ["p:s1", "m:a1", "m:a2"], "their desks keep their laptops on")

        send(.subagentStop, agent: "a2", type: "Plan", at: 30)
        let leaving = track(plan, from: 30, to: 50)
        XCTAssertEqual(talkSeconds(leaving), 0, "no report from the meeting room")
        XCTAssertGreaterThan(leaving.compactMap { $0 }.count, 0)
        XCTAssertEqual(stage.moment(at: t0 + 31).room.count, 2, "the others stay")

        send(.preToolUse, at: 60)
        XCTAssertEqual(stage.moment(at: t0 + 60.5).walkers.count, 2, "back to their desks")
        let after = stage.moment(at: t0 + 80)
        XCTAssertEqual(after.room.count, 0)
        XCTAssertEqual(after.out, [])
    }

    /// No more than six walk at once: the seventh is just there.
    func testAtMostSixWalkAtOnce() {
        send(.userPromptSubmit, at: 0)
        for k in 0..<3 { send(.subagentStart, agent: "a\(k)", type: "Explore", at: 1) }
        meet(at: 11)
        send(.sessionStart, "s2", at: 11)
        send(.subagentStart, "s2", agent: "b0", type: "Plan", at: 11)
        send(.subagentStart, "s2", agent: "b1", type: "Plan", at: 11)
        let counts = stride(from: 11.0, to: 30, by: 0.1).map { stage.moment(at: t0 + $0).walkers.count }
        XCTAssertEqual(counts.max(), Stage.maxWalkers, "s1 and its three to the meeting, s2 and b0 in")
        XCTAssertFalse(stage.moment(at: t0 + 11.5).away.contains("m:b1"), "the seventh is at its desk at once")
    }

    /// Reduce Motion: nobody walks. ① shows the speaking mark at the session's own seat for 2 s, and a meeting
    /// sits down in the meeting room at once.
    func testReduceMotionTalksInPlaceAndMeetsWithoutWalking() {
        send(.userPromptSubmit, at: 0, animate: false)
        send(.subagentStart, agent: "a1", type: "Explore", at: 1, animate: false)
        let marks = stride(from: 1.0, to: 10, by: 0.05).map { stage.moment(at: t0 + $0) }
        XCTAssertTrue(marks.allSatisfy { $0.walkers.isEmpty && $0.standing.isEmpty })
        XCTAssertEqual(Double(marks.filter { !$0.talks.isEmpty }.count) * 0.05, Stage.talkTime, accuracy: 0.11)
        XCTAssertEqual(stage.nextChange(after: t0 + 1), t0 + 1 + Stage.together, "the picture wakes up for it")

        send(.subagentStart, agent: "a2", type: "Plan", at: 20, animate: false)
        meet(at: 30, animate: false)
        let moment = stage.moment(at: t0 + 30)
        XCTAssertEqual(moment.walkers.count, 0)
        XCTAssertEqual(moment.room.count, 3)
    }

    private func message(from agent: String?, to: String, at time: TimeInterval, animate: Bool = true) {
        office.apply(
            HookEvent(
                kind: .preToolUse, session: "s1", cwd: folder, agentID: agent, toolKind: .team, sendsMessage: true,
                recipient: to), now: t0 + time)
        _ = stage.sync(office, width: width, now: t0 + time, animate: animate)
    }

    /// A message between two teammates at their desks: the sender walks over, talks 2 s and walks back; the
    /// recipient stays seated. At the meeting table only the mark shows, nobody walks.
    func testATeammateWalksOverToTalk() {
        send(.userPromptSubmit, at: 0)
        send(.subagentStart, agent: "a1", type: "Explore", at: 1)
        send(.subagentStart, agent: "a2", type: "Plan", at: 1)
        message(from: "a1", to: "Plan", at: 9)
        let walk = track(explore, from: 9, to: 30)
        XCTAssertNotNil(walk[1], "on the way")
        XCTAssertEqual(talkSeconds(walk), Stage.talkTime, accuracy: 0.11)
        XCTAssertNil(walk.last!, "back at its desk")
        XCTAssertTrue(track(plan, from: 9, to: 30).allSatisfy { $0 == nil }, "the recipient stays seated")

        meet(at: 40)
        message(from: "a2", to: "a1", at: 60)
        let inMeeting = stride(from: 60.0, to: 64, by: 0.05).map { stage.moment(at: t0 + $0) }
        XCTAssertTrue(inMeeting.allSatisfy { $0.walkers.isEmpty })
        XCTAssertEqual(Double(inMeeting.filter { !$0.talks.isEmpty }.count) * 0.05, Stage.talkTime, accuracy: 0.11)
    }
}
