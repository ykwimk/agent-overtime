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
        let route = UpdateRoute.homebrew(
            HomebrewRoute(
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
                }))
        let model = AppModel(supportFolder: folder, socketPath: socket, defaults: defaults, route: route)
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

/// Update on the app's own way, with everything outside the model replaced: nothing here touches a real app.
@MainActor
final class SelfUpdateModelTests: XCTestCase {
    private final class Fake {
        var log: [String] = []
        var preparing: UpdateFailure?
        var swapWorks = true
        var opens = true
        var listens = true
        var socket = ""
        var socketGoneAtOpen = false
    }

    private let version = ReleaseVersion(tag: "v99.0.0")!

    private func model(
        _ fake: Fake, answer: UpdateCheck.Outcome? = nil, defaults: UserDefaults? = nil
    ) -> AppModel {
        let folder = (Paths.userTempFolder as NSString).appendingPathComponent("ao-su-\(UUID().uuidString.prefix(8))")
        fake.socket = folder + "/events.sock"
        let answer = answer ?? .newer(version)
        let defaults = defaults ?? UserDefaults(suiteName: "ao-su-\(UUID().uuidString)")!
        defaults.set(false, forKey: "findsSessions")
        defaults.set(false, forKey: "checksForUpdates")
        let route = UpdateRoute.selfUpdate(
            SelfUpdateRoute(
                prepare: { number, _ in
                    await MainActor.run { fake.log.append("prepare \(number.number)") }
                    return await MainActor.run { fake.preparing }
                },
                swap: {
                    fake.log.append("swap")
                    return fake.swapWorks
                },
                removeCopy: { fake.log.append("remove") },
                open: { completion in
                    fake.log.append("open")
                    fake.socketGoneAtOpen = !FileManager.default.fileExists(atPath: fake.socket)
                    if !fake.opens { completion(nil) }
                },
                isListening: { fake.listens },
                quit: { fake.log.append("quit") },
                patience: 0.3))
        let model = AppModel(
            supportFolder: folder, socketPath: fake.socket, defaults: defaults, askLatest: { _ in answer },
            route: route)
        model.checksForUpdates = true
        model.receive(update: .newer(version))
        return model
    }

    private func finish(_ model: AppModel) async {
        for _ in 0..<500 where model.updates.isDownloading {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testWhenTheNewAppTakesTheSocketTheOldOneGoes() async {
        let fake = Fake()
        let model = model(fake)
        model.listen()
        fake.log = []
        model.startUpdate(version)
        XCTAssertTrue(model.updates.isDownloading)
        await finish(model)
        XCTAssertEqual(fake.log, ["prepare 99.0.0", "swap", "open", "remove", "quit"])
        XCTAssertTrue(fake.socketGoneAtOpen, "let go of before the new app opens")
        XCTAssertNil(model.updates.shownFailure)
    }

    func testIfTheNewAppNeverTakesTheSocketTheOldOneComesBack() async {
        let fake = Fake()
        fake.listens = false
        let model = model(fake)
        model.listen()
        fake.log = []
        model.startUpdate(version)
        await finish(model)
        XCTAssertEqual(fake.log, ["prepare 99.0.0", "swap", "open", "swap", "remove"], "swapped back, no quit")
        XCTAssertEqual(model.updates.shownFailure, .install)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fake.socket), "listening again")
    }

    func testIfTheNewAppWontOpenTheOldOneComesBackAtOnce() async {
        let fake = Fake()
        fake.opens = false
        let model = model(fake)
        model.startUpdate(version)
        await finish(model)
        XCTAssertEqual(fake.log, ["prepare 99.0.0", "swap", "open", "swap", "remove"])
        XCTAssertEqual(model.updates.shownFailure, .install)
    }

    func testIfSwappingBackFailsNothingIsDeleted() async {
        final class Swaps {
            var count = 0
        }
        let fake = Fake()
        fake.listens = false
        let swaps = Swaps()
        let folder = (Paths.userTempFolder as NSString).appendingPathComponent("ao-su-\(UUID().uuidString.prefix(8))")
        let defaults = UserDefaults(suiteName: "ao-su-\(UUID().uuidString)")!
        let number = version
        let model = AppModel(
            supportFolder: folder, socketPath: folder + "/events.sock", defaults: defaults,
            askLatest: { _ in .newer(number) },
            route: .selfUpdate(
                SelfUpdateRoute(
                    prepare: { _, _ in nil },
                    swap: {
                        swaps.count += 1
                        return swaps.count == 1
                    },
                    removeCopy: { fake.log.append("remove") }, open: { _ in }, isListening: { false },
                    quit: { fake.log.append("quit") }, patience: 0.1)))
        model.receive(update: .newer(version))
        model.startUpdate(version)
        await finish(model)
        XCTAssertEqual(swaps.count, 2)
        XCTAssertEqual(fake.log, [], "the old app stays beside the new one, for the next launch")
    }

    func testAFailedSwapChangesNothing() async {
        let fake = Fake()
        fake.swapWorks = false
        let model = model(fake)
        model.listen()
        fake.log = []
        model.startUpdate(version)
        await finish(model)
        XCTAssertEqual(fake.log, ["prepare 99.0.0", "swap", "remove"])
        XCTAssertEqual(model.updates.shownFailure, .install)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fake.socket), "it never let go")
    }

    func testAFailedPreparationStopsThere() async {
        let fake = Fake()
        fake.preparing = .unverified
        let model = model(fake)
        model.startUpdate(version)
        await finish(model)
        XCTAssertEqual(fake.log, ["prepare 99.0.0"])
        XCTAssertEqual(model.updates.shownFailure, .unverified)

        model.startUpdate(version)
        await finish(model)
        XCTAssertEqual(fake.log, ["prepare 99.0.0"], "that number isn't tried again in this run")
    }

    func testASecondPressDoesNothing() async {
        let fake = Fake()
        let model = model(fake)
        model.startUpdate(version)
        model.startUpdate(version)
        await finish(model)
        XCTAssertEqual(fake.log.filter { $0.hasPrefix("prepare") }.count, 1)
    }

    func testAReleaseWithdrawnSinceTheLineAppearedIsNotFetched() async {
        let fake = Fake()
        let model = model(fake, answer: .upToDate)
        model.startUpdate(version)
        await finish(model)
        XCTAssertEqual(fake.log, [])
        XCTAssertNil(model.updates.newVersion, "the line goes too")
        XCTAssertNil(model.updates.shownFailure)
    }

    func testALowerAnswerIsNotFetchedAndTheLineShowsIt() async {
        let fake = Fake()
        let lower = ReleaseVersion(tag: "v98.0.0")!
        let model = model(fake, answer: .newer(lower))
        model.startUpdate(version)
        await finish(model)
        XCTAssertEqual(fake.log, [])
        XCTAssertEqual(model.updates.newVersion, lower)
    }

    func testAHigherAnswerIsWhatGetsFetched() async {
        let fake = Fake()
        let model = model(fake, answer: .newer(ReleaseVersion(tag: "v99.0.1")!))
        model.startUpdate(version)
        await finish(model)
        XCTAssertEqual(fake.log.first, "prepare 99.0.1")
    }

    func testNoAnswerAtThePressIsANetworkFailure() async {
        let fake = Fake()
        let model = model(fake, answer: .failed)
        model.startUpdate(version)
        await finish(model)
        XCTAssertEqual(fake.log, [])
        XCTAssertEqual(model.updates.shownFailure, .network)
        XCTAssertEqual(model.updates.newVersion, version, "try again stays possible")
    }

    func testListeningClearsWhatAnUpdateLeftBehind() {
        let fake = Fake()
        let model = model(fake)
        fake.log = []
        model.listen()
        XCTAssertEqual(fake.log, ["remove"])
    }

    func testAnOlderLastRunShowsTheUpdatedLineOnce() {
        let defaults = UserDefaults(suiteName: "ao-su-\(UUID().uuidString)")!
        defaults.set("v0.0.1", forKey: "lastRunVersion")
        let first = model(Fake(), defaults: defaults)
        XCTAssertEqual(first.justUpdated?.tag, Release.tag)
        let second = model(Fake(), defaults: defaults)
        XCTAssertNil(second.justUpdated, "the same version again")
    }

    func testAFirstRunShowsNoUpdatedLine() {
        XCTAssertNil(model(Fake()).justUpdated)
    }
}
