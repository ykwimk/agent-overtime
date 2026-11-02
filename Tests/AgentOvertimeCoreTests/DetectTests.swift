import XCTest

@testable import AgentOvertimeCore

/// Sessions found running on this Mac before any news: one person a process, quiet until its first news, which goes
/// on in the same seat; never among the recent folders until then.
final class DetectTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let project = "/Users/me/my-project"

    private func found(_ pid: Int32, _ folder: String? = nil, started: TimeInterval = 0, busy: Bool = false)
        -> OfficeState.Found
    {
        OfficeState.Found(pid: pid, started: t0 + started, folder: folder ?? project, busy: busy)
    }

    private func hook(_ kind: HookEvent.Kind, _ session: String, pid: Int32?, cwd: String? = nil) -> HookEvent {
        HookEvent(kind: kind, session: session, cwd: cwd ?? project, pid: pid)
    }

    func testFoundSessionsSitQuietOrWorkingAndWalkInOnlyOnceTheAppIsOpen() {
        var office = OfficeState()
        office.detect([found(10), found(20, "/w/web-app", busy: true)], now: t0 + 60, opening: true)
        let sessions = office.desks.flatMap(\.sessions)
        XCTAssertEqual(sessions.map(\.label), ["my-project", "web-app"])
        XCTAssertEqual(sessions.map(\.state), [.quiet, .working])
        XCTAssertEqual(sessions.map(\.arrived), [nil, nil], "there already: nobody walks in")
        XCTAssertEqual(sessions.map(\.heard), [false, false])
        XCTAssertEqual(office.islands.map(\.slot), [0, 1])
        XCTAssertEqual(office.count(.quiet), 1)
        XCTAssertEqual(office.count(.resting), 0, "never counted as resting")

        office.detect([found(10), found(20, "/w/web-app"), found(30, "/w/blog")], now: t0 + 65, opening: false)
        XCTAssertEqual(office.desks.flatMap(\.sessions).map(\.arrived), [nil, nil, t0 + 65], "a new one walks in")
        XCTAssertEqual(office.desks.flatMap(\.sessions).map(\.state), [.quiet, .quiet, .quiet], "web-app went quiet")
    }

    /// Found only: the recent folders stay as they were (nothing to save). Its first news goes on in the same seat
    /// as the same person, and only then is its folder remembered.
    func testFirstNewsGoesOnInTheSameSeatAndOnlyThenIsTheFolderRemembered() {
        var office = OfficeState(folders: ["/old/one"])
        office.detect([found(10), found(20, "/w/web-app")], now: t0, opening: true)
        XCTAssertEqual(office.folders, ["/old/one"])
        let person = office.desks[0].sessions[0].id

        XCTAssertTrue(office.apply(hook(.userPromptSubmit, "s1", pid: 10), now: t0 + 5), "remembered now")
        XCTAssertEqual(office.folders, ["/old/one", project])
        XCTAssertEqual(office.islands.map(\.slot), [0, 1], "no new seat")
        let session = office.desks[0].sessions[0]
        XCTAssertEqual(session.id, person, "the same person, so nobody walks")
        XCTAssertEqual(session.state, .working)
        XCTAssertTrue(session.heard)
        XCTAssertEqual(office.session(person)?.arrived, nil)

        // Its news goes on under the session id: teammates sit at its island, and its end sends it home.
        office.apply(HookEvent(kind: .subagentStart, session: "s1", cwd: project, agentID: "a1", pid: 10), now: t0 + 6)
        XCTAssertEqual(office.islands[0].seats[1], .teammate("a1"))
        office.apply(hook(.stop, "s1", pid: 10), now: t0 + 7)
        XCTAssertEqual(office.session(person)?.state, .resting)
        office.detect([found(10), found(20, "/w/web-app")], now: t0 + 10, opening: false)
        XCTAssertEqual(office.session(person)?.state, .resting, "a look changes nothing once there is news")
        office.apply(hook(.sessionEnd, "s1", pid: 10), now: t0 + 12)
        XCTAssertNil(office.session(person))
        XCTAssertEqual(office.islands.map(\.slot), [1])

        // The process still runs (after /clear, say): the next look seats it again, quiet.
        office.detect([found(10), found(20, "/w/web-app")], now: t0 + 15, opening: false)
        XCTAssertEqual(office.desks.flatMap(\.sessions).map(\.state), [.quiet, .quiet])
        XCTAssertEqual(office.islands.map(\.slot), [0, 1])
    }

    /// A session with news that is then found is the same person; a second session with news in the same process
    /// ends the first. One process, one seat.
    func testOneProcessOneSeat() {
        var office = OfficeState()
        office.apply(hook(.userPromptSubmit, "s1", pid: 10), now: t0)
        office.detect([found(10)], now: t0 + 5, opening: true)
        XCTAssertEqual(office.liveSessionCount, 1)
        XCTAssertEqual(office.desks[0].sessions[0].started, t0)

        office.apply(HookEvent(kind: .subagentStart, session: "s1", cwd: project, agentID: "a1", pid: 10), now: t0 + 6)
        office.apply(hook(.sessionStart, "s2", pid: 10), now: t0 + 7)
        XCTAssertEqual(office.desks.flatMap(\.sessions).map(\.id), ["s2"])
        XCTAssertNil(office.teammate("a1"), "the first session's teammates went with it")
        XCTAssertEqual(office.islands.count, 1)
    }

    /// The same number with another start time is another process: the first went home, the new one sits down.
    /// Gone from the list: home, with its teammates.
    func testSameNumberLaterStartIsAnotherPersonAndGoneMeansHome() {
        var office = OfficeState()
        office.detect([found(10)], now: t0, opening: true)
        let first = office.desks[0].sessions[0].id
        office.detect([found(10, started: 30)], now: t0 + 40, opening: false)
        XCTAssertNil(office.session(first))
        XCTAssertEqual(office.desks[0].sessions.map(\.started), [t0 + 30])
        XCTAssertEqual(office.desks[0].sessions[0].arrived, t0 + 40, "a new person walks in")

        office.apply(hook(.userPromptSubmit, "s1", pid: 10), now: t0 + 41)
        office.apply(HookEvent(kind: .subagentStart, session: "s1", cwd: project, agentID: "a1", pid: 10), now: t0 + 42)
        office.detect([], now: t0 + 45, opening: false)
        XCTAssertEqual(office.liveSessionCount, 0)
        XCTAssertNil(office.teammate("a1"))
        XCTAssertEqual(office.islands, [])

        // A session with news that was never found is left to the process check.
        office.apply(hook(.userPromptSubmit, "s9", pid: 99), now: t0 + 50)
        office.detect([], now: t0 + 55, opening: false)
        XCTAssertNotNil(office.session("s9"))
    }

    /// Name tags follow the usual rules; the home folder shows "~", not the account's name. A folder that isn't a
    /// clean absolute path seats nobody.
    func testNamesAndFolders() {
        var office = OfficeState()
        office.detect(
            [found(10, Paths.home), found(20), found(21), found(30, "relative/path"), found(40, "\u{200B}")], now: t0,
            opening: true)
        XCTAssertEqual(office.desks.flatMap(\.sessions).map(\.label), ["~", "my-project", "my-project 2"])
        XCTAssertEqual(office.desks.map(\.folder), [Paths.home, project])
    }
}

/// Telling Claude Code's processes from the rest: by name or by the official install's path, never by a word in it.
final class SessionFinderTests: XCTestCase {
    let home = "/Users/me"

    /// A made-up process table that counts each read.
    final class Table {
        struct Process {
            var uid: uid_t = 501
            var parent: Int32 = 1
            var name = "claude"
            var started: UInt64 = 1_000
            var path: String? = nil
            var folder: String? = "/Users/me/my-project"
            var cpu: UInt64? = 0
        }
        var processes: [Int32: Process] = [:]
        var reads: [String: Int] = [:]

        var table: SessionFinder.ProcessTable {
            SessionFinder.ProcessTable(
                list: { [unowned self] in self.processes.keys.sorted() },
                info: { [unowned self] pid in
                    self.processes[pid].map { ($0.uid, $0.parent, $0.name) }
                },
                started: { [unowned self] pid in self.processes[pid]?.started },
                path: { [unowned self] pid in
                    self.reads["path", default: 0] += 1
                    return self.processes[pid]?.path
                },
                folder: { [unowned self] pid in
                    self.reads["folder", default: 0] += 1
                    return self.processes[pid]?.folder
                },
                cpu: { [unowned self] pid in self.processes[pid]?.cpu })
        }
    }

    func testOnlyClaudeByNameOrByTheInstallPath() {
        XCTAssertTrue(SessionFinder.isClaude(name: "claude", path: nil, home: home))
        for name in ["Claude", "claude2", "claude-tools", "claude ", "node"] {
            XCTAssertFalse(SessionFinder.isClaude(name: name, path: nil, home: home), name)
        }
        let versions = home + "/.local/share/claude/versions/"
        XCTAssertTrue(SessionFinder.isClaude(name: "2.1.316", path: versions + "2.1.316", home: home))
        for path in [
            versions + "2.1.316/extra", versions + "latest", versions + "2.1",
            "/Users/other/.local/share/claude/versions/2.1.316",
            "/Applications/Claude.app/Contents/MacOS/Claude", home + "/claude-tools/claude", home + "/bin/claude",
        ] {
            XCTAssertFalse(SessionFinder.isClaude(name: "2.1.316", path: path, home: home), path)
        }
        XCTAssertTrue(SessionFinder.isVersion("10.0.1"))
        XCTAssertFalse(SessionFinder.isVersion("1..2"))
    }

    /// Others' processes, other names and a Claude Code started by another are left out; a process that answers
    /// short is skipped. The folder and path are read once for each process, not at every look.
    func testFindsTheSessionsAndReadsTheFolderOnce() {
        let fake = Table()
        fake.processes = [
            10: .init(),
            11: .init(parent: 10, folder: "/Users/me/my-project"),  // run by session 10
            12: .init(name: "2.1.316", started: 2_000, path: home + "/.local/share/claude/versions/2.1.316"),
            13: .init(uid: 502),
            14: .init(name: "Claude"),
            15: .init(name: "9.9.9", path: home + "/claude-tools/9.9.9"),
            16: .init(folder: nil),
        ]
        var finder = SessionFinder(table: fake.table, home: home, uid: 501)
        let found = finder.look(now: 1_000_000_000)
        XCTAssertEqual(found.map(\.pid), [10, 12])
        XCTAssertEqual(found.map(\.busy), [false, false], "nothing to compare yet")
        XCTAssertEqual(fake.reads["path"], 2, "only for the two names that are version numbers")
        let folders = fake.reads["folder", default: 0]
        _ = finder.look(now: 6_000_000_000)
        XCTAssertEqual(fake.reads["folder"], folders, "not again for the same process")
        XCTAssertEqual(fake.reads["path"], 2)

        // The same number with a new start time is another process: read anew.
        fake.processes[10]?.started = 5_000
        let again = finder.look(now: 7_000_000_000).first { $0.pid == 10 }
        XCTAssertEqual(again?.started.timeIntervalSince1970 ?? 0, 0.005, accuracy: 0.000_01)
        XCTAssertEqual(fake.reads["folder"], folders + 1)
    }

    /// Busy while it spends more than 3 % of the time since the last look on the CPU.
    func testBusyByCPUTime() {
        let fake = Table()
        fake.processes = [10: .init(cpu: 0)]
        var finder = SessionFinder(table: fake.table, home: home, uid: 501)
        _ = finder.look(now: 0)
        fake.processes[10]?.cpu = 100_000_000  // 0.1 s in 5 s: 2 %
        XCTAssertEqual(finder.look(now: 5_000_000_000).first?.busy, false)
        fake.processes[10]?.cpu = 600_000_000  // 0.5 s in 5 s: 10 %
        XCTAssertEqual(finder.look(now: 10_000_000_000).first?.busy, true)
        fake.processes[10]?.cpu = nil
        XCTAssertEqual(finder.look(now: 15_000_000_000).first?.busy, false, "unreadable: not busy")
        XCTAssertTrue(SessionFinder.isBusy(spent: 160_000_000, over: 5_000_000_000))
        XCTAssertFalse(SessionFinder.isBusy(spent: 1, over: 0))
    }
}

/// Finding on and off, and one process, one person.
final class FoundSessionTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let project = "/Users/me/my-project"

    private func found(_ pid: Int32, started: TimeInterval = 0) -> OfficeState.Found {
        OfficeState.Found(pid: pid, started: t0 + started, folder: project, busy: false)
    }

    /// Turned off, those only found go home; a session with news stays, and keeps the process it was matched with.
    func testTurningFindingOffAndAMatchedSessionsNumber() {
        var office = OfficeState()
        office.detect([found(10), found(20)], now: t0, opening: true)
        office.apply(HookEvent(kind: .userPromptSubmit, session: "s1", cwd: project, pid: 10), now: t0 + 1)
        office.apply(HookEvent(kind: .stop, session: "s1", cwd: project, pid: 99), now: t0 + 2)
        XCTAssertEqual(office.desks.flatMap(\.sessions).first { $0.heard }?.pid, 10, "news from another number")
        office.forgetFound()
        XCTAssertEqual(office.desks.flatMap(\.sessions).map(\.heard), [true])
        XCTAssertEqual(office.liveSessionCount, 1)
    }

    /// What was seen: a session at work, and a short Claude Code run in the same folder sending SessionStart and
    /// SessionEnd. Now it comes and goes as its own person (a hook's news), leaves no seat behind, and the session
    /// stays as it was. Found on this Mac, a Claude Code run by the session isn't a person at all.
    func testAShortRunInTheSameFolderLeavesNothingBehind() {
        var office = OfficeState()
        office.detect([found(10)], now: t0, opening: true)
        office.apply(HookEvent(kind: .userPromptSubmit, session: "s1", cwd: project, pid: 10), now: t0 + 1)
        office.apply(HookEvent(kind: .sessionStart, session: "short", cwd: project, pid: 11), now: t0 + 2)
        XCTAssertEqual(office.desks[0].sessions.map(\.label), ["my-project", "my-project 2"])
        office.apply(HookEvent(kind: .sessionEnd, session: "short", cwd: project, pid: 11), now: t0 + 3)
        XCTAssertEqual(office.desks[0].sessions.map(\.label), ["my-project"])
        XCTAssertEqual(office.islands.count, 1)
        XCTAssertEqual(office.desks[0].sessions[0].state, .working)
    }
}
