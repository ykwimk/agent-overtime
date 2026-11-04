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
