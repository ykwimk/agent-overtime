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
        XCTAssertEqual(model.office.desks.map(\.name), ["my-project", "web-app", "blog", "prototype"])
        XCTAssertEqual(model.office.count(.working), 1)
        XCTAssertEqual(model.office.count(.waiting), 2)
        XCTAssertEqual(model.office.count(.resting), 1)
        XCTAssertTrue(model.office.desks[3].isOff)
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
        for event in events[helper...] { model.receive(event, at: now - 200) }
        _ = stage.sync(model.office, width: width, now: now - walked, animate: !still)
        return (model, stage)
    }

    func testCaptureOffice() throws {
        for (time, hour) in [("day", 14), ("night", 22)] {
            let now = today(hour)
            let (model, stage) = scenario(at: now)
            try capture(
                "office-\(time)", size: OfficeView.defaultSize,
                OfficeView(fixedNow: now, stage: stage).environmentObject(model))
            let (small, smallStage) = scenario(at: now, still: true)
            try capture(
                "office-min-\(time)", size: OfficeView.minSize,
                OfficeView(fixedNow: now, stage: smallStage).environmentObject(small))
        }
        // The helper passing web-app on its way to blog: under the name tags, not over the seated heads.
        let (passing, passingStage) = scenario(at: today(14), walked: 1.5)
        try capture(
            "office-passing", size: OfficeView.defaultSize,
            OfficeView(fixedNow: today(14), stage: passingStage).environmentObject(passing))

        // Off duty: my-project's second session walks out; the door stands open as it gets there.
        let (leaving, leavingStage) = scenario(at: today(14), still: true)
        let width = Int(OfficeView.minSize.width) / RoomLayout.pointsPerPixel
        _ = leavingStage.sync(leaving.office, width: width, now: today(14) - 3, animate: true)
        leaving.receive(
            HookEvent(kind: .sessionEnd, session: "demo-b1", cwd: FakeScenario.root + "/my-project"),
            at: today(14) - 1.7)
        _ = leavingStage.sync(leaving.office, width: width, now: today(14) - 1.7, animate: true)
        try capture(
            "office-leaving", size: OfficeView.minSize,
            OfficeView(fixedNow: today(14), stage: leavingStage).environmentObject(leaving))

        // Reduce Motion takes the same path as animate: false: people appear at their desks at once.
        let (still, stillStage) = scenario(at: today(22), still: true)
        try capture(
            "office-reduce-motion", size: OfficeView.defaultSize,
            OfficeView(fixedNow: today(22), stage: stillStage).environmentObject(still))

        let empty = makeModel(connected: true)
        try capture(
            "office-empty", size: OfficeView.defaultSize, OfficeView(fixedNow: today(22)).environmentObject(empty))

        let crowd = makeModel(connected: true)
        for i in 0..<9 {
            let folder = FakeScenario.root + "/project-\(i + 1)"
            crowd.receive(HookEvent(kind: .userPromptSubmit, session: "crowd-\(i)", cwd: folder), at: today(14) - 300)
            if i % 3 == 1 {
                crowd.receive(
                    HookEvent(kind: .permissionRequest, session: "crowd-\(i)", cwd: folder), at: today(14) - 300)
            }
            for k in 0..<(i % 4) {
                crowd.receive(
                    HookEvent(
                        kind: .subagentStart, session: "crowd-\(i)", cwd: folder, agentID: "crowd-\(i)-\(k)",
                        agentType: ["Explore", "Plan", "code-reviewer"][k % 3]), at: today(14) - 300)
            }
        }
        try capture(
            "office-many", size: OfficeView.defaultSize, OfficeView(fixedNow: today(14)).environmentObject(crowd))

        // Six desks went off duty, then a new folder: it takes the desk by the door. Five teammates, the fifth
        // without a desk ("+2") and waiting, which the summary and the main tag still count.
        let returning = makeModel(connected: true)
        let old = (1...6).map { FakeScenario.root + "/old-\($0)" }
        for kind in [HookEvent.Kind.sessionStart, .sessionEnd] {
            for folder in old { returning.receive(HookEvent(kind: kind, session: folder, cwd: folder), at: today(13)) }
        }
        let project = FakeScenario.root + "/my-project"
        returning.receive(HookEvent(kind: .userPromptSubmit, session: "new", cwd: project), at: today(14) - 300)
        for (k, type) in ["Explore", "Plan", "code-reviewer", "Explore", "Plan"].enumerated() {
            returning.receive(
                HookEvent(kind: .subagentStart, session: "new", cwd: project, agentID: "new-\(k)", agentType: type),
                at: today(14) - 300)
        }
        returning.receive(
            HookEvent(kind: .permissionRequest, session: "new", cwd: project, agentID: "new-4", agentType: "Plan"),
            at: today(14) - 200)
        XCTAssertEqual(returning.office.desks.first?.name, "my-project")
        XCTAssertEqual(returning.office.count(.waiting), 1)
        try capture(
            "office-new-session", size: OfficeView.defaultSize,
            OfficeView(fixedNow: today(14)).environmentObject(returning))
    }

    /// The README picture (copied by hand to docs/images/): the window a little taller than the default so the
    /// off-duty prototype desk shows too, and the helper already seated, so no name tag stands under an empty
    /// chair. Light by day, dark by night.
    func testCaptureReadme() throws {
        for (time, hour) in [("day", 14), ("night", 22)] {
            let (model, stage) = scenario(at: today(hour), still: true)
            try capture(
                "readme-\(time)", size: CGSize(width: OfficeView.defaultSize.width, height: 860),
                OfficeView(fixedNow: today(hour), stage: stage).environmentObject(model))
        }
    }

    /// One walking speed: the far desk of the default window is 4 to 5 seconds from the door.
    func testFarDeskWalkTakesFourToFiveSeconds() {
        let room = RoomLayout(points: OfficeView.defaultSize.width, podCount: 4)
        let seconds = Stage.length(room.route(pod: 3, desk: 3)) / Stage.speed
        XCTAssertTrue((4...5).contains(seconds), "\(seconds)")
    }

    /// Pods are not focusable (no focus ring) when the window opens, and Tab makes them so. A real, key window, as
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

    /// Four pods fit the default window under the real top bar, with no scrolling.
    func testDefaultWindowHoldsFourPods() {
        let model = makeModel(connected: true)
        let bar = NSHostingView(rootView: OfficeBar().environmentObject(model)).fittingSize.height + 1  // + divider
        let room = RoomLayout(points: OfficeView.defaultSize.width, podCount: 4)
        XCTAssertEqual(room.columns, 2)
        XCTAssertLessThanOrEqual(
            bar + CGFloat(room.contentHeight * RoomLayout.pointsPerPixel), OfficeView.defaultSize.height)
        let smallest = RoomLayout(points: OfficeView.minSize.width, podCount: 1)
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
    /// Code's own agents side by side: one name at desks 1 to 3, or different names at the same desk.
    func testExampleOfficeHasNoTwoSameHeads() {
        var office = OfficeState()
        for event in FakeScenario.events { office.apply(event, now: today(14)) }
        var plan = SeatPlan()
        var heads: [String] = []
        for pod in plan.pods(for: office) where !pod.isOff {
            heads.append("\(OfficeScene.mainLook(pod).hair)")
            for (index, mate) in pod.mates.enumerated() {
                if let mate { heads.append("\(OfficeScene.mateLook(mate, desk: index + 1).hair)") }
            }
        }
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

    /// The bitmap is twice as dense as the art, so the view shows one bitmap pixel per point: the room keeps
    /// its size on screen.
    func testOfficeBitmapIsOnePixelPerPoint() {
        let layout = RoomLayout(points: OfficeView.defaultSize.width, podCount: 4)
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
            let (pods, layout) = stage.sync(model.office, width: width, now: now, animate: true)
            let height = layout.contentHeight + 20
            let parts = stage.picture(at: now, frame: 3, height: height, reduceMotion: false)
            XCTAssertFalse(parts.walkers.isEmpty)
            let moment = stage.moment(at: now)
            let scene = OfficeScene(
                layout: layout, height: height, pods: pods,
                darkness: (Daylight.darkness(at: now) * 100).rounded() / 100,
                frame: 3, now: now, walkers: moment.walkers, away: moment.away, doorOpen: moment.doorOpen)
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

    /// At the walking frame rate a walker moves about 5 art pixels a frame and the six-picture walk advances at
    /// most one picture a frame, so the feet never skip a step.
    func testWalkAtItsFrameRateMovesInSmallSteps() throws {
        let now = today(14)
        let (_, stage) = scenario(at: now, walked: 0)
        let rate = OfficePicture.walkingFrameRate
        var frames = 0
        var last: Walker?
        while let walker = stage.moment(at: now + Double(frames) / rate).walkers.first {
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

    /// Four pods, every desk working, the window on screen and ticking: how much CPU the office takes.
    func testCPUWithFourPodsWorking() throws {
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
        window.contentView = NSHostingView(rootView: OfficeView(ticksWhileHidden: true).environmentObject(model))
        window.orderFrontRegardless()
        defer { window.close() }
        RunLoop.main.run(until: Date() + 3)

        let total = percent(over: 10)
        let visible = window.occlusionState.contains(.visible)
        // The far desk's teammate leaves: 4.7 s of walking to the door, drawn 30 times a second.
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
        window.close()

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
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let locked = session?["CGSSessionScreenIsLocked"] as? Bool ?? false
        let asleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0

        // One picture on its own, to tell drawing from SwiftUI's share.
        var plan = SeatPlan()
        let scene = OfficeScene(
            layout: RoomLayout(points: OfficeView.defaultSize.width, podCount: 4), height: 320,
            pods: plan.pods(for: model.office), darkness: 1, frame: 3, now: Date())
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
                "CPU, 4 pods x 4 desks working (window visible=%@, locked=%@, display asleep=%@): still: office %.2f%% "
                + "(process %.2f%% - idle %.2f%%); walking: office %.2f%%; reduce motion: office %.2f%%; "
                + "one picture: night %.2f ms, day %.2f ms; one walker box: night %.2f ms\n",
            "\(visible)", "\(locked)", "\(asleep)", office, total, idle, walking, reduced, renderMs, dayMs, boxMs)
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
