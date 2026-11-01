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
        while model.office.desks.count < 4 || model.office.liveSessionCount < 4, Date() < deadline {
            RunLoop.main.run(until: Date() + 0.05)
        }
        XCTAssertEqual(model.office.desks.map(\.name), ["web-shop", "agent-overtime", "blog", "prototype"])
        XCTAssertEqual(model.office.count(.working), 1)
        XCTAssertEqual(model.office.count(.waiting), 2)
        XCTAssertEqual(model.office.count(.resting), 1)
        XCTAssertTrue(model.office.desks[3].isOff)
        XCTAssertEqual(model.office.desks[0].teammates.map(\.state), [.working, .waiting, .resting])
        XCTAssertTrue(model.everConnected)

        let later = Date() + 200  // so "Waiting · 3 min" shows
        try capture(
            "office-default", size: OfficeView.defaultSize, OfficeView(fixedNow: later).environmentObject(model))
        try capture("office-min", size: OfficeView.minSize, OfficeView(fixedNow: later).environmentObject(model))
        try capture("menu", MenuContent(fixedNow: later).environmentObject(model))
        try capture("menubar-icon", MenuBarLabel(model: model).padding(6))
        try capture(
            "start-register",
            StartSheet(
                sheet: .register, initial: StartCommand(folder: FakeScenario.root + "/web-shop", run: ["claude"])
            )
            .environmentObject(model))
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
        let configured = makeModel(connected: true, start: StartCommand(folder: project, run: ["./start.sh"]))
        try capture("settings", SettingsView().environmentObject(configured))
        // A pasted config with a zero-width space: the confirmation shows it.
        try capture(
            "start-confirm",
            StartSheet(sheet: .confirm(StartCommand(folder: project, run: ["./start.sh", "--watch\u{200B}"])))
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
            event, HookEvent(kind: .preToolUse, session: "helper-test", cwd: "/Users/demo/work/shop", pid: getpid()),
            "only state fields, and the parent process as the session")
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
}
