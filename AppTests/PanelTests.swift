import SwiftUI
import XCTest

@testable import AgentOvertime

/// The side panel and nicknames: what the panel shows, how it opens, moves and closes, and nicknames kept in
/// config.json, read back with care.
@MainActor
final class PanelTests: XCTestCase {
    let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let project = FakeScenario.root + "/my-project"

    private func folder() -> String {
        let folder = (Paths.userTempFolder as NSString).appendingPathComponent(
            "ao-panel-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        return folder
    }

    private func model(in folder: String) -> AppModel {
        AppModel(
            supportFolder: folder, socketPath: folder + "/events.sock",
            defaults: UserDefaults(suiteName: "ao-panel-\(UUID().uuidString)")!)
    }

    /// my-project with Explore, Plan and code-reviewer; web-app alone.
    private func office(_ model: AppModel) {
        model.receive(HookEvent(kind: .userPromptSubmit, session: "s1", cwd: project), at: t0)
        for (id, type) in [("a1", "Explore"), ("a2", "Plan"), ("a3", "code-reviewer")] {
            model.receive(
                HookEvent(kind: .subagentStart, session: "s1", cwd: project, agentID: id, agentType: type), at: t0)
        }
        model.receive(
            HookEvent(kind: .preToolUse, session: "s1", cwd: project, agentID: "a1", agentType: "Explore"), at: t0 + 5)
        model.receive(HookEvent(kind: .sessionStart, session: "w1", cwd: FakeScenario.root + "/web-app"), at: t0)
    }

    private func selection(_ model: AppModel, _ id: String) throws -> PanelSelection {
        for pod in model.office.pods {
            for (index, seat) in pod.seats.enumerated() {
                guard let seat, OfficeScene.id(seat)?.dropFirst(2) == Substring(id) else { continue }
                return PanelSelection(seat, at: .seat(slot: pod.slot, index: index))
            }
        }
        throw XCTSkip("nobody with id \(id)")
    }

    /// A session (its teammates listed), a teammate, a session with none, someone who went home; VoiceOver hears
    /// the name and the state.
    func testThePanelShowsWhoAndHowTheyAre() throws {
        let model = model(in: folder())
        office(model)
        guard case .session(let session, let named) = SidePanel.facts(try selection(model, "s1"), in: model.office)
        else { return XCTFail("a session") }
        XCTAssertEqual(session.teammates.map(\.name), ["Explore", "Plan", "code-reviewer"])
        XCTAssertFalse(named)
        guard case .teammate(let mate, let of) = SidePanel.facts(try selection(model, "a1"), in: model.office) else {
            return XCTFail("a teammate")
        }
        XCTAssertEqual(mate.name, "Explore")
        XCTAssertEqual(of.id, "s1")
        guard case .session(let alone, _) = SidePanel.facts(try selection(model, "w1"), in: model.office) else {
            return XCTFail("web-app")
        }
        XCTAssertEqual(alone.teammates, [], "No teammates")

        let spoken = try XCTUnwrap(SidePanel.spoken(.teammate("a1"), in: model.office, now: t0 + 6))
        XCTAssertTrue(spoken.hasPrefix("Explore, "), spoken)
        XCTAssertTrue(spoken.contains("my-project"), spoken)

        let leaving = try selection(model, "s1")
        model.receive(HookEvent(kind: .sessionEnd, session: "s1", cwd: project), at: t0 + 10)
        guard case .wentHome(let name) = SidePanel.facts(leaving, in: model.office) else { return XCTFail("gone") }
        XCTAssertEqual(name, "my-project")
    }

    /// Space on a teammate row opens that teammate; Esc while typing a nickname stops typing, then Esc closes the
    /// panel and focus goes back to the seat it was opened from.
    func testRowsSwitchAndEscClosesBackToTheSeat() throws {
        let model = model(in: folder())
        office(model)
        let start = try selection(model, "s1")
        let panel = SidePanel(start)
        panel.focus = .mate("a2")
        XCTAssertTrue(panel.press(in: model.office))
        XCTAssertEqual(panel.selection?.kind, .teammate("a2"))
        let plansDesk = try selection(model, "a2").seat
        XCTAssertEqual(panel.selection?.seat, plansDesk)

        panel.focus = .edit
        XCTAssertTrue(panel.press(in: model.office))
        XCTAssertEqual(panel.draft, "")
        XCTAssertTrue(panel.escape())
        XCTAssertNil(panel.draft)
        XCTAssertNotNil(panel.selection, "Esc while typing only stops typing")
        XCTAssertEqual(panel.focusRequest, .edit)
        XCTAssertTrue(panel.escape())
        XCTAssertNil(panel.selection)
        XCTAssertEqual(panel.focusRequest, plansDesk, "focus goes back to the seat")
        XCTAssertFalse(panel.escape(), "nothing open: Esc goes on to whoever wants it")
    }

    /// Pressing a character finds its seat, at a desk or at the meeting table; the floor finds nobody.
    func testPressingACharacterFindsItsSeat() throws {
        let model = model(in: folder())
        office(model)
        let stage = Stage()
        let width = Int(OfficeView.defaultSize.width) / RoomLayout.pointsPerPixel
        let (_, layout) = stage.sync(model.office, width: width, now: t0 + 60, animate: false)
        let origin = layout.origin(of: 0)
        let across = (x: origin.x + RoomLayout.personX(1), y: origin.y + RoomLayout.farDesk - 10)
        XCTAssertEqual(stage.seat(at: across, now: t0 + 60).map { [$0.slot, $0.index] }, [0, 1])
        XCTAssertNil(stage.seat(at: (x: 4, y: 300), now: t0 + 60))

        model.advanceMeetings(to: t0 + 60)
        _ = stage.sync(model.office, width: width, now: t0 + 61, animate: false)
        let room = try XCTUnwrap(layout.meetingRoom)
        let head = (x: room.seats[Stage.sessionSeat].x, y: MeetingRoom.table.y - 20)
        XCTAssertEqual(stage.seat(at: head, now: t0 + 61).map { [$0.slot, $0.index] }, [0, 0], "the session's desk")
    }

    /// Nicknames go to config.json and come back on the next start; clearing them all clears the file too.
    func testNicknamesAreKeptAndCleared() throws {
        let place = folder()
        let first = model(in: place)
        office(first)
        XCTAssertEqual(first.rename(.session("s1"), to: "shop 🛒"), "shop 🛒")
        XCTAssertEqual(first.rename(.teammate("a1"), to: "Scout"), "Scout")
        XCTAssertNil(first.rename(.session("s1"), to: String(repeating: "a", count: 33)))

        let again = model(in: place)
        XCTAssertEqual(again.office.nicknames.folders, [project: "shop 🛒"])
        XCTAssertEqual(again.office.nicknames.agents, ["Explore": "Scout"])
        office(again)
        XCTAssertEqual(again.office.session("s1")?.label, "shop 🛒")
        XCTAssertEqual(again.office.teammate("a1")?.teammate.label, "Scout")
        XCTAssertEqual(again.office.session("s1")?.name, "my-project", "the look keeps the folder's name")

        again.forgetNicknames()
        XCTAssertEqual(model(in: place).office.nicknames, Nicknames())
        let text = try String(contentsOfFile: place + "/config.json", encoding: .utf8)
        XCTAssertFalse(text.contains("Scout"))
    }

    /// A config.json edited outside the app still opens: the start command and folders stay, and only the
    /// nicknames that would not have passed are dropped.
    func testAStrangeConfigFileStillOpens() throws {
        let place = folder()
        let config = """
            {"start": {"folder": "\(project)", "run": ["claude"]}, "desks": ["\(project)"],
             "nicknames": {"folders": {"\(project)": "shop", "/w/long": "\(String(repeating: "x", count: 40))",
                                       "/w/hidden": "a\\u2066b", "/w/number": 7},
                           "agents": {"Explore": ["not", "text"], "Plan": "Planner"}}}
            """
        try Data(config.utf8).write(to: URL(fileURLWithPath: place + "/config.json"))
        let opened = model(in: place)
        XCTAssertEqual(opened.start?.folder, project)
        XCTAssertEqual(opened.office.folders, [project])
        XCTAssertEqual(opened.office.nicknames.folders, [project: "shop"])
        XCTAssertEqual(opened.office.nicknames.agents, ["Plan": "Planner"])

        try Data(#"{"start": {"folder": "/x", "run": ["claude"]}, "desks": [], "nicknames": "nonsense"}"#.utf8)
            .write(to: URL(fileURLWithPath: place + "/config.json"))
        let nonsense = model(in: place)
        XCTAssertEqual(nonsense.start?.folder, "/x", "the rest of the file is still read")
        XCTAssertEqual(nonsense.office.nicknames, Nicknames())
    }

    /// "What they're doing now": one of six fixed phrases, only while working; a kind the app doesn't know shows
    /// nothing, and nothing received is ever shown.
    func testNowIsAFixedPhraseOnlyWhileWorking() throws {
        let model = model(in: folder())
        office(model)
        model.receive(HookEvent(kind: .preToolUse, session: "s1", cwd: project, toolKind: .edit), at: t0 + 6)
        XCTAssertEqual(SidePanel.doing(.session("s1"), in: model.office), .edit)
        let spoken = try XCTUnwrap(SidePanel.spoken(.session("s1"), in: model.office, now: t0 + 7))
        XCTAssertTrue(spoken.hasSuffix(HookEvent.ToolKind.edit.spoken + ", " + TimeSpan.just.lastingSpoken), spoken)
        model.receive(HookEvent(kind: .preToolUse, session: "s1", cwd: project, toolKind: .edit), at: t0 + 7)
        XCTAssertEqual(model.office.toolSince(session: "s1"), t0 + 6, "still that work")
        let later = try XCTUnwrap(SidePanel.spoken(.session("s1"), in: model.office, now: t0 + 6 + 180))
        XCTAssertTrue(later.hasSuffix(TimeSpan.minutes(3).lastingSpoken), later)
        XCTAssertEqual(SidePanel.doing(.teammate("a1"), in: model.office), nil, "a1 sent no kind")

        model.receive(HookEvent(kind: .permissionRequest, session: "s1", cwd: project), at: t0 + 8)
        XCTAssertNil(SidePanel.doing(.session("s1"), in: model.office), "only while working")
        model.receive(HookEvent(kind: .stop, session: "s1", cwd: project), at: t0 + 9)
        XCTAssertNil(SidePanel.doing(.session("s1"), in: model.office))

        let line = Data(#"{"e":"PreToolUse","s":"s1","d":"\#(project)","k":"Bash: rm -rf ~/"}"#.utf8)
        model.receive(try XCTUnwrap(HookEvent.fromWire(line)), at: t0 + 10)
        XCTAssertEqual(model.office.session("s1")?.state, .working)
        XCTAssertNil(SidePanel.doing(.session("s1"), in: model.office), "an unknown kind shows no line")

        let phrases = HookEvent.ToolKind.allCases.map(\.spoken)
        XCTAssertEqual(Set(phrases).count, 6)
        for phrase in phrases { XCTAssertFalse(phrase.contains("rm"), phrase) }
    }

    /// A session found on this Mac before any news: "Quiet" with no time, VoiceOver hears the same, and nothing
    /// is saved until its first news, which remembers its folder.
    func testAQuietSessionIsNotSavedUntilItsNews() throws {
        let place = folder()
        let model = model(in: place)
        model.receive(found: [OfficeState.Found(pid: 4242, started: t0, folder: project, busy: false)], at: t0)
        let id = try XCTUnwrap(model.office.desks.first?.sessions.first?.id)
        XCTAssertEqual(
            SidePanel.spoken(.session(id), in: model.office, now: t0 + 600), "my-project, " + WorkState.quiet.spoken)
        XCTAssertFalse(FileManager.default.fileExists(atPath: place + "/config.json"), "nothing saved")

        model.receive(HookEvent(kind: .userPromptSubmit, session: "s1", cwd: project, pid: 4242), at: t0 + 700)
        XCTAssertEqual(model.office.session(id)?.state, .working, "the same person, at work")
        XCTAssertEqual(model.office.liveSessionCount, 1)
        let saved = try String(contentsOfFile: place + "/config.json", encoding: .utf8)
        XCTAssertTrue(saved.contains(project), saved)
    }

    /// No seconds on the panel: under a minute is "just", then minutes, then hours.
    func testTimeWordsHaveNoSeconds() {
        let cases: [(TimeInterval, TimeSpan)] = [
            (0, .just), (59, .just), (60, .minutes(1)), (59 * 60, .minutes(59)), (60 * 60, .hours(1)),
            (3 * 3600 + 59 * 60, .hours(3)), (-5, .just),
        ]
        for (seconds, span) in cases { XCTAssertEqual(TimeSpan(from: t0, to: t0 + seconds), span, "\(seconds) s") }
        // Localized texts don't compare equal; their description carries the words.
        XCTAssertTrue(String(describing: TimeSpan.just.lasting).contains("\"Just started\""))
        XCTAssertTrue(String(describing: TimeSpan.minutes(2).lasting).contains("\"2 min\""))
        XCTAssertTrue(String(describing: TimeSpan.hours(1).lasting).contains("\"1 h\""))
        XCTAssertTrue(String(describing: TimeSpan.just.ago).contains("\"Just now\""))
        XCTAssertTrue(String(describing: TimeSpan.minutes(3).ago).contains("\"3 min ago\""))
        XCTAssertTrue(String(describing: TimeSpan.hours(1).ago).contains("\"1 h ago\""))
    }

    /// The panel's state badges read at 4.5:1 or more, light and dark: the word on its own fill, Quiet's on the
    /// panel's background.
    func testStateBadgesKeepTheirContrast() throws {
        func luminance(_ color: NSColor) throws -> Double {
            let c = try XCTUnwrap(color.usingColorSpace(.sRGB))
            let channel = { (v: CGFloat) -> Double in
                let v = Double(v)
                return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(c.redComponent) + 0.7152 * channel(c.greenComponent)
                + 0.0722 * channel(c.blueComponent)
        }
        var lines: [String] = []
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            try XCTUnwrap(NSAppearance(named: name)).performAsCurrentDrawingAppearance {
                for state in WorkState.allCases {
                    let badge = Style.badge(state)
                    let back = state == .quiet ? NSColor.windowBackgroundColor : badge.fill
                    guard let text = try? luminance(badge.text), let fill = try? luminance(back) else {
                        return XCTFail("\(state)")
                    }
                    let ratio = (max(text, fill) + 0.05) / (min(text, fill) + 0.05)
                    lines.append(String(format: "%@ %@ %.2f", name.rawValue, state.rawValue, ratio))
                    XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(name.rawValue) \(state)")
                }
            }
        }
        print("Badge contrast: " + lines.joined(separator: ", "))
    }

    /// In a meeting: only the teammates at it say so. One with headphones keeps working as it was, in the panel
    /// and to VoiceOver.
    func testOnlyTheTeammatesAtTheMeetingAreInIt() throws {
        let model = model(in: folder())
        model.receive(HookEvent(kind: .userPromptSubmit, session: "s1", cwd: project), at: t0)
        model.receive(
            HookEvent(kind: .subagentStart, session: "s1", cwd: project, agentID: "h1", agentType: "Explore"), at: t0)
        model.receive(HookEvent(kind: .preToolUse, session: "s1", cwd: project, toolKind: .edit), at: t0 + 1)
        for id in ["p1", "p2"] {
            model.receive(
                HookEvent(kind: .subagentStart, session: "s1", cwd: project, agentID: id, agentType: "Plan"), at: t0 + 2
            )
        }
        model.advanceMeetings(to: t0 + 60)
        let session = try XCTUnwrap(model.office.session("s1"))
        XCTAssertTrue(session.meets)
        XCTAssertEqual(session.direct.count, 2, "the name tag says 2 teammates, not 3")
        let meeting = String(localized: "In a meeting")
        let away = try XCTUnwrap(SidePanel.spoken(.teammate("h1"), in: model.office, now: t0 + 60))
        XCTAssertFalse(away.contains(meeting), away)
        XCTAssertTrue(away.contains(WorkState.working.spoken), away)
        let met = try XCTUnwrap(SidePanel.spoken(.teammate("p1"), in: model.office, now: t0 + 60))
        XCTAssertTrue(met.contains(meeting), met)
    }
}
