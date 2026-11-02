import SwiftUI
import XCTest

@testable import AgentOvertime

/// Runs inside the app (hosted tests). Sends the fake scenario through the app's real socket, checks the live
/// office, then saves each screen as PNG in captures/ — drawn by the app itself, no screen recording permission.
@MainActor
final class CaptureTests: XCTestCase {
    private let out = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("captures")

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }

    func testFakeEventsReachTheOfficeThroughTheSocket() throws {
        let model = try XCTUnwrap(AppModel.live, "the host app's model")
        for event in FakeScenario.events {
            XCTAssertTrue(EventClient.send(event.wireLine(), to: model.socketPath), "\(event.kind)")
            usleep(20_000)
        }
        let deadline = Date() + 5
        while model.office.folders.count < 4 || model.office.liveSessionCount < 4, Date() < deadline {
            RunLoop.main.run(until: Date() + 0.05)
        }
        XCTAssertEqual(model.office.desks.map(\.name), ["my-project", "web-app", "blog"])
        XCTAssertEqual(model.office.count(.working), 1)
        XCTAssertEqual(model.office.count(.waiting), 2)
        XCTAssertEqual(model.office.count(.resting), 1)
        XCTAssertEqual(model.office.folders.last, FakeScenario.root + "/prototype", "came and went, remembered")
        XCTAssertEqual(model.office.desks[0].teammates.map(\.state), [.working, .waiting, .resting])
        XCTAssertTrue(model.everConnected)

        let later = Date() + 200  // so "Waiting · 3 min" shows
        try capture("menu", MenuContent(fixedNow: later).environmentObject(model))
        try capture("menubar-icon", MenuBarLabel(model: model).padding(6))
        try capture(
            "start-register",
            StartSheet(
                sheet: .register, initial: StartCommand(folder: FakeScenario.root + "/my-project", run: ["claude"])
            )
            .environmentObject(model))
    }

    // MARK: the office

    /// Today at this hour on this Mac's clock.
    private func today(_ hour: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date())!
    }

    /// The fake scenario as of `now`, with the blog's helper `walked` seconds into its walk in from the door
    /// (unless `still`).
    private func scenario(at now: Date, still: Bool = false, walked: TimeInterval = 0.9) -> (AppModel, Stage) {
        let model = makeModel(connected: true)
        let stage = Stage()
        let width = Int(OfficeView.defaultSize.width) / RoomLayout.pointsPerPixel
        let events = FakeScenario.events
        let helper = events.firstIndex { $0.kind == .subagentStart && $0.agentID == "demo-h" }!
        for event in events[..<helper] { model.receive(event, at: now - 200) }
        _ = stage.sync(model.office, width: width, now: now - 2, animate: !still)
        for event in events[helper...] { model.receive(event, at: now - walked) }
        _ = stage.sync(model.office, width: width, now: now - walked, animate: !still)
        return (model, stage)
    }

    /// `sessions` sessions, each followed by its teammates (names from the list in turn), in a mix of states, all
    /// seated before `now`.
    private func team(sessions: Int, teammates: Int, at now: Date) -> AppModel {
        team(Array(repeating: teammates, count: sessions), at: now)
    }

    /// One session for each count, with that many teammates.
    private func team(_ teammates: [Int], at now: Date) -> AppModel {
        let model = makeModel(connected: true)
        let names = ["Explore", "Plan", "code-reviewer", nil, "general-purpose"]
        let folders = ["my-project", "web-app", "blog", "api", "docs", "design"]
        for (i, count) in teammates.enumerated() {
            let folder = FakeScenario.root + "/" + folders[i % folders.count]
            let session = "team-\(i)"
            model.receive(HookEvent(kind: .userPromptSubmit, session: session, cwd: folder), at: now - 300)
            if i % 3 == 1 { model.receive(HookEvent(kind: .stop, session: session, cwd: folder), at: now - 300) }
            for k in 0..<count {
                let agent = "\(session)-\(k)"
                let name = names[(i + k) % names.count]
                model.receive(
                    HookEvent(kind: .subagentStart, session: session, cwd: folder, agentID: agent, agentType: name),
                    at: now - 300)
                if (i + k) % 4 == 1 {
                    model.receive(
                        HookEvent(
                            kind: .permissionRequest, session: session, cwd: folder, agentID: agent, agentType: name),
                        at: now - 200)
                } else if (i + k) % 4 == 3 {
                    model.receive(
                        HookEvent(
                            kind: .notification, session: session, cwd: folder, agentID: agent, agentType: name,
                            notification: "idle_prompt"), at: now - 200)
                }
            }
        }
        return model
    }

    func testCaptureOffice() throws {
        // Four islands, 16 people: the default window holds them all.
        for (time, hour) in [("day", 14), ("night", 22)] {
            let full = team(sessions: 4, teammates: 3, at: today(hour))
            XCTAssertEqual(full.office.islands.map(\.slot), [0, 1, 2, 3])
            // One teammate tries the headphones on; nothing decides who wears them yet.
            let trying = Stage()
            trying.headphones = ["m:team-0-0"]
            try capture(
                "office-16-\(time)", size: OfficeView.defaultSize,
                OfficeView(fixedNow: today(hour), stage: trying).environmentObject(full))

            let (model, stage) = scenario(at: today(hour))
            try capture(
                "office-\(time)", size: OfficeView.defaultSize,
                OfficeView(fixedNow: today(hour), stage: stage).environmentObject(model))
            let (small, smallStage) = scenario(at: today(hour), still: true)
            try capture(
                "office-min-\(time)", size: OfficeView.minSize,
                OfficeView(fixedNow: today(hour), stage: smallStage).environmentObject(small))
        }
        // The helper on its way to blog's island: down the lane, along the aisle between the rows.
        let (passing, passingStage) = scenario(at: today(14), walked: 1.5)
        try capture(
            "office-passing", size: OfficeView.defaultSize,
            OfficeView(fixedNow: today(14), stage: passingStage).environmentObject(passing))

        // Going home: my-project's session walks out with its three teammates; their island stays, empty, until
        // the last of them is out of the door, and the other islands keep their places.
        let (leaving, leavingStage) = scenario(at: today(14), still: true)
        let width = Int(OfficeView.defaultSize.width) / RoomLayout.pointsPerPixel
        _ = leavingStage.sync(leaving.office, width: width, now: today(14) - 3, animate: true)
        leaving.receive(
            HookEvent(kind: .sessionEnd, session: "demo-b1", cwd: FakeScenario.root + "/my-project"),
            at: today(14) - 0.4)
        _ = leavingStage.sync(leaving.office, width: width, now: today(14) - 0.4, animate: true)
        XCTAssertEqual(leaving.office.islands.map(\.slot), [1, 2, 3])
        let walking = leavingStage.moment(at: today(14))
        XCTAssertEqual(walking.walkers.count + walking.standing.count, 4, "the session and its three teammates")
        func drawn(at time: Date) -> [Int] {
            leavingStage.scene(at: time, frame: 0, height: 400, reduceMotion: false).scene.pods.map(\.slot)
        }
        XCTAssertEqual(drawn(at: today(14)), [0, 1, 2, 3], "its island waits for them")
        XCTAssertEqual(drawn(at: today(14) + 30), [1, 2, 3], "then goes")
        try capture(
            "office-session-end", size: OfficeView.defaultSize,
            OfficeView(fixedNow: today(14), stage: leavingStage).environmentObject(leaving))

        // Reduce Motion takes the same path as animate: false: people appear at their seats at once.
        let (still, stillStage) = scenario(at: today(22), still: true)
        try capture(
            "office-reduce-motion", size: OfficeView.defaultSize,
            OfficeView(fixedNow: today(22), stage: stillStage).environmentObject(still))

        // Nobody at work: no islands, only the meeting room and the lounge.
        let empty = makeModel(connected: true)
        for (time, hour) in [("day", 14), ("night", 22)] {
            try capture(
                "office-empty-\(time)", size: OfficeView.defaultSize,
                OfficeView(fixedNow: today(hour)).environmentObject(empty))
        }

        let one = team(sessions: 1, teammates: 0, at: today(14))
        try capture("office-one", size: OfficeView.defaultSize, OfficeView(fixedNow: today(14)).environmentObject(one))

        // Both headphone pictures: on someone facing the room and on someone with their back to it.
        let pair = team(sessions: 1, teammates: 3, at: today(14))
        let pairStage = Stage()
        pairStage.headphones = ["p:team-0", "m:team-0-0"]
        try capture(
            "office-headphones", size: OfficeView.minSize,
            OfficeView(fixedNow: today(14), stage: pairStage).environmentObject(pair))

    }

    /// One island a session: a team of five shows "+2", a fifth session scrolls, eight fill four rows, one folder's
    /// two sessions sit at two islands, a team in the meeting room leaves its island empty, and the smallest window
    /// keeps the "+2".
    func testCaptureSessionIslands() throws {
        // my-project's five teammates: three at its island, "+2" on its tag. Light by day, dark by night.
        for (suffix, hour) in [("", 14), ("-night", 22)] {
            let overflow = team([5, 2, 1, 0], at: today(hour))
            XCTAssertEqual(overflow.office.islands.map(\.slot), [0, 1, 2, 3])
            guard case .session(_, let more)? = overflow.office.pods[0].seats[0] else { return XCTFail("my-project") }
            XCTAssertEqual(more, 2)
            try capture(
                "office-team-overflow" + suffix, size: OfficeView.defaultSize,
                OfficeView(fixedNow: today(hour)).environmentObject(overflow))
        }

        // Five sessions and only nine people: the fifth session's island starts a third row, below the fold.
        let fifth = team([1, 0, 2, 0, 1], at: today(14))
        XCTAssertEqual(fifth.office.islands.map(\.slot), [0, 1, 2, 3, 4])
        try capture(
            "office-fifth-session", size: OfficeView.defaultSize,
            OfficeView(fixedNow: today(14)).environmentObject(fifth))

        // Eight sessions in a window tall enough for all four rows.
        let eight = team([3, 1, 0, 2, 5, 0, 1, 3], at: today(14))
        XCTAssertEqual(eight.office.islands.count, 8)
        try capture(
            "office-all", size: CGSize(width: OfficeView.defaultSize.width, height: 1360),
            OfficeView(fixedNow: today(14)).environmentObject(eight))

        // One folder, two sessions: two islands, "my-project" and "my-project 2", each with its Plan.
        let twins = makeModel(connected: true)
        let project = FakeScenario.root + "/my-project"
        for session in ["twin-1", "twin-2"] {
            twins.receive(HookEvent(kind: .userPromptSubmit, session: session, cwd: project), at: today(14) - 300)
            twins.receive(
                HookEvent(
                    kind: .subagentStart, session: session, cwd: project, agentID: session + "-p", agentType: "Plan"),
                at: today(14) - 300)
        }
        XCTAssertEqual(twins.office.desks[0].sessions.map(\.name), ["my-project", "my-project 2"])
        XCTAssertEqual(twins.office.desks[0].teammates.map(\.number), [1, 2])
        XCTAssertEqual(twins.office.islands.map(\.slot), [0, 1])
        try capture(
            "office-same-folder", size: OfficeView.defaultSize, OfficeView(fixedNow: today(14)).environmentObject(twins)
        )

        // my-project meets its five: the three from its island at the table, "+2" on the glass door, the island
        // empty.
        let meeting = meetingOffice(at: today(14), teammates: 5)
        meeting.advanceMeetings(to: today(14) - 150)
        XCTAssertEqual(meeting.office.meeting?.members.count, 3)
        XCTAssertEqual(meeting.office.meeting?.more, 2)
        try capture(
            "office-meeting-island", size: OfficeView.defaultSize,
            OfficeView(fixedNow: today(14)).environmentObject(meeting))

        // The smallest window: one island, its "+2" whole.
        try capture(
            "office-min", size: OfficeView.minSize,
            OfficeView(fixedNow: today(14)).environmentObject(team([5, 1], at: today(14))))
    }

    /// Sessions found on this Mac before any news: four quiet ones as the app opens; quiet, busy, one whose news has
    /// come and one known by news only; the connect line when no news ever came, also in the smallest window; the
    /// side panel's four state badges, and a quiet session's panel.
    func testCaptureDetected() throws {
        let now = today(14)
        func found(_ pid: Int32, _ folder: String, busy: Bool = false) -> OfficeState.Found {
            OfficeState.Found(pid: pid, started: now - 3600, folder: FakeScenario.root + "/" + folder, busy: busy)
        }
        let four = makeModel(connected: true)
        four.receive(
            found: ["my-project", "web-app", "blog", "api"].enumerated().map {
                found(Int32(100 + $0.offset), $0.element)
            },
            at: now - 120)
        XCTAssertEqual(four.office.count(.quiet), 4)
        try capture(
            "office-detected-four", size: OfficeView.defaultSize, OfficeView(fixedNow: now).environmentObject(four))

        let mixed = makeModel(connected: true)
        mixed.receive(
            found: [found(100, "my-project"), found(101, "web-app", busy: true), found(102, "blog")], at: now - 300)
        let blog = FakeScenario.root + "/blog"
        mixed.receive(HookEvent(kind: .userPromptSubmit, session: "b1", cwd: blog, pid: 102), at: now - 200)
        mixed.receive(
            HookEvent(kind: .subagentStart, session: "b1", cwd: blog, agentID: "b1-e", agentType: "Explore", pid: 102),
            at: now - 190)
        mixed.receive(HookEvent(kind: .permissionRequest, session: "b1", cwd: blog, pid: 102), at: now - 120)
        mixed.receive(HookEvent(kind: .stop, session: "a1", cwd: FakeScenario.root + "/api", pid: 103), at: now - 100)
        let sessions = mixed.office.desks.flatMap(\.sessions)
        XCTAssertEqual(sessions.map(\.state), [.quiet, .working, .waiting, .resting])
        XCTAssertEqual(mixed.office.islands.map(\.slot), [0, 1, 2, 3], "blog's news went on in its seat")
        try capture(
            "office-detected-mixed", size: OfficeView.defaultSize, OfficeView(fixedNow: now).environmentObject(mixed))

        let fresh = makeModel(connected: false)
        fresh.receive(found: [found(100, "my-project"), found(101, "web-app", busy: true)], at: now - 60)
        XCTAssertTrue(fresh.asksToConnect)
        try capture(
            "office-not-connected-detected", size: OfficeView.defaultSize,
            OfficeView(fixedNow: now).environmentObject(fresh))
        try capture("office-min-detected", size: OfficeView.minSize, OfficeView(fixedNow: now).environmentObject(fresh))

        // Working, waiting, resting, quiet, side by side.
        let selections = try [1, 2, 3, 0].map { slot in
            PanelSelection(try XCTUnwrap(mixed.office.pods[slot].seats[0]), at: .seat(slot: slot, index: 0))
        }
        try capture(
            "panel-status", size: CGSize(width: 4 * (SidePanelView.width + 1), height: 330),
            SidePanels(selections: selections, now: now).environmentObject(mixed))
        try capture(
            "panel-quiet", size: OfficeView.defaultSize,
            OfficeView(fixedNow: now, panel: try panel(mixed, slot: 0, index: 0)).environmentObject(mixed))
    }

    /// Show Details in the side panel: the file being edited, the edits, the latest steps and the model; a task
    /// list; teammates done; a teammate's long command; the same with Show Details off; the smallest window with a
    /// long path. Events go through the helper's own reading, from the hook input Claude Code gives.
    func testCaptureDetails() throws {
        let now = today(14)
        let project = FakeScenario.root + "/my-project"
        func hook(_ model: AppModel, _ fields: [String: Any], at seconds: TimeInterval) throws {
            var all = fields
            all["session_id"] = all["session_id"] ?? "d1"
            all["cwd"] = project
            let data = try JSONSerialization.data(withJSONObject: all)
            model.receive(try XCTUnwrap(HookEvent.fromHookInput(data, pid: nil, details: true)), at: now + seconds)
        }
        func tool(_ model: AppModel, _ name: String, _ input: [String: Any], agent: String? = nil, at: TimeInterval)
            throws
        {
            var fields: [String: Any] = ["hook_event_name": "PreToolUse", "tool_name": name, "tool_input": input]
            fields["agent_id"] = agent
            try hook(model, fields, at: at)
        }
        func working(_ details: Bool = true) throws -> AppModel {
            let model = makeModel(connected: true)
            model.showsDetails = details
            try hook(model, ["hook_event_name": "SessionStart", "model": "claude-opus-4-7"], at: -900)
            try hook(model, ["hook_event_name": "UserPromptSubmit"], at: -600)
            try tool(model, "Read", ["file_path": project + "/src/app.css"], at: -500)
            try tool(model, "Grep", ["pattern": "button"], at: -400)
            try tool(
                model, "Edit", ["file_path": project + "/notes.md", "old_string": "a\nb", "new_string": "c\nd"],
                at: -240)
            try tool(model, "Write", ["file_path": project + "/src/ui/button.css", "content": "1\n2\n3\n"], at: -120)
            try tool(
                model, "Edit",
                ["file_path": project + "/src/ui/button.css", "old_string": "x", "new_string": "y\nz\nw"], at: -10)
            return model
        }

        let detail = try working()
        try capture(
            "panel-detail", size: OfficeView.defaultSize,
            OfficeView(fixedNow: now, panel: try panel(detail, slot: 0, index: 0)).environmentObject(detail))
        let off = try working(false)
        XCTAssertNil(off.office.detail(session: "d1")?.model)
        try capture(
            "panel-detail-off", size: OfficeView.defaultSize,
            OfficeView(fixedNow: now, panel: try panel(off, slot: 0, index: 0)).environmentObject(off))

        let tasks = try working()
        try tool(
            tasks, "TodoWrite",
            [
                "todos": [
                    ["content": "Pick the button colours", "status": "completed"],
                    ["content": "Match the header", "status": "completed"],
                    ["content": "Match the button colours", "status": "in_progress"],
                ]
            ], at: -5)
        try tool(
            tasks, "Edit", ["file_path": project + "/src/ui/button.css", "old_string": "x", "new_string": "y"],
            at: -2)
        XCTAssertEqual(tasks.office.detail(session: "d1")?.tasks.total, 3)
        try capture(
            "panel-detail-tasks", size: OfficeView.defaultSize,
            OfficeView(fixedNow: now, panel: try panel(tasks, slot: 0, index: 0)).environmentObject(tasks))

        let team = try working()
        for (id, type) in [("t1", "Explore"), ("t2", "Plan"), ("t3", "code-reviewer")] {
            try hook(
                team, ["hook_event_name": "SubagentStart", "agent_id": id, "agent_type": type], at: -300)
        }
        for id in ["t1", "t2"] { try hook(team, ["hook_event_name": "SubagentStop", "agent_id": id], at: -60) }
        XCTAssertEqual(team.office.detail(session: "d1").map { [$0.teamCalled, $0.teamDone] }, [3, 2])
        try capture(
            "panel-detail-team", size: OfficeView.defaultSize,
            OfficeView(fixedNow: now, panel: try panel(team, slot: 0, index: 0)).environmentObject(team))

        // code-reviewer runs one long command: "Running a command · 4 min".
        try tool(team, "Read", ["file_path": project + "/src/app.ts"], agent: "t3", at: -280)
        try tool(team, "Bash", ["command": "swift test"], agent: "t3", at: -240)
        try capture(
            "panel-detail-teammate", size: OfficeView.defaultSize,
            OfficeView(fixedNow: now, panel: try panel(team, slot: 0, index: 3)).environmentObject(team))

        let small = try working()
        let deep = project + "/packages/web-app/src/components/navigation/very-long-component-name-for-the-header.tsx"
        try tool(small, "Edit", ["file_path": deep, "old_string": "a", "new_string": "b"], at: -1)
        try capture(
            "panel-detail-small", size: OfficeView.minSize,
            OfficeView(fixedNow: now, panel: try panel(small, slot: 0, index: 0)).environmentObject(small))
    }

    /// my-project hands work to `teammates` teammates and waits for them; web-app works on with a helper, blog
    /// rests. The meeting starts once `advanceMeetings` passes 10 s after the teammates came (`now` - 200).
    private func meetingOffice(at now: Date, teammates: Int = 3) -> AppModel {
        let model = makeModel(connected: true)
        func send(
            _ kind: HookEvent.Kind, _ session: String, _ folder: String, agent: String? = nil, type: String? = nil,
            at: Date
        ) {
            model.receive(
                HookEvent(
                    kind: kind, session: session, cwd: FakeScenario.root + "/" + folder, agentID: agent,
                    agentType: type), at: at)
        }
        let names = ["Explore", "Plan", "code-reviewer", "general-purpose", "Explore", "Plan", "Explore"]
        send(.userPromptSubmit, "m1", "my-project", at: now - 300)
        for k in 0..<teammates {
            send(.subagentStart, "m1", "my-project", agent: "m1-\(k)", type: names[k], at: now - 200)
        }
        send(.userPromptSubmit, "w1", "web-app", at: now - 300)
        send(.subagentStart, "w1", "web-app", agent: "w1-h", at: now - 250)
        send(.preToolUse, "w1", "web-app", at: now - 100)
        send(.sessionStart, "b1", "blog", at: now - 300)
        return model
    }

    func testCaptureMeeting() throws {
        let width = Int(OfficeView.defaultSize.width) / RoomLayout.pointsPerPixel
        for (time, hour) in [("day", 14), ("night", 22)] {
            let model = meetingOffice(at: today(hour))
            model.advanceMeetings(to: today(hour) - 150)
            XCTAssertEqual(model.office.meeting?.session.name, "my-project")
            try capture(
                "office-meeting-\(time)", size: OfficeView.defaultSize,
                OfficeView(fixedNow: today(hour)).environmentObject(model))
        }
        // On the way: through the glass door, around the table.
        let now = today(14)
        let walking = meetingOffice(at: now)
        let stage = Stage()
        _ = stage.sync(walking.office, width: width, now: now - 2, animate: true)
        walking.advanceMeetings(to: now - 2)
        _ = stage.sync(walking.office, width: width, now: now - 2, animate: true)
        try capture(
            "office-meeting-gathering", size: OfficeView.defaultSize,
            OfficeView(fixedNow: now, stage: stage).environmentObject(walking))

        // Seven teammates: the three seated at my-project's island at the table, "+4" on the glass door for the
        // four still waiting for a seat.
        let full = meetingOffice(at: now, teammates: 7)
        full.advanceMeetings(to: now - 150)
        XCTAssertEqual(full.office.meeting?.more, 4)
        try capture(
            "office-meeting-full", size: CGSize(width: OfficeView.defaultSize.width, height: 1060),
            OfficeView(fixedNow: now).environmentObject(full))

        // Plan asks for permission during the meeting: it stays at the table with a hopping "!", the glass door
        // shows one too, and my-project's tag puts the wait before the meeting.
        let asking = meetingOffice(at: now)
        asking.advanceMeetings(to: now - 150)
        asking.receive(
            HookEvent(
                kind: .permissionRequest, session: "m1", cwd: FakeScenario.root + "/my-project", agentID: "m1-1",
                agentType: "Plan"), at: now - 130)
        XCTAssertNotNil(asking.office.meeting, "waiting for an answer keeps the meeting")
        XCTAssertEqual(asking.office.count(.waiting), 1)
        try capture(
            "office-meeting-waiting", size: OfficeView.defaultSize, OfficeView(fixedNow: now).environmentObject(asking))

        // web-app meets too, later: the room is my-project's, so web-app's tag only says so.
        let two = meetingOffice(at: now)
        for k in 0..<2 {
            two.receive(
                HookEvent(
                    kind: .subagentStart, session: "w1", cwd: FakeScenario.root + "/web-app", agentID: "w1-\(k)",
                    agentType: "Plan"), at: now - 90)
        }
        two.advanceMeetings(to: now - 60)
        XCTAssertEqual(two.office.meeting?.session.name, "my-project")
        XCTAssertEqual(two.office.desks.flatMap(\.sessions).filter(\.meets).count, 2)
        try capture(
            "office-meeting-second", size: OfficeView.defaultSize, OfficeView(fixedNow: now).environmentObject(two))

        // web-app's helper wears headphones: it works on through the meeting, and its panel says so.
        let helper = try XCTUnwrap(
            two.office.pods.flatMap { pod in pod.seats.indices.map { (pod.slot, $0, pod.seats[$0]) } }.first {
                $0.2.flatMap(OfficeScene.id) == "m:w1-h"
            })
        XCTAssertEqual(two.office.session("w1")?.teammates.first?.headphones, true)
        try capture(
            "panel-meeting-headphones", size: OfficeView.defaultSize,
            OfficeView(fixedNow: now, panel: try panel(two, slot: helper.0, index: helper.1)).environmentObject(two))
    }

    /// The side panel on the seat at `slot`, `index`.
    private func panel(_ model: AppModel, slot: Int, index: Int) throws -> SidePanel {
        let seat = try XCTUnwrap(model.office.pods.first { $0.slot == slot }?.seats[index])
        return SidePanel(PanelSelection(seat, at: .seat(slot: slot, index: index)))
    }

    /// Teams: my-project called Explore and went on editing files (Explore wears headphones), Explore called Plan
    /// (at Explore's island, indented under it in the panel, which also says what my-project is doing now). In
    /// web-app, Explore walks over to Plan to talk.
    func testCaptureTeamsHeadphonesAndTalks() throws {
        let now = today(14)
        let model = makeModel(connected: true)
        let project = FakeScenario.root + "/my-project"
        let web = FakeScenario.root + "/web-app"
        func send(
            _ kind: HookEvent.Kind, _ session: String, _ cwd: String, agent: String? = nil, type: String? = nil,
            tool: HookEvent.ToolKind? = nil, to: String? = nil, at: TimeInterval
        ) {
            model.receive(
                HookEvent(
                    kind: kind, session: session, cwd: cwd, agentID: agent, agentType: type, toolKind: tool,
                    sendsMessage: to != nil, recipient: to), at: now + at)
        }
        send(.userPromptSubmit, "m1", project, at: -300)
        send(.preToolUse, "m1", project, tool: .team, at: -290)
        send(.subagentStart, "m1", project, agent: "e1", type: "Explore", at: -289)
        send(.preToolUse, "m1", project, tool: .edit, at: -200)
        send(.preToolUse, "m1", project, agent: "e1", type: "Explore", tool: .team, at: -150)
        send(.subagentStart, "m1", project, agent: "p1", type: "Plan", at: -149)
        send(.preToolUse, "m1", project, tool: .edit, at: -12)
        send(.userPromptSubmit, "w1", web, at: -300)
        send(.subagentStart, "w1", web, agent: "e2", type: "Explore", at: -280)
        send(.subagentStart, "w1", web, agent: "p2", type: "Plan", at: -260)
        let mates = try XCTUnwrap(model.office.session("m1")?.teammates)
        XCTAssertEqual(mates.map(\.calledBy), [nil, "e1"])
        XCTAssertEqual(mates.map(\.headphones), [true, false])
        try capture(
            "panel-team-doing", size: OfficeView.defaultSize,
            OfficeView(fixedNow: now, panel: try panel(model, slot: 0, index: 0)).environmentObject(model))

        let stage = Stage()
        let width = Int(OfficeView.defaultSize.width) / RoomLayout.pointsPerPixel
        _ = stage.sync(model.office, width: width, now: now - 20, animate: true)
        send(.preToolUse, "w1", web, agent: "e2", type: "Explore", tool: .team, to: "Plan", at: -10)
        _ = stage.sync(model.office, width: width, now: now - 10, animate: true)
        let talk = try talking(stage, from: now - 10, to: now)
        try capture(
            "office-talk", size: OfficeView.defaultSize,
            OfficeView(fixedNow: talk, stage: stage).environmentObject(model))
    }

    /// The side panel: a session with three teammates, a teammate, over the smallest window, someone who went
    /// home, a nickname being typed, and nicknames on the name tags.
    func testCaptureSidePanel() throws {
        let now = today(14)
        let office = team(sessions: 4, teammates: 3, at: now)
        try capture(
            "panel-session", size: OfficeView.defaultSize,
            OfficeView(fixedNow: now, panel: try panel(office, slot: 0, index: 0)).environmentObject(office))
        try capture(
            "panel-teammate", size: OfficeView.defaultSize,
            OfficeView(fixedNow: now, panel: try panel(office, slot: 0, index: 2)).environmentObject(office))
        try capture(
            "panel-small", size: OfficeView.minSize,
            OfficeView(fixedNow: now, panel: try panel(office, slot: 0, index: 1)).environmentObject(office))

        let leaving = team(sessions: 2, teammates: 0, at: now)
        let gone = try panel(leaving, slot: 1, index: 0)
        leaving.receive(
            HookEvent(kind: .sessionEnd, session: "team-1", cwd: FakeScenario.root + "/web-app"), at: now - 10)
        try capture(
            "panel-went-home", size: OfficeView.defaultSize,
            OfficeView(fixedNow: now, panel: gone).environmentObject(leaving))

        let typing = try panel(office, slot: 0, index: 0)
        typing.draft = "shop 🛒"
        try capture(
            "panel-nickname-typing", size: OfficeView.defaultSize,
            OfficeView(fixedNow: now, panel: typing).environmentObject(office))

        let named = team(sessions: 4, teammates: 3, at: now)
        XCTAssertNotNil(named.rename(.session("team-0"), to: "shop 🛒"))
        let explore = try XCTUnwrap(named.office.session("team-0")?.teammates.first)
        XCTAssertNotNil(named.rename(.teammate(explore.id), to: "Scout"))
        try capture(
            "panel-nicknames", size: OfficeView.defaultSize,
            OfficeView(fixedNow: now, panel: try panel(named, slot: 0, index: 0)).environmentObject(named))
    }

    /// The middle of the first moment someone stands and talks, between `from` and `to`.
    private func talking(_ stage: Stage, from: Date, to: Date) throws -> Date {
        let start = try XCTUnwrap(
            stride(from: 0.0, to: to.timeIntervalSince(from), by: 0.05).map { from + $0 }.first {
                !stage.moment(at: $0).talks.isEmpty
            })
        return start + Stage.talkTime / 2
    }

    /// ① my-project walks over to its new Explore's desk and talks; ② a Plan that worked a while reports at
    /// my-project's desk on its way out. With Reduce Motion nobody walks: the speaking mark shows at the seat, and
    /// the meeting sits down at once.
    func testCaptureHandOffReportAndReduceMotion() throws {
        let width = Int(OfficeView.defaultSize.width) / RoomLayout.pointsPerPixel
        let base = today(14)
        let folder = FakeScenario.root + "/my-project"
        func office(_ stage: Stage, animate: Bool = true) -> AppModel {
            let model = meetingOffice(at: base, teammates: 0)
            _ = stage.sync(model.office, width: width, now: base - 30, animate: animate)
            return model
        }

        let handOff = Stage()
        let visited = office(handOff)
        visited.receive(
            HookEvent(kind: .subagentStart, session: "m1", cwd: folder, agentID: "e1", agentType: "Explore"),
            at: base - 20)
        _ = handOff.sync(visited.office, width: width, now: base - 20, animate: true)
        let visit = try talking(handOff, from: base - 20, to: base)
        try capture(
            "office-hand-off", size: OfficeView.defaultSize,
            OfficeView(fixedNow: visit, stage: handOff).environmentObject(visited))

        // ① to a newcomer across the desks: the caller stands at the island's end, off the name tags. The first
        // teammate sits across from its session (that end is the lane); with two teammates there before it, the
        // newcomer sits across on the right.
        for (name, earlier) in [("office-hand-off-front", 0), ("office-hand-off-front-right", 2)] {
            let stage = Stage()
            let model = makeModel(connected: true)
            model.receive(HookEvent(kind: .userPromptSubmit, session: "f0", cwd: folder), at: base - 300)
            for (k, type) in ["Plan", "code-reviewer"].prefix(earlier).enumerated() {
                model.receive(
                    HookEvent(kind: .subagentStart, session: "f0", cwd: folder, agentID: "e\(k)", agentType: type),
                    at: base - 300)
            }
            _ = stage.sync(model.office, width: width, now: base - 30, animate: true)
            model.receive(
                HookEvent(kind: .subagentStart, session: "f0", cwd: folder, agentID: "x1", agentType: "Explore"),
                at: base - 20)
            _ = stage.sync(model.office, width: width, now: base - 20, animate: true)
            XCTAssertEqual(
                model.office.pods.first?.seats[1 + earlier].flatMap(OfficeScene.id), "m:x1", "seat \(1 + earlier)")
            try capture(
                name, size: OfficeView.defaultSize,
                OfficeView(fixedNow: try talking(stage, from: base - 20, to: base), stage: stage).environmentObject(
                    model))
        }

        let report = Stage()
        let reporting = office(report)
        reporting.receive(
            HookEvent(kind: .subagentStart, session: "m1", cwd: folder, agentID: "p1", agentType: "Plan"),
            at: base - 200)
        _ = report.sync(reporting.office, width: width, now: base - 30, animate: true)
        reporting.receive(
            HookEvent(kind: .subagentStop, session: "m1", cwd: folder, agentID: "p1", agentType: "Plan"),
            at: base - 20)
        _ = report.sync(reporting.office, width: width, now: base - 20, animate: true)
        let told = try talking(report, from: base - 20, to: base)
        try capture(
            "office-report", size: OfficeView.defaultSize,
            OfficeView(fixedNow: told, stage: report).environmentObject(reporting))

        // Reduce Motion: my-project's three meet at once at the table; web-app's new Explore gets the speaking
        // mark at web-app's own seat.
        let calm = Stage()
        let still = office(calm, animate: false)
        for k in 0..<3 {
            still.receive(
                HookEvent(
                    kind: .subagentStart, session: "m1", cwd: folder, agentID: "c\(k)",
                    agentType: ["Explore", "Plan", "code-reviewer"][k]), at: base - 25)
        }
        still.advanceMeetings(to: base - 15)
        still.receive(
            HookEvent(
                kind: .subagentStart, session: "w1", cwd: FakeScenario.root + "/web-app", agentID: "e2",
                agentType: "Explore"), at: base - 3)
        _ = calm.sync(still.office, width: width, now: base - 3, animate: false)
        let moment = calm.moment(at: base)
        XCTAssertEqual(moment.walkers.count, 0)
        XCTAssertEqual(moment.room.count, 4)
        XCTAssertEqual(moment.talks.count, 1)
        try capture(
            "office-meeting-reduce-motion", size: OfficeView.defaultSize,
            OfficeView(fixedNow: base, stage: calm).environmentObject(still))
    }

    /// Every desk prop twice: once across the desks and once with the back to the room. Folder and teammate names
    /// are picked so each prop comes up: at each island the session and its first teammate get one prop, its other
    /// two teammates the next.
    func testCaptureDeskProps() throws {
        let model = makeModel(connected: true)
        let names = Prop.allCases.map { prop in (0...).lazy.map { "desk-\($0)" }.first { Prop.pick($0) == prop }! }
        for first in stride(from: 0, to: names.count, by: 2) {
            let session = "prop-\(first)"
            let folder = FakeScenario.root + "/" + names[first]
            model.receive(HookEvent(kind: .userPromptSubmit, session: session, cwd: folder), at: today(14) - 300)
            let next = names[min(first + 1, names.count - 1)]
            for (k, name) in [names[first], next, next].enumerated() {
                model.receive(
                    HookEvent(
                        kind: .subagentStart, session: session, cwd: folder, agentID: "\(session)-\(k)",
                        agentType: name), at: today(14) - 300)
            }
        }
        XCTAssertEqual(model.office.islands.count, (names.count + 1) / 2)
        XCTAssertEqual(model.office.pods.flatMap(\.seats).compactMap { $0 }.count, model.office.islands.count * 4)
        for (time, hour) in [("day", 14), ("night", 22)] {
            try capture(
                "office-props-\(time)", size: CGSize(width: OfficeView.defaultSize.width, height: 1060),
                OfficeView(fixedNow: today(hour)).environmentObject(model))
        }
    }

    /// The README picture (copied by hand to docs/images/): the example office in the default window, my-project
    /// meeting its three teammates (Plan waiting for an answer at the table), the others at their islands. Light
    /// by day, dark by night.
    func testCaptureReadme() throws {
        for (time, hour) in [("day", 14), ("night", 22)] {
            let model = makeModel(connected: true)
            for event in FakeScenario.events { model.receive(event, at: today(hour) - 200) }
            model.advanceMeetings(to: today(hour))
            XCTAssertEqual(model.office.meeting?.members.count, 3)
            try capture(
                "readme-\(time)", size: OfficeView.defaultSize,
                OfficeView(fixedNow: today(hour)).environmentObject(model))
        }
    }

    /// One walking speed (v0.2's 120 px/s): the farthest seat of the default window is 4 to 6 seconds from the
    /// door, the nearest about one.
    func testFarSeatWalkTakesFourToSixSeconds() {
        let room = RoomLayout(points: OfficeView.defaultSize.width, slots: 4)
        let seconds = (0..<4).flatMap { slot in
            (0..<Island.size).map { Stage.length(room.route(slot: slot, seat: $0)) / Stage.speed }
        }
        XCTAssertTrue((4...6).contains(seconds.max()!), "\(seconds.max()!)")
        XCTAssertTrue((0.5...1.5).contains(seconds.min()!), "\(seconds.min()!)")
    }

    /// Seats are not focusable (no focus ring) when the window opens, and Tab makes them so. A real, key window, as
    /// focus needs one. The ring itself can't be checked here: drawing the view into a bitmap leaves it out.
    func testTabTurnsOnKeyboardFocus() throws {
        let (model, stage) = scenario(at: today(22), still: true)
        let host = NSHostingView(
            rootView: OfficeView(fixedNow: today(22), stage: stage).environmentObject(model)
                .environment(\.locale, Locale(identifier: "ko")))
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: OfficeView.defaultSize), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        defer {
            window.close()
            KeyboardNavigation.shared.active = false  // as a click would, for the tests after this one
        }
        func settle() {
            // The app's own event loop is not running here, so hand queued events (the re-posted Tab) over by hand.
            let until = Date() + 0.5
            while Date() < until {
                if let event = NSApp.nextEvent(matching: .any, until: Date() + 0.05, inMode: .default, dequeue: true) {
                    NSApp.sendEvent(event)
                }
            }
        }
        settle()
        XCTAssertFalse(KeyboardNavigation.shared.active)
        let tab = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t",
                isARepeat: false, keyCode: 48))
        NSApp.sendEvent(tab)
        settle()
        XCTAssertTrue(KeyboardNavigation.shared.active)
    }

    /// Under the real top bar, with no scrolling: four islands (16 people) and the right-hand column in the
    /// default window, one island and its name tags in the smallest. The bar measured in both languages.
    func testDefaultWindowHoldsFourIslands() {
        let model = makeModel(connected: true)
        let bar = ["en", "ko"].map { language in
            NSHostingView(
                rootView: OfficeBar().environmentObject(model).environment(\.locale, Locale(identifier: language))
            ).fittingSize.height + 1  // + divider
        }.max()!
        let room = RoomLayout(points: OfficeView.defaultSize.width, slots: 4)
        XCTAssertEqual(room.columns, 2)
        XCTAssertEqual(room.columns * room.rows, 4)
        XCTAssertNotNil(room.pillar)
        XCTAssertLessThanOrEqual(
            bar + CGFloat(room.contentHeight * RoomLayout.pointsPerPixel), OfficeView.defaultSize.height)
        XCTAssertGreaterThan(
            bar + CGFloat(RoomLayout(points: OfficeView.defaultSize.width, slots: 5).contentHeight * 2),
            OfficeView.defaultSize.height, "a fifth island scrolls")
        let smallest = RoomLayout(points: OfficeView.minSize.width, slots: 1)
        XCTAssertEqual(smallest.columns, 1)
        XCTAssertLessThanOrEqual(
            bar + CGFloat(smallest.contentHeight * RoomLayout.pointsPerPixel), OfficeView.minSize.height)
    }

    /// The art's credits and license travel inside the app, and every picture the office draws is there.
    func testArtCreditsAndPicturesAreInTheBundle() throws {
        let art = try XCTUnwrap(Bundle.main.resourceURL?.appendingPathComponent("Art"))
        for name in ["CREDITS.txt", "LICENSE.txt"] {
            let text = try String(contentsOf: art.appendingPathComponent(name), encoding: .utf8)
            XCTAssertTrue(text.contains("OGA-BY 3.0"), name)
            XCTAssertTrue(text.contains("CC0 1.0"), name)
        }
        let store = ArtStore()
        XCTAssertNotNil(store.cell(Look.shadow, 0, 0, 32, 32))
        for look in Look.all {
            for layer in look.layers {
                // The last cell of the row: the sheet is 24 cells wide and has this row.
                XCTAssertNotNil(store.cell(layer.sheet, 23 * 32, layer.row * 32, 32, 32), "\(layer)")
            }
        }
    }

    /// Every pack picture inside the app has its own line in the credits, every credited file is there, and
    /// Settings > Art names every artist on an ARTIST(S) line.
    func testCreditsCoverEveryPictureInTheBundle() throws {
        let art = try XCTUnwrap(Bundle.main.resourceURL?.appendingPathComponent("Art"))
        let credits = try String(contentsOf: art.appendingPathComponent("CREDITS.txt"), encoding: .utf8)
        let files = try XCTUnwrap(FileManager.default.enumerator(atPath: art.path))
            .compactMap { $0 as? String }.filter { $0.hasSuffix(".png") }
        XCTAssertGreaterThanOrEqual(files.count, 30, "the folder was found")
        for file in files where !file.hasPrefix("MetroCity/") {
            XCTAssertTrue(credits.contains("-- Used here: " + file), file)
        }
        for file in files where file.hasPrefix("MetroCity/") {
            XCTAssertTrue(credits.contains(file) || credits.contains((file as NSString).lastPathComponent), file)
        }
        let used = credits.components(separatedBy: "\n").filter { $0.hasPrefix("-- Used here: ") }
            .map { String($0.dropFirst("-- Used here: ".count)) }
        XCTAssertGreaterThanOrEqual(used.count, 25)
        for file in used { XCTAssertTrue(files.contains(file), "credited but missing: \(file)") }

        let artists = credits.components(separatedBy: "\n").filter { $0.contains("ARTIST(S):") }
            .flatMap { $0.components(separatedBy: "ARTIST(S):")[1].components(separatedBy: ",") }
            .map { $0.replacingOccurrences(of: #"\(.*\)"#, with: "", options: .regularExpression) }
        XCTAssertGreaterThanOrEqual(Set(artists).count, 4)
        for artist in artists {
            let words = artist.split(separator: " ")
            XCTAssertTrue(
                SettingsView.artists.contains { name in words.allSatisfy { name.contains($0) } },
                "Settings > Art misses \(artist)")
        }
    }

    /// People get LPC-like colours: black outlines one step lighter, no pure white, a little less saturated.
    func testPeopleColoursMoveTowardTheRoom() {
        let black = ArtStore.nearRoom(0, 0, 0)
        XCTAssertGreaterThan(Int(black.0) + Int(black.1) + Int(black.2), 60)
        XCTAssertLessThan(ArtStore.nearRoom(255, 255, 255).0, 255)
        let orange = ArtStore.nearRoom(0xCC, 0x74, 0x1D)
        XCTAssertLessThan(Int(orange.0) - Int(orange.2), 0xCC - 0x1D)
        XCTAssertGreaterThan(orange.0, orange.1, "still orange")
    }

    /// At least eight people with different hair (at most two blond, no hair band), both suits among them, every
    /// skin tone of the pack, and a name keeps its person.
    func testLooks() {
        XCTAssertEqual(Set(Look.all.map { "\($0.hair)" }).count, Look.all.count)
        XCTAssertGreaterThanOrEqual(Look.all.count, 8)
        let blond = Look.all.filter { $0.hair.sheet.hasSuffix("MetroCity 2.0/Hair.png") && $0.hair.row != 1 }
        XCTAssertLessThanOrEqual(blond.count, 2)
        XCTAssertFalse(blond.contains { $0.hair.row == 4 }, "the hair band with a ponytail")
        XCTAssertGreaterThanOrEqual(Look.all.filter { $0.clothes.sheet.hasSuffix("/Suit.png") }.count, 2)
        XCTAssertEqual(Set(Look.all.map(\.skin)), Set(0..<6))
        XCTAssertEqual(Look.pick("my-project"), Look.pick("my-project"))
    }

    /// Everyone seated in the example office (captures, README pictures) has different hair, and so do Claude
    /// Code's own agents side by side: one name numbered 1 to 3, or different names with the same number.
    func testExampleOfficeHasNoTwoSameHeads() {
        var office = OfficeState()
        for event in FakeScenario.events { office.apply(event, now: today(14)) }
        let heads = office.pods.flatMap(\.seats).compactMap { $0.flatMap(OfficeScene.look).map { "\($0.hair)" } }
        XCTAssertEqual(heads.count, 8)
        XCTAssertEqual(Set(heads).count, heads.count, "\(heads)")

        let names = ["Explore", "Plan", "general-purpose", "helper"]
        let groups =
            names.map { name in (1...3).map { "\(name) \($0)" } }
            + (1...3).map { desk in names.map { "\($0) \(desk)" } }
        for group in groups {
            XCTAssertEqual(Set(group.map { "\(Look.pick($0).hair)" }).count, group.count, "\(group)")
        }
    }

    /// A desk prop goes by the folder's name for a session (its second and third sessions get the same one) and
    /// by the name for a teammate. Different names get different props, and every prop's picture is in the bundle.
    func testDeskPropsGoByFolderAndName() throws {
        var office = OfficeState()
        let folder = FakeScenario.root + "/my-project"
        for session in ["a", "b", "c"] {
            office.apply(HookEvent(kind: .userPromptSubmit, session: session, cwd: folder), now: today(14))
            office.apply(
                HookEvent(
                    kind: .subagentStart, session: session, cwd: folder, agentID: session + "1", agentType: "Plan"),
                now: today(14))
        }
        office.apply(HookEvent(kind: .sessionEnd, session: "a", cwd: folder), now: today(14))
        let seats = office.pods.flatMap(\.seats).compactMap { $0 }
        XCTAssertEqual(seats.count, 4, "a's island left with it")
        let props = { (wanted: (Seat) -> Bool) in Set(seats.filter(wanted).map(OfficeScene.prop)) }
        let sessions = props {
            switch $0 {
            case .session: return true
            case .teammate: return false
            }
        }
        XCTAssertEqual(sessions.count, 1, "my-project 2 and my-project 3")
        XCTAssertEqual(
            props { if case .teammate = $0 { return true } else { return false } }.count, 1, "Plan 2, Plan 3")
        let names = ["my-project", "web-app", "blog", "api", "Explore", "Plan", "code-reviewer", "helper"]
        XCTAssertGreaterThanOrEqual(Set(names.map(Prop.pick)).count, 4, "the example names don't all match")

        XCTAssertGreaterThanOrEqual(Prop.allCases.count, 10, "at least six new kinds beside the four before")

        let store = ArtStore()
        let small = "Objects/Small Items/"
        for (sheet, x, y) in [
            (small + "Lighting, Table.png", 224, 32), (small + "Lighting, Table.png", 192, 32),
            (small + "Lighting, Table.png", 160, 32), (small + "Lighting, Table.png", 128, 32),
            ("Objects/Furniture/Planter.png", 128, 0), (small + "Laptop.png", 64, 0), (small + "Laptop.png", 64, 96),
            (small + "Dishes A.png", 0, 0), (small + "Coffee Maker.png", 64, 0), (small + "Rotary Phones.png", 32, 32),
            (small + "Tabletop Portraits.png", 32, 32), (small + "Loose Paper.png", 32, 64),
            (small + "Boxes.png", 32, 32), (small + "Flowers.png", 128, 64), (small + "Flowers.png", 192, 0),
            (small + "Flowers.png", 96, 64),
        ] {
            XCTAssertNotNil(store.cell(sheet, x, y, 32, 32), "\(sheet) \(x),\(y)")
        }
    }

    /// The meeting room's glass door has a second picture, standing open, for the walks to a meeting.
    func testMeetingRoomDoorHasAnOpenPicture() throws {
        func pixels(_ scene: OfficeScene) throws -> Data {
            let image = try XCTUnwrap(OfficeRenderer().render(scene))
            return try XCTUnwrap(image.dataProvider?.data as Data?)
        }
        let shut = OfficeScene(
            layout: RoomLayout(points: OfficeView.defaultSize.width, slots: 0), height: MeetingRoom.columnDepth,
            pods: [], darkness: 0, frame: 0, now: today(14))
        XCTAssertNotNil(shut.layout.meetingRoom)
        var open = shut
        open.meetingDoorOpen = true
        XCTAssertNotEqual(try pixels(shut), try pixels(open))
    }

    /// The bitmap is twice as dense as the art, so the view shows one bitmap pixel per point: the room keeps
    /// its size on screen.
    func testOfficeBitmapIsOnePixelPerPoint() {
        let layout = RoomLayout(points: OfficeView.defaultSize.width, slots: 4)
        let image = OfficeRenderer().render(
            OfficeScene(layout: layout, height: 300, pods: [], darkness: 1, frame: 0, now: Date()))
        XCTAssertEqual(layout.width * RoomLayout.pointsPerPixel, Int(OfficeView.defaultSize.width))
        XCTAssertEqual(image?.width, Int(OfficeView.defaultSize.width))
        XCTAssertEqual(image?.height, 300 * RoomLayout.pointsPerPixel)
    }

    /// The room without walkers with each walker's box laid over it is the one picture, pixel for pixel: walkers
    /// stay under the night light, behind lit lamps and bubbles, and the door opens for them.
    func testWalkerBoxesOverTheRoomMakeTheSamePicture() throws {
        for (hour, walked) in [(22, 0.1), (22, 0.9), (14, 1.5)] {
            let now = today(hour)
            let (model, stage) = scenario(at: now, walked: walked)
            let width = Int(OfficeView.defaultSize.width) / RoomLayout.pointsPerPixel
            let (_, layout) = stage.sync(model.office, width: width, now: now, animate: true)
            let height = layout.contentHeight + 20
            let parts = stage.picture(at: now, frame: 3, height: height, reduceMotion: false)
            XCTAssertFalse(parts.walkers.isEmpty)
            var (scene, walking) = stage.scene(at: now, frame: 3, height: height, reduceMotion: false)
            scene.walkers += walking
            let whole = try XCTUnwrap(OfficeRenderer().render(scene))
            func pixels(_ paint: (CGContext) throws -> Void) throws -> [UInt8] {
                var bytes = [UInt8](repeating: 0, count: whole.width * whole.height * 4)
                try bytes.withUnsafeMutableBytes { buffer in
                    let context = try XCTUnwrap(
                        CGContext(
                            data: buffer.baseAddress, width: whole.width, height: whole.height, bitsPerComponent: 8,
                            bytesPerRow: whole.width * 4, space: ArtStore.screenSpace,
                            bitmapInfo: ArtStore.screenFormat))
                    context.setBlendMode(.copy)
                    try paint(context)
                }
                return bytes
            }
            let full = CGRect(x: 0, y: 0, width: whole.width, height: whole.height)
            let density = CGFloat(OfficeRenderer.density)
            let laid = try pixels { context in
                context.draw(try XCTUnwrap(parts.room), in: full)
                for piece in parts.walkers {
                    let box = piece.box
                    context.draw(
                        try XCTUnwrap(piece.image),
                        in: CGRect(
                            x: box.minX * density, y: full.height - box.maxY * density, width: box.width * density,
                            height: box.height * density))
                }
            }
            XCTAssert(try laid == pixels { $0.draw(whole, in: full) }, "\(hour):00, \(walked) s in")
        }
    }

    /// At the walking frame rate a walker moves about 4 art pixels a frame and the six-picture walk advances at
    /// most one picture a frame, so the feet never skip a step.
    func testWalkAtItsFrameRateMovesInSmallSteps() throws {
        let now = today(14)
        let (_, stage) = scenario(at: now, walked: 0)
        let rate = OfficePicture.walkingFrameRate
        var frames = 0
        var last: Walker?
        // The helper walking in (blog's session visits it after, in its own walk).
        let helper = Look.pick("helper 1")
        while let walker = stage.moment(at: now + Double(frames) / rate).walkers.first(where: { $0.look == helper }) {
            if let last {
                let moved = hypot(Double(walker.x - last.x), Double(walker.y - last.y))
                XCTAssertLessThanOrEqual(moved, Stage.speed / rate + 1.5, "frame \(frames)")
                XCTAssert((0...1).contains(walker.step - last.step), "frame \(frames)")
            }
            last = walker
            frames += 1
        }
        XCTAssertGreaterThan(frames, 10)
    }

    /// Someone who starts after the app walks in even when the window first draws a moment later, and is seated
    /// once the walk would be over. A session opened before the app sits down without walking.
    func testWalkInCountsFromTheArrivalNotTheFirstDrawing() {
        let width = Int(OfficeView.defaultSize.width) / RoomLayout.pointsPerPixel
        let t0 = today(14)
        var office = OfficeState()
        office.apply(HookEvent(kind: .sessionStart, session: "new", cwd: "/x/new"), now: t0 + 1)
        office.apply(HookEvent(kind: .preToolUse, session: "old", cwd: "/x/old"), now: t0 + 1)
        let cases: [(drawn: TimeInterval, walking: [String])] = [(1.5, ["p:new"]), (10, [])]
        for (drawn, walking) in cases {
            let stage = Stage()
            _ = stage.sync(office, width: width, now: t0 + drawn, animate: true)
            XCTAssertEqual(stage.moment(at: t0 + drawn).away.sorted(), walking, "first drawn \(drawn) s in")
        }
    }

    /// Four islands, all 16 people working, the window on screen and ticking: how much CPU the office takes.
    func testCPUWithFourIslandsWorking() throws {
        let model = makeModel(connected: true)
        for i in 0..<4 {
            let folder = FakeScenario.root + "/cpu-\(i)"
            model.receive(HookEvent(kind: .userPromptSubmit, session: "cpu-\(i)", cwd: folder))
            for k in 0..<3 {
                model.receive(
                    HookEvent(
                        kind: .subagentStart, session: "cpu-\(i)", cwd: folder, agentID: "cpu-\(i)-\(k)",
                        agentType: "Explore"))
            }
        }
        // cpu-0's panel has details to show: steps, edits, a task list, the model.
        for (index, name) in ["a.swift", "b.swift", "c.swift"].enumerated() {
            var edit = HookEvent(
                kind: .preToolUse, session: "cpu-0", cwd: FakeScenario.root + "/cpu-0",
                toolKind: index == 1 ? .read : .edit)
            (edit.file, edit.linesAdded, edit.linesRemoved) = ("src/" + name, 3, 1)
            model.receive(edit, at: Date() - Double(60 * (3 - index)))
        }
        var todo = HookEvent(kind: .preToolUse, session: "cpu-0", cwd: FakeScenario.root + "/cpu-0", toolKind: .tasks)
        (todo.taskAction, todo.todoTotal, todo.todoDone, todo.taskTitle) = (.todo, 3, 1, "Speed up the office")
        model.receive(todo)
        func cpuSeconds() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        func percent(over seconds: TimeInterval) -> Double {
            let cpu = cpuSeconds()
            let start = Date()
            RunLoop.main.run(until: Date() + seconds)
            return (cpuSeconds() - cpu) / Date().timeIntervalSince(start) * 100
        }
        // The test app on its own (its own empty office, menu bar item, socket, test runner).
        let idle = percent(over: 5)

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: OfficeView.defaultSize), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        let stage = Stage()
        let panel = SidePanel()
        window.contentView = NSHostingView(
            rootView: OfficeView(stage: stage, panel: panel, ticksWhileHidden: true).environmentObject(model))
        window.orderFrontRegardless()
        defer { window.close() }
        RunLoop.main.run(until: Date() + 3)

        let total = percent(over: 10)
        let visible = window.occlusionState.contains(.visible)
        // The side panel open on cpu-0, its minutes redrawn every 30 s.
        let first = try XCTUnwrap(model.office.pods.first?.seats[0])
        panel.open(PanelSelection(first, at: .seat(slot: 0, index: 0)))
        RunLoop.main.run(until: Date() + 2)
        let panelOpen = percent(over: 10) - idle
        panel.close()
        RunLoop.main.run(until: Date() + 1)
        // A teammate across the desks of the far island reports to its session and leaves: about 4 s of walking,
        // drawn 30 times a second.
        model.receive(
            HookEvent(
                kind: .subagentStop, session: "cpu-3", cwd: FakeScenario.root + "/cpu-3", agentID: "cpu-3-2",
                agentType: "Explore"))
        let walking = percent(over: 4) - idle
        // The walker still near the door, as the layers give it to the screen (screenshots use draw(_:)).
        func picture(in view: NSView) -> NSView? {
            view is OfficePicture.PictureView ? view : view.subviews.lazy.compactMap(picture).first
        }
        let layer = try XCTUnwrap(window.contentView.flatMap(picture)?.layer)
        let rep = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(layer.bounds.width), pixelsHigh: Int(layer.bounds.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0))
        layer.render(in: try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep)).cgContext)
        try rep.representation(using: .png, properties: [:])?.write(
            to: out.appendingPathComponent("office-walking-layers.png"))

        // Six at once: cpu-0 meets (the session and its three teammates walk to the meeting room) while two of
        // cpu-2's teammates report and leave. Then the meeting sits still.
        RunLoop.main.run(until: Date() + 6)
        model.advanceMeetings(to: Date() + OfficeState.meetingDelay)
        for k in 0..<2 {
            model.receive(
                HookEvent(
                    kind: .subagentStop, session: "cpu-2", cwd: FakeScenario.root + "/cpu-2", agentID: "cpu-2-\(k)",
                    agentType: "Explore"))
        }
        RunLoop.main.run(until: Date() + 0.2)
        XCTAssertEqual(stage.moment(at: Date()).walkers.count, 6)
        let six = percent(over: 4) - idle
        RunLoop.main.run(until: Date() + 8)
        XCTAssertEqual(stage.moment(at: Date()).room.count, 4, "cpu-0 and its three teammates at the table")
        let meeting = percent(over: 10) - idle
        // A closed window's picture still ticks (it is allowed to while hidden): take it out of each window measured.
        window.close()
        window.contentView = nil

        // The same office with Reduce Motion: nobody walks, the picture ticks every 30 s.
        let calm = NSWindow(
            contentRect: CGRect(origin: .zero, size: OfficeView.defaultSize), styleMask: [.titled], backing: .buffered,
            defer: false)
        calm.isReleasedWhenClosed = false
        calm.contentView = NSHostingView(
            rootView: OfficeView(ticksWhileHidden: true, reducesMotion: true).environmentObject(model))
        calm.orderFrontRegardless()
        defer { calm.close() }
        RunLoop.main.run(until: Date() + 3)
        let reduced = percent(over: 10) - idle
        calm.close()
        calm.contentView = nil

        // Four sessions found on this Mac, all quiet: nobody types or nods, nothing hops.
        let found = makeModel(connected: true)
        found.receive(
            found: (0..<4).map {
                OfficeState.Found(
                    pid: Int32(9000 + $0), started: Date() - 600, folder: FakeScenario.root + "/quiet-\($0)",
                    busy: false)
            })
        let quietWindow = NSWindow(
            contentRect: CGRect(origin: .zero, size: OfficeView.defaultSize), styleMask: [.titled], backing: .buffered,
            defer: false)
        quietWindow.isReleasedWhenClosed = false
        quietWindow.contentView = NSHostingView(
            rootView: OfficeView(ticksWhileHidden: true).environmentObject(found))
        quietWindow.orderFrontRegardless()
        defer { quietWindow.close() }
        RunLoop.main.run(until: Date() + 3)
        let quiet = percent(over: 10) - idle
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let locked = session?["CGSSessionScreenIsLocked"] as? Bool ?? false
        let asleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0

        // One picture on its own, to tell drawing from SwiftUI's share.
        let scene = OfficeScene(
            layout: RoomLayout(points: OfficeView.defaultSize.width, slots: 4), height: 350,
            pods: model.office.pods, darkness: 1, frame: 3, now: Date())
        let renderStart = Date()
        for _ in 0..<50 { _ = OfficeRenderer().render(scene) }
        let renderMs = Date().timeIntervalSince(renderStart) / 50 * 1000
        var day = scene
        day.darkness = 0
        let dayStart = Date()
        for _ in 0..<50 { _ = OfficeRenderer().render(day) }
        let dayMs = Date().timeIntervalSince(dayStart) / 50 * 1000
        var passing = scene
        passing.walkers = [Walker(look: Look.pick("box"), x: 200, y: 150, facing: .left, step: 0)]
        let boxStart = Date()
        for _ in 0..<50 { _ = OfficeRenderer().render(passing, crop: passing.walkers[0].box) }
        let boxMs = Date().timeIntervalSince(boxStart) / 50 * 1000

        let office = total - idle
        let line = String(
            format:
                "CPU, 4 islands x 4 seats (window visible=%@, locked=%@, display asleep=%@): still: office %.2f%% "
                + "(process %.2f%% - idle %.2f%%); side panel open, still: office %.2f%%; walking: office %.2f%%; "
                + "six walking: office %.2f%%; meeting, still: office %.2f%%; reduce motion: office %.2f%%; "
                + "four quiet, still: office %.2f%%; one picture: night %.2f ms, day %.2f ms; one walker box: night "
                + "%.2f ms\n",
            "\(visible)", "\(locked)", "\(asleep)", office, total, idle, panelOpen, walking, six, meeting, reduced,
            quiet, renderMs, dayMs, boxMs)
        print(line)
        try line.write(to: out.appendingPathComponent("cpu.txt"), atomically: true, encoding: .utf8)
        XCTAssertLessThan(office, 5)
    }

    func testCaptureOtherScreens() throws {
        let fresh = makeModel(connected: false)
        try capture("welcome", WelcomeView(location: .ok).environmentObject(fresh))
        try capture("welcome-move-app", WelcomeView(location: .notInApplications).environmentObject(fresh))
        try capture(
            "office-not-connected", size: OfficeView.minSize, OfficeView(fixedNow: Date()).environmentObject(fresh))
        try capture(
            "office-nobody", size: OfficeView.minSize,
            OfficeView(fixedNow: Date()).environmentObject(makeModel(connected: true)))

        let project = FakeScenario.root + "/my-project"
        let configured = makeModel(connected: true, start: StartCommand(folder: project, run: ["claude"]))
        try capture("settings", SettingsView().environmentObject(configured))
        // A pasted config with a zero-width space: the confirmation shows it.
        try capture(
            "start-confirm",
            StartSheet(sheet: .confirm(StartCommand(folder: project, run: ["claude", "--continue\u{200B}"])))
                .environmentObject(configured))
    }

    /// Start Work feedback, the inline "one more?" question, and the not-connected / idle variants.
    func testCaptureStatesAndErrors() throws {
        let later = Date() + 200
        func office(_ phase: AppModel.StartPhase, askAnother: Bool = false) -> AppModel {
            let model = makeModel(connected: true)
            for event in FakeScenario.events { model.receive(event) }
            model.startPhase = phase
            model.askAnother = askAnother
            return model
        }
        try capture(
            "office-starting", size: OfficeView.minSize,
            OfficeView(fixedNow: later).environmentObject(office(.starting(Date()))))
        try capture(
            "office-start-failed", size: OfficeView.minSize,
            OfficeView(fixedNow: later).environmentObject(office(.failed(.folderMissing))))
        try capture(
            "office-nobody-came", size: OfficeView.minSize,
            OfficeView(fixedNow: later).environmentObject(office(.nobodyCame)))
        try capture(
            "office-ask-another", size: OfficeView.minSize,
            OfficeView(fixedNow: later).environmentObject(office(.idle, askAnother: true)))

        let fresh = makeModel(connected: false)
        try capture("welcome-no-news", WelcomeView(location: .ok, noNewsYet: true).environmentObject(fresh))
        try capture("menu-not-connected", MenuContent().environmentObject(fresh))
        try capture("menubar-icon-idle", MenuBarLabel(model: fresh).padding(6))
    }

    /// Pressing 출근 again while starting, or while "one more?" is up, must not start a second time.
    func testStartWorkTwiceStartsOnce() {
        // The folder never exists, so any real launch shows "folder is missing" instead of opening Terminal.
        let missing = "/nonexistent-agent-overtime-test/\(UUID().uuidString.prefix(8))"
        let model = makeModel(connected: true)
        model.approveAndStart(StartCommand(folder: missing, run: ["echo", "출근 시험"]))
        XCTAssertEqual(model.startPhase, .failed(.folderMissing), "approved, and launch() was reached")

        let since = Date()
        model.startPhase = .starting(since)
        model.startWork()
        XCTAssertEqual(model.startPhase, .starting(since), "second press while starting")

        model.startPhase = .idle
        model.receive(HookEvent(kind: .sessionStart, session: "twice", cwd: missing))
        model.startWork()
        XCTAssertTrue(model.askAnother)
        model.startWork()
        XCTAssertTrue(model.askAnother)
        XCTAssertEqual(model.startPhase, .idle, "second press while asking")
    }

    /// Opens a real Terminal window with `echo`, so it only runs once after captures/.run-terminal-test is created.
    func testStartOpensTerminalWithoutAutomationPermission() throws {
        let flag = out.appendingPathComponent(".run-terminal-test")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: flag.path),
            "opens a Terminal window; create captures/.run-terminal-test to run it once")
        try FileManager.default.removeItem(at: flag)
        let folder = URL(fileURLWithPath: Paths.userTempFolder).appendingPathComponent(
            "ao-terminal-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let opened = expectation(description: "Terminal opened the script")
        var openError: Error?
        Launcher.run(StartCommand(folder: folder.path, run: ["echo", "출근 시험"]), scriptFolder: folder) { error in
            openError = error
            opened.fulfill()
        }
        wait(for: [opened], timeout: 15)
        XCTAssertNil(openError)

        // The script deletes itself on its first line, so an empty folder means Terminal really ran it.
        let leftovers = { (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] }
        let deadline = Date() + 15
        while !leftovers().isEmpty, Date() < deadline { RunLoop.main.run(until: Date() + 0.2) }
        XCTAssertEqual(leftovers(), [])
    }

    // MARK: helpers

    private func makeModel(connected: Bool, start: StartCommand? = nil) -> AppModel {
        let folder = (Paths.userTempFolder as NSString).appendingPathComponent("ao-cap-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        if let start {
            let config: [String: Any] = ["start": ["folder": start.folder, "run": start.run], "desks": []]
            try? JSONSerialization.data(withJSONObject: config).write(to: URL(fileURLWithPath: folder + "/config.json"))
        }
        let defaults = UserDefaults(suiteName: "ao-cap-\(UUID().uuidString)")!
        defaults.set(connected, forKey: "everConnected")
        return AppModel(supportFolder: folder, socketPath: folder + "/events.sock", defaults: defaults)
    }

    /// Light and dark, English and Korean.
    private func capture<V: View>(_ name: String, size: CGSize? = nil, _ view: V) throws {
        for (scheme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for language in ["en", "ko"] {
                let root =
                    view
                    .environment(\.locale, Locale(identifier: language))
                    .background(Color(nsColor: .windowBackgroundColor))
                let host = NSHostingView(rootView: root)
                let window = NSWindow(
                    contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                    backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: appearance)
                window.contentView = host
                var target = size ?? host.fittingSize
                if target.height < 50 { target.height = 760 }
                window.setContentSize(target)
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date() + 0.3)

                let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                try png.write(to: out.appendingPathComponent("\(name)-\(language)-\(scheme).png"))
                window.close()
            }
        }
    }
}

/// Side panels next to each other, one for each selection, for a capture.
private struct SidePanels: View {
    let selections: [PanelSelection]
    let now: Date
    @FocusState private var focus: OfficeFocus?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(selections.indices, id: \.self) { index in
                SidePanelView(panel: SidePanel(selections[index]), focus: $focus, fixedNow: now)
                    .frame(width: SidePanelView.width, alignment: .top)
                Divider()
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// Runs the embedded agent-overtime-hook the way Claude Code does: JSON on stdin, output thrown away.
final class HelperTests: XCTestCase {
    private var helper: URL!

    override func setUpWithError() throws {
        helper = try XCTUnwrap(Bundle.main.url(forAuxiliaryExecutable: Paths.helperName), "embedded in Contents/MacOS")
    }

    private func run(_ input: Data?, closeStdin: Bool = true) throws -> (status: Int32, output: Data, seconds: Double) {
        let process = Process()
        process.executableURL = helper
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stdout
        let started = Date()
        try process.run()
        if let input { stdin.fileHandleForWriting.write(input) }
        if closeStdin { try stdin.fileHandleForWriting.close() }
        process.waitUntilExit()
        let seconds = Date().timeIntervalSince(started)
        try? stdin.fileHandleForWriting.close()
        return (process.terminationStatus, stdout.fileHandleForReading.readDataToEndOfFile(), seconds)
    }

    /// Uses the real socket path, so it skips when the user's own copy of the app is running.
    func testSendsOnlyStateAndPrintsNothing() throws {
        let path = Paths.socket()
        try XCTSkipIf(
            FileManager.default.fileExists(atPath: path), "Agent Overtime is running; not touching its socket")
        let received = expectation(description: "event")
        var event: HookEvent?
        let server = EventServer(path: path) {
            event = $0
            received.fulfill()
        }
        try server.start()
        defer { server.stop() }

        let input = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "PreToolUse", "session_id": "helper-test", "cwd": "/Users/demo/work/shop",
            "tool_name": "Bash", "tool_input": ["command": "echo SECRET-TOKEN"], "transcript_path": "/x/y.jsonl",
        ])
        let result = try run(input)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output.count, 0, "anything printed would reach every Claude conversation")
        XCTAssertLessThan(result.seconds, 1)
        wait(for: [received], timeout: 2)
        XCTAssertEqual(
            event,
            HookEvent(
                kind: .preToolUse, session: "helper-test", cwd: "/Users/demo/work/shop", toolKind: .command,
                pid: getpid()),
            "only state fields and the tool's kind, and the parent process as the session")
    }

    func testQuietWithoutAppOrWithGarbage() throws {
        try XCTSkipIf(FileManager.default.fileExists(atPath: Paths.socket()), "Agent Overtime is running")
        for input in [
            Data("not json".utf8), Data(),
            Data(#"{"hook_event_name":"SessionStart","session_id":"s","cwd":"/x"}"#.utf8),
        ] {
            let result = try run(input)
            XCTAssertEqual(result.status, 0)
            XCTAssertEqual(result.output.count, 0)
        }
    }

    func testStopsOnItsOwnWhenStdinNeverEnds() throws {
        let result = try run(Data(#"{"hook_event_name":"#.utf8), closeStdin: false)
        XCTAssertEqual(result.status, 0)
        XCTAssertLessThan(result.seconds, 1.0, "0.5 s hard stop")
    }

    /// A model switch's hook output would reach Claude's context: nothing is printed, and it always exits 0.
    func testAModelSwitchPrintsNothing() throws {
        // The helper may reach the real socket: only while no other copy of the app is open (a socket file can
        // outlive it).
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: ShowDetails.appID)
            .filter { $0.processIdentifier != getpid() }
        try XCTSkipIf(!others.isEmpty, "Agent Overtime is running")
        let input = Data(
            #"{"hook_event_name":"PostModelSwitch","session_id":"s","cwd":"/x","from_model":"a","to_model":"b"}"#.utf8)
        let result = try run(input)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output.count, 0)
    }
}
