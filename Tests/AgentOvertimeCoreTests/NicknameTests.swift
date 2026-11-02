import XCTest

@testable import AgentOvertimeCore

/// Nicknames given on this Mac: a folder's sessions and a name's teammates show them, numbered like the names.
final class NicknameTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func event(
        _ kind: HookEvent.Kind, _ session: String, cwd: String, agent: String? = nil, type: String? = nil
    ) -> HookEvent {
        HookEvent(kind: kind, session: session, cwd: cwd, agentID: agent, agentType: type)
    }

    private func labels(_ office: OfficeState) -> [String] { office.desks.flatMap(\.sessions).map(\.label) }

    func testAFolderNicknameShowsOnItsSessionsAndTheNameStaysForTheLook() {
        var office = OfficeState()
        office.apply(event(.userPromptSubmit, "a", cwd: "/w/my-project"), now: t0)
        office.apply(event(.userPromptSubmit, "b", cwd: "/w/my-project"), now: t0)
        XCTAssertTrue(office.rename(folder: "/w/my-project", to: "  shop 🛒 "))
        XCTAssertEqual(labels(office), ["shop 🛒", "shop 🛒 2"])
        XCTAssertEqual(office.desks[0].sessions.map(\.name), ["my-project", "my-project 2"], "the look goes by these")
        office.apply(event(.sessionStart, "c", cwd: "/w/my-project"), now: t0)
        XCTAssertEqual(labels(office).last, "shop 🛒 3", "a newcomer from the folder shows it too")
        office.apply(event(.sessionEnd, "a", cwd: "/w/my-project"), now: t0)
        XCTAssertEqual(labels(office), ["shop 🛒 2", "shop 🛒 3"], "the others keep their numbers")
        XCTAssertTrue(office.rename(folder: "/w/my-project", to: ""))
        XCTAssertEqual(labels(office), ["my-project 2", "my-project 3"], "empty: back to the automatic name")
    }

    /// The same nickname on two folders is numbered like the same name; renaming one folder leaves everyone
    /// else's number alone.
    func testTheSameNicknameTwiceIsNumbered() {
        var office = OfficeState()
        office.apply(event(.userPromptSubmit, "a", cwd: "/w/web-app"), now: t0)
        office.apply(event(.userPromptSubmit, "b", cwd: "/x/blog"), now: t0)
        office.rename(folder: "/w/web-app", to: "work")
        office.rename(folder: "/x/blog", to: "work")
        XCTAssertEqual(labels(office), ["work", "work 2"])
        office.rename(folder: "/w/web-app", to: "home")
        XCTAssertEqual(labels(office), ["home", "work 2"], "blog keeps its number")
        office.rename(folder: "/x/blog", to: "web-app")
        office.rename(folder: "/w/web-app", to: nil)
        XCTAssertEqual(labels(office), ["web-app 2", "web-app"], "a nickname can match another folder's name")
    }

    /// A teammate's nickname goes by its name, so the next one of that name has it too.
    func testATeammateNicknameGoesByItsName() {
        var office = OfficeState()
        office.apply(event(.userPromptSubmit, "s", cwd: "/w/my-project"), now: t0)
        office.apply(event(.subagentStart, "s", cwd: "/w/my-project", agent: "e1", type: "Explore"), now: t0)
        office.apply(event(.subagentStart, "s", cwd: "/w/my-project", agent: "h1"), now: t0)
        XCTAssertTrue(office.rename(agent: "Explore", to: "Scout"))
        XCTAssertTrue(office.rename(agent: nil, to: "Runner"))
        office.apply(event(.subagentStart, "s", cwd: "/w/my-project", agent: "e2", type: "Explore"), now: t0)
        let mates = office.desks[0].sessions[0].teammates
        XCTAssertEqual(mates.map(\.nickname), ["Scout", "Runner", "Scout"])
        XCTAssertEqual(mates.map(\.labelNumber), [1, 1, 2])
        XCTAssertEqual(mates.map(\.number), [1, 1, 2], "the automatic numbers stay for the look")
        office.forgetNicknames()
        XCTAssertEqual(office.desks[0].sessions[0].teammates.map(\.nickname), [nil, nil, nil])
        XCTAssertEqual(office.nicknames, Nicknames())
    }

    /// config.json can be edited by hand: reading it back checks each nickname as if typed and drops only the bad
    /// ones; past 64 of a kind the rest are dropped too, and no new one is taken.
    func testReadingBackDropsOnlyTheBadNicknames() throws {
        let json = """
            {"folders": {"/w/shop": "shop", "/w/long": "\(String(repeating: "a", count: 33))", "/w/hidden": "a\\u200Bb",
                         "relative/path": "x", "/w/number": 5, "/w/spaces": " x "},
             "agents": {"Explore": "Scout", "": "Runner", "Plan\\u202E": "y", "code-reviewer": null}}
            """
        let read = try JSONDecoder().decode(Nicknames.self, from: Data(json.utf8))
        XCTAssertEqual(read.folders, ["/w/shop": "shop"])
        XCTAssertEqual(read.agents, ["Explore": "Scout", "": "Runner"])
        XCTAssertEqual(try JSONDecoder().decode(Nicknames.self, from: JSONEncoder().encode(read)), read)
        XCTAssertEqual(try JSONDecoder().decode(Nicknames.self, from: Data(#"{"folders": [1, 2]}"#.utf8)), Nicknames())

        let many = (0..<100).map { "\"/w/p\($0)\": \"n\($0)\"" }.joined(separator: ",")
        var office = OfficeState(
            nicknames: try JSONDecoder().decode(Nicknames.self, from: Data("{\"folders\": {\(many)}}".utf8)))
        XCTAssertEqual(office.nicknames.folders.count, Nicknames.maxCount)
        XCTAssertFalse(office.rename(folder: "/w/new", to: "new"), "full")
        XCTAssertTrue(office.rename(folder: office.nicknames.folders.keys.first!, to: "renamed"), "a known one still")
    }

    /// At most 32 characters (an emoji is one), hidden characters dropped, spaces trimmed; an empty name clears.
    func testNicknamesAreCleanedAndShort() {
        XCTAssertEqual(Nicknames.cleaned(" a\u{200B}b\u{202E}c "), "abc")
        XCTAssertEqual(Nicknames.cleaned(String(repeating: "가", count: 32)), String(repeating: "가", count: 32))
        XCTAssertNil(Nicknames.cleaned(String(repeating: "a", count: 33)))
        XCTAssertEqual(Nicknames.cleaned(String(repeating: "🛒", count: 32))?.count, 32)
        XCTAssertNil(Nicknames.cleaned("\u{200B}\u{200B}"))
        var office = OfficeState()
        office.apply(event(.userPromptSubmit, "a", cwd: "/w/my-project"), now: t0)
        XCTAssertFalse(office.rename(folder: "/w/my-project", to: String(repeating: "a", count: 33)))
        XCTAssertEqual(labels(office), ["my-project"])
        office.rename(folder: "/w/my-project", to: "shop")
        XCTAssertTrue(office.rename(folder: "/w/my-project", to: "\u{200B} "), "nothing visible: no nickname")
        XCTAssertEqual(labels(office), ["my-project"])
    }
}
