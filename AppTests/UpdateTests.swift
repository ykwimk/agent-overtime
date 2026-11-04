import XCTest

@testable import AgentOvertime

/// The update check as the app runs it, with the question to GitHub replaced: nothing here reaches the network.
@MainActor
final class UpdateTests: XCTestCase {
    private actor Asked {
        var count = 0
        func add() { count += 1 }
    }

    private let newer = UpdateCheck.Outcome.newer(ReleaseVersion(tag: "v99.0.0")!)

    private func model(on: Bool?, answer: UpdateCheck.Outcome, asked: Asked) -> AppModel {
        let folder = (Paths.userTempFolder as NSString).appendingPathComponent("ao-up-\(UUID().uuidString.prefix(8))")
        let defaults = UserDefaults(suiteName: "ao-up-\(UUID().uuidString)")!
        defaults.set(false, forKey: "findsSessions")
        if let on { defaults.set(on, forKey: "checksForUpdates") }
        return AppModel(
            supportFolder: folder, socketPath: folder + "/events.sock", defaults: defaults,
            askLatest: { _ in
                await asked.add()
                return answer
            })
    }

    /// Lets the task the model started finish.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    func testOffAsksNothingFromOpeningOnward() async {
        let asked = Asked()
        let model = model(on: false, answer: newer, asked: asked)
        model.listen()
        model.askForUpdate(at: Date() + 2 * UpdateState.interval)
        await settle()
        let count = await asked.count
        XCTAssertEqual(count, 0)
        XCTAssertNil(model.updates.newVersion)
    }

    func testOnByDefaultAsksOnceWhenTheAppOpens() async {
        let asked = Asked()
        let model = model(on: nil, answer: newer, asked: asked)
        XCTAssertTrue(model.checksForUpdates)
        model.listen()
        model.askForUpdate()
        await settle()
        let count = await asked.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(model.updates.newVersion?.tag, "v99.0.0")
        XCTAssertNotNil(model.updates.lastChecked)
    }

    func testATickWithNothingDueRedrawsNothing() async {
        let model = model(on: nil, answer: .upToDate, asked: Asked())
        model.listen()
        await settle()
        var changes = 0
        let watching = model.objectWillChange.sink { changes += 1 }
        for _ in 0..<3 { model.askForUpdate() }
        XCTAssertEqual(changes, 0)
        watching.cancel()
    }

    func testAModelThatIsNotListeningNeverAsks() async {
        let asked = Asked()
        let model = model(on: true, answer: newer, asked: asked)
        model.askForUpdate()
        model.checksForUpdates = false
        model.checksForUpdates = true
        await settle()
        let count = await asked.count
        XCTAssertEqual(count, 0)
    }

    func testSwitchTurnsTheBarOffAndAsksWhenTurnedOn() async {
        let asked = Asked()
        let model = model(on: false, answer: newer, asked: asked)
        model.listen()
        model.checksForUpdates = true
        await settle()
        var count = await asked.count
        XCTAssertEqual(count, 1)
        XCTAssertNotNil(model.updates.newVersion)
        model.checksForUpdates = false
        XCTAssertNil(model.updates.newVersion)
        model.checksForUpdates = true
        await settle()
        count = await asked.count
        XCTAssertEqual(count, 1, "answered a moment ago: no second question")
    }
}

/// Update through Homebrew with Terminal, the app on disk and quitting all replaced.
@MainActor
final class HomebrewUpdateModelTests: XCTestCase {
    private final class Fake {
        var terminals = 0
        var terminalError: Error?
        var installed: ReleaseVersion?
        var reopens = 0
        var reopenWorks = true
        var socketThereAtReopen: Bool?
    }

    private let version = ReleaseVersion(tag: "v99.0.0")!
    private let start = Date()

    private func model(_ fake: Fake) -> AppModel {
        let folder = (Paths.userTempFolder as NSString).appendingPathComponent("ao-hb-\(UUID().uuidString.prefix(8))")
        let socket = folder + "/events.sock"
        let defaults = UserDefaults(suiteName: "ao-hb-\(UUID().uuidString)")!
        defaults.set(false, forKey: "findsSessions")
        defaults.set(false, forKey: "checksForUpdates")
        let route = HomebrewRoute(
            openTerminal: { completion in
                fake.terminals += 1
                let error = fake.terminalError
                Task { @MainActor in completion(error) }
            },
            installedVersion: { fake.installed },
            reopen: {
                fake.reopens += 1
                fake.socketThereAtReopen = FileManager.default.fileExists(atPath: socket)
                return fake.reopenWorks
            })
        let model = AppModel(supportFolder: folder, socketPath: socket, defaults: defaults, homebrew: route)
        model.checksForUpdates = true
        model.receive(update: .newer(version))
        return model
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    func testPressOpensTerminalOnceAndASecondPressDoesNothing() {
        let fake = Fake()
        let model = model(fake)
        model.startUpdate(version)
        model.startUpdate(version)
        XCTAssertEqual(fake.terminals, 1)
        XCTAssertTrue(model.updates.isInTerminal)
    }

    func testTerminalThatWontOpenGoesBackToNewVersion() async {
        let fake = Fake()
        fake.terminalError = CocoaError(.fileNoSuchFile)
        let model = model(fake)
        model.startUpdate(version)
        await settle()
        XCTAssertFalse(model.updates.isInTerminal)
        XCTAssertEqual(model.updates.newVersion, version)
    }

    func testNoChangeOnDiskGoesBackAfterFiveMinutes() {
        let fake = Fake()
        let model = model(fake)
        let pressed = Date()
        model.startUpdate(version)
        model.followUpdate(at: pressed + 60)
        XCTAssertTrue(model.updates.isInTerminal)
        model.followUpdate(at: pressed + 400)
        XCTAssertFalse(model.updates.isInTerminal)
        XCTAssertEqual(fake.reopens, 0)
    }

    func testReopensWhenTheNewAppHasSettledAndLetsGoOfTheSocketFirst() {
        let fake = Fake()
        let model = model(fake)
        model.listen()
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.socketPath))
        model.startUpdate(version)
        fake.installed = version
        model.followUpdate(at: start + 5)
        XCTAssertEqual(fake.reopens, 0, "brew may still be at it")
        model.followUpdate(at: start + 10)
        XCTAssertEqual(fake.reopens, 1)
        XCTAssertEqual(fake.socketThereAtReopen, false, "gone before the new app opens")
    }

    func testIfReopeningFailsTheAppKeepsListening() {
        let fake = Fake()
        fake.reopenWorks = false
        let model = model(fake)
        model.listen()
        model.startUpdate(version)
        fake.installed = version
        model.followUpdate(at: start + 5)
        model.followUpdate(at: start + 10)
        XCTAssertEqual(fake.reopens, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.socketPath))
        XCTAssertFalse(model.updates.isInTerminal)
    }

    func testPressWithTheNewAppAlreadyOnDiskJustReopens() {
        let fake = Fake()
        fake.installed = version
        let model = model(fake)
        model.startUpdate(version)
        XCTAssertEqual(fake.reopens, 1)
        XCTAssertEqual(fake.terminals, 0)
    }

    func testNewNumberOnDiskWithoutAPressNeverReopens() {
        let fake = Fake()
        fake.installed = version
        let model = model(fake)
        model.followUpdate(at: start + 5)
        model.followUpdate(at: start + 10)
        XCTAssertEqual(fake.reopens, 0)
    }
}
