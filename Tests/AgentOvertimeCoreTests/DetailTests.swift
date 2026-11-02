import XCTest

@testable import AgentOvertimeCore

/// File names shortened and edits counted inside the helper, from the text alone.
final class DetailTests: XCTestCase {
    let folder = "/Users/me/my-project"

    func testInsideTheFolderAtMostTheLastTwoParts() {
        XCTAssertEqual(Detail.shortPath(folder + "/src/app.ts", in: folder), "src/app.ts")
        XCTAssertEqual(Detail.shortPath(folder + "/notes.md", in: folder), "notes.md")
        XCTAssertEqual(Detail.shortPath(folder + "/src/ui/button.css", in: folder), "…/ui/button.css")
        XCTAssertEqual(Detail.shortPath(folder + "//src///ui/kit/button.css", in: folder + "/"), "…/kit/button.css")
        XCTAssertEqual(Detail.shortPath("/etc/hosts", in: folder), "hosts", "outside: the name alone")
        XCTAssertNil(Detail.shortPath("src/app.ts", in: folder), "not absolute")
        XCTAssertNil(Detail.shortPath("/", in: folder))
    }

    /// The six cases to check: `..` parts, a folder of one part or none, a folder whose name starts another's,
    /// hidden characters and a long name, and the folder itself. None shows the folder's path or a home folder.
    func testNeverTheFullPathOrAnAccountName() {
        let cases: [(path: String, folder: String, shown: String)] = [
            ("/Users/me/p/../../x", "/Users/me/p", "x"),
            ("/Users/me/secret/file.txt", "/", "file.txt"),
            ("/Users/me/secret/file.txt", "/Users", "file.txt"),
            ("/a/proj2/f", "/a/proj", "f"),
            ("/a/proj/sub/../../proj2/f", "/a/proj", "f"),
            (folder, folder, "my-project"),
            (folder + "/ev\u{202E}il\n.txt", folder, "evil.txt"),
        ]
        for (path, base, shown) in cases {
            let result = Detail.shortPath(path, in: base)
            XCTAssertEqual(result, shown, path)
            for leaked in ["/Users", "me/", "secret", "proj/"] { XCTAssertFalse(result?.contains(leaked) ?? false) }
        }
        let long = Detail.shortPath(folder + "/" + String(repeating: "a", count: 300), in: folder)
        XCTAssertEqual(long?.count, Detail.file)
        XCTAssertEqual(long?.hasSuffix("…"), true)
    }

    func testLinesAnEditAddsAndRemoves() {
        XCTAssertTrue(Detail.lineChange(old: "a\nb\nc\n", new: "a\nX\nc\n") == (1, 1), "context lines left out")
        XCTAssertTrue(Detail.lineChange(old: "a\nb\n", new: "a\nb\nc\nd\n") == (2, 0))
        XCTAssertTrue(Detail.lineChange(old: "a\nb\nc", new: "a\nc") == (0, 1))
        XCTAssertTrue(Detail.lineChange(old: "same", new: "same") == (0, 0))
        XCTAssertTrue(Detail.lineChange(old: "", new: "one\ntwo") == (2, 0))
        XCTAssertTrue(Detail.lineChange(old: "x", new: "y") == (1, 1))
        XCTAssertEqual(Detail.lines("a\nb\nc\n"), 3)
        XCTAssertEqual(Detail.lines("a\nb"), 2)
        XCTAssertEqual(Detail.lines(""), 0)
        XCTAssertEqual(Detail.lines(String(repeating: "\n", count: 2_000_000)), Detail.maxLines, "capped")
    }

    /// Near the 8 MiB input limit, counting stays well inside the helper's 0.5 s.
    func testAHugeEditIsCountedQuickly() {
        let half = String(repeating: "let x = 1\n", count: 400_000)  // 4 MB
        let (old, new) = (half + "old\n" + half, half + "new\n" + half)
        let started = Date()
        let change = Detail.lineChange(old: old, new: new)
        XCTAssertTrue(change == (1, 1), "\(change)")
        XCTAssertEqual(Detail.lines(old), 800_001)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    }
}

/// What the app keeps for the side panel, per person, in memory: bounded, and gone with them.
final class PersonDetailTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let folder = "/Users/me/my-project"

    private func tool(
        _ kind: HookEvent.ToolKind, file: String? = nil, lines: (Int, Int)? = nil, agent: String? = nil,
        _ change: (inout HookEvent) -> Void = { _ in }
    ) -> HookEvent {
        var event = HookEvent(kind: .preToolUse, session: "s1", cwd: folder, agentID: agent, toolKind: kind)
        event.file = file
        (event.linesAdded, event.linesRemoved) = (lines?.0, lines?.1)
        change(&event)
        return event
    }

    func testStepsEditsAndTheModel() throws {
        var office = OfficeState()
        office.apply(HookEvent(kind: .userPromptSubmit, session: "s1", cwd: folder), now: t0)
        var start = HookEvent(kind: .sessionStart, session: "s1", cwd: folder)
        start.model = "claude-opus-4-7"
        office.apply(start, now: t0)
        office.apply(tool(.read, file: "app.ts"), now: t0 + 1)
        office.apply(tool(.read, file: "app.ts"), now: t0 + 2)
        office.apply(tool(.edit, file: "app.ts", lines: (5, 2)), now: t0 + 3)
        office.apply(tool(.edit, file: "app.ts", lines: (1, 0)), now: t0 + 4)
        office.apply(tool(.write, file: "notes.md", lines: (3, 0)), now: t0 + 5)
        office.apply(tool(.grep), now: t0 + 6)
        var detail = try XCTUnwrap(office.detail(session: "s1"))
        XCTAssertEqual(detail.steps.map(\.kind), [.read, .edit, .write, .grep], "a run on one file is one step")
        XCTAssertEqual(detail.steps[0].at, t0 + 2)
        XCTAssertEqual(
            detail.edits, [.init(file: "app.ts", added: 6, removed: 2), .init(file: "notes.md", added: 3, removed: 0)])
        XCTAssertEqual(detail.model, "claude-opus-4-7")
        office.apply(tool(.command), now: t0 + 7)
        XCTAssertEqual(office.detail(session: "s1")?.steps.count, PersonDetail.maxSteps)

        for i in 0..<25 { office.apply(tool(.edit, file: "f\(i)", lines: (1, 1)), now: t0 + 8) }
        detail = try XCTUnwrap(office.detail(session: "s1"))
        XCTAssertEqual(detail.edits.count, PersonDetail.maxEdits)
        XCTAssertEqual(detail.moreEdits, 7)
        office.apply(HookEvent(kind: .userPromptSubmit, session: "s1", cwd: folder), now: t0 + 9)
        XCTAssertEqual(office.detail(session: "s1")?.edits, [], "a new question starts them again")

        var switched = HookEvent(kind: .postModelSwitch, session: "s1", cwd: folder)
        switched.model = "claude-sonnet-4-5"
        office.apply(switched, now: t0 + 10)
        XCTAssertEqual(office.detail(session: "s1")?.model, "claude-sonnet-4-5")

        office.forgetDetails()
        detail = try XCTUnwrap(office.detail(session: "s1"))
        XCTAssertNil(detail.model)
        XCTAssertEqual(detail.edits, [])
        XCTAssertEqual(detail.steps.compactMap(\.file), [], "kinds stay, files go")
        XCTAssertFalse(detail.steps.isEmpty)
    }

    func testTaskLists() throws {
        var office = OfficeState()
        func tasks() -> TaskList? { office.detail(session: "s1")?.tasks }
        office.apply(
            tool(.tasks) {
                $0.taskAction = .todo
                ($0.todoTotal, $0.todoDone, $0.taskTitle) = (3, 1, "Fix the header")
            }, now: t0)
        XCTAssertEqual(tasks().map { [$0.total, $0.done] }, [3, 1])
        XCTAssertEqual(tasks()?.title, "Fix the header")

        // TaskCreate has no id yet: counted, and matched by the TaskUpdates that follow.
        for title in ["One", "Two", "Three"] {
            office.apply(tool(.tasks) { ($0.taskAction, $0.taskTitle) = (.create, title) }, now: t0 + 1)
        }
        XCTAssertEqual(tasks().map { [$0.total, $0.done] }, [3, 0], "a new list")
        XCTAssertNil(tasks()?.title)
        func update(_ id: String, _ status: HookEvent.TaskStatus?, _ title: String? = nil) {
            office.apply(
                tool(.tasks) { ($0.taskAction, $0.taskID, $0.taskStatus, $0.taskTitle) = (.update, id, status, title) },
                now: t0 + 2)
        }
        update("1", .completed)
        update("2", .inProgress, "Two")
        XCTAssertEqual(tasks().map { [$0.total, $0.done] }, [3, 1])
        XCTAssertEqual(tasks()?.title, "Two")
        update("3", .deleted)
        XCTAssertEqual(tasks()?.total, 2)
        for i in 10..<80 { update("\(i)", .pending) }
        XCTAssertEqual(tasks()?.total, TaskList.maxTasks, "the oldest go")
    }

    /// Teammates starting and stopping over and over between two prompts can't make the count grow without end.
    func testTheTeammateCountIsCapped() {
        var office = OfficeState()
        office.apply(HookEvent(kind: .userPromptSubmit, session: "s1", cwd: folder), now: t0)
        for i in 0..<200 {
            office.apply(HookEvent(kind: .subagentStart, session: "s1", cwd: folder, agentID: "x\(i)"), now: t0)
            office.apply(HookEvent(kind: .subagentStop, session: "s1", cwd: folder, agentID: "x\(i)"), now: t0)
        }
        XCTAssertLessThanOrEqual(office.detail(session: "s1")?.teamCalled ?? 0, 128)
        XCTAssertEqual(office.detail(session: "s1")?.teamDone, office.detail(session: "s1")?.teamCalled)
    }

    /// The session's teammates since its last prompt; details go with whoever leaves, and nobody unseated has any.
    func testTeammatesAndCleanUp() throws {
        var office = OfficeState()
        office.apply(HookEvent(kind: .userPromptSubmit, session: "s1", cwd: folder), now: t0)
        for id in ["a1", "a2", "a3"] {
            office.apply(HookEvent(kind: .subagentStart, session: "s1", cwd: folder, agentID: id), now: t0)
        }
        office.apply(tool(.edit, file: "x.ts", lines: (1, 0), agent: "a1"), now: t0 + 1)
        XCTAssertEqual(office.detail(teammate: "a1")?.edits.count, 1)
        office.apply(HookEvent(kind: .subagentStop, session: "s1", cwd: folder, agentID: "a1"), now: t0 + 2)
        office.apply(HookEvent(kind: .subagentStop, session: "s1", cwd: folder, agentID: "a2"), now: t0 + 2)
        XCTAssertEqual(office.detail(session: "s1").map { [$0.teamCalled, $0.teamDone] }, [3, 2])
        XCTAssertNil(office.detail(teammate: "a1"), "gone with it")

        var stranger = tool(.edit, file: "y.ts", lines: (1, 0), agent: "zz")
        stranger.sendsMessage = true
        office.apply(stranger, now: t0 + 3)
        XCTAssertNil(office.detail(teammate: "zz"), "nobody seated for it")

        office.apply(HookEvent(kind: .userPromptSubmit, session: "s1", cwd: folder), now: t0 + 4)
        XCTAssertEqual(office.detail(session: "s1").map { [$0.teamCalled, $0.teamDone] }, [0, 0])
        office.apply(HookEvent(kind: .sessionEnd, session: "s1", cwd: folder), now: t0 + 5)
        XCTAssertNil(office.detail(session: "s1"))
        XCTAssertNil(office.detail(teammate: "a3"), "the session's teammates' too")

        office.detect([OfficeState.Found(pid: 9, started: t0, folder: folder, busy: true)], now: t0, opening: true)
        XCTAssertNil(office.detail(session: try XCTUnwrap(office.desks.first?.sessions.first?.id)), "found only")
    }
}
