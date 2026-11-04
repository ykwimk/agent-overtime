import CryptoKit
import XCTest

@testable import AgentOvertimeCore

/// Serves a release's files by name instead of the network.
private final class FakeReleases: URLProtocol {
    enum Reply {
        case file(Data)
        case status(Int)
        case offline
    }

    static var replies: [String: Reply] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        func answer(_ status: Int, _ body: Data) {
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        switch Self.replies[url.lastPathComponent] ?? .offline {
        case .offline: client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        case .status(let status): answer(status, Data("nope".utf8))
        case .file(let data): answer(200, data)
        }
    }
}

private func runTool(_ path: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0, "\(path) \(arguments)")
}

/// The whole way up to the swap, with made-up releases in real disk images. The made-up apps are signed ad hoc here
/// so `codesign --verify` passes, and none of them is ever run.
final class SelfUpdateTests: XCTestCase {
    private let current = ReleaseVersion(tag: "v0.5.0")!
    private let version = ReleaseVersion(tag: "v0.5.1")!
    private let dmgName = "AgentOvertime-0.5.1.dmg"
    private let sigName = "AgentOvertime-0.5.1.dmg.sig"
    private static let key = Curve25519.Signing.PrivateKey()
    private static var goodImage: Data?

    /// A folder with no link on its way: `AppPlace` refuses those, and /var/folders is one.
    private func folder() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ao-self-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return try XCTUnwrap(realpath(url.path, nil).map { String(cString: $0) })
    }

    private func makeApp(
        at path: String, identifier: String = "io.github.ykwimk.AgentOvertime", number: String = "0.5.1",
        executable: String = "AgentOvertime", minimum: String = "13.0", hook: Bool = true, signed: Bool = true
    ) throws {
        let programs = path + "/Contents/MacOS"
        try FileManager.default.createDirectory(atPath: programs, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": identifier, "CFBundleShortVersionString": number, "CFBundleExecutable": executable,
            "LSMinimumSystemVersion": minimum, "CFBundlePackageType": "APPL",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(
            to: URL(fileURLWithPath: path + "/Contents/Info.plist"))
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: programs + "/" + executable)
        if hook { try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: programs + "/agent-overtime-hook") }
        guard signed else { return }
        if hook { try runTool("/usr/bin/codesign", ["--force", "--sign", "-", programs + "/agent-overtime-hook"]) }
        try runTool("/usr/bin/codesign", ["--force", "--sign", "-", path])
    }

    private func image(_ fill: (String) throws -> Void) throws -> Data {
        let work = try folder()
        let source = work + "/source"
        try FileManager.default.createDirectory(atPath: source, withIntermediateDirectories: true)
        try fill(source)
        let dmg = work + "/out.dmg"
        try runTool(
            "/usr/bin/hdiutil", ["create", "-quiet", "-volname", "Test", "-srcfolder", source, "-format", "UDZO", dmg])
        return try Data(contentsOf: URL(fileURLWithPath: dmg))
    }

    private func goodImage() throws -> Data {
        if let image = Self.goodImage { return image }
        let made = try image { try makeApp(at: $0 + "/AgentOvertime.app") }
        Self.goodImage = made
        return made
    }

    private func signature(
        of dmg: Data, number: String = "0.5.1", key: Curve25519.Signing.PrivateKey = SelfUpdateTests.key
    ) throws -> Data {
        let hash = SHA256.hash(data: dmg).map { String(format: "%02x", $0) }.joined()
        return try key.signature(for: Data("agent-overtime \(number) \(hash)".utf8))
    }

    private struct Stage {
        let update: SelfUpdate
        let place: AppPlace
        let temp: String
    }

    /// An app at 0.5.0 in a folder of its own, and an update aimed at it.
    private func stage() throws -> Stage {
        let home = try folder()
        let temp = home + "/temp"
        try FileManager.default.createDirectory(atPath: temp, withIntermediateDirectories: true)
        let bundle = home + "/AgentOvertime.app"
        try makeApp(at: bundle, number: "0.5.0", signed: false)
        let place = try XCTUnwrap(AppPlace(checking: bundle))
        let update = SelfUpdate(
            place: place, publicKey: Self.key.publicKey.rawRepresentation, tempRoot: temp,
            configuration: {
                let configuration = UpdateCheck.downloadConfiguration
                configuration.protocolClasses = [FakeReleases.self]
                return configuration
            })
        return Stage(update: update, place: place, temp: temp)
    }

    private func number(_ bundle: String) -> String? {
        HomebrewUpdate.installedVersion(bundlePath: bundle)?.number
    }

    /// The failure of one try, after checking it left everything as it was.
    private func failure(dmg: FakeReleases.Reply, sig: FakeReleases.Reply) async throws -> UpdateFailure? {
        FakeReleases.replies = [dmgName: dmg, sigName: sig]
        let stage = try stage()
        let failure = await stage.update.prepare(version, current: current)
        XCTAssertEqual(number(stage.place.bundle), "0.5.0", "the app stays")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.place.copy), "no copy left")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: stage.temp), [], "no temporary files")
        return failure
    }

    func testAGoodReleaseLeavesACheckedCopyThenSwapsBothWays() async throws {
        let dmg = try goodImage()
        FakeReleases.replies = [dmgName: .file(dmg), sigName: .file(try signature(of: dmg))]
        let stage = try stage()
        let failure = await stage.update.prepare(version, current: current)
        XCTAssertNil(failure)
        XCTAssertEqual(number(stage.place.copy), "0.5.1")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: stage.temp), [], "nothing left in temp")

        XCTAssertTrue(stage.place.swap())
        XCTAssertEqual(number(stage.place.bundle), "0.5.1")
        XCTAssertEqual(number(stage.place.copy), "0.5.0", "the old app waits beside it")
        XCTAssertTrue(stage.place.swap(), "the same call undoes it")
        XCTAssertEqual(number(stage.place.bundle), "0.5.0")

        stage.place.removeCopy()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.place.copy))
    }

    func testAnythingButAGoodSignatureStopsBeforeTheImageIsOpened() async throws {
        let dmg = try goodImage()
        let good = try signature(of: dmg)
        var changed = dmg
        changed[changed.count / 2] ^= 1

        let cases: [(String, Data, Data)] = [
            ("one byte changed", changed, good),
            ("another key", dmg, try signature(of: dmg, key: Curve25519.Signing.PrivateKey())),
            ("another version's line", dmg, try signature(of: dmg, number: "0.5.2")),
            ("empty", dmg, Data()),
            ("one byte too long", dmg, good + Data([0])),
            ("way too long", dmg, Data(repeating: 1, count: 2048)),
        ]
        for (name, file, proof) in cases {
            let outcome = try await failure(dmg: .file(file), sig: .file(proof))
            XCTAssertEqual(outcome, .unverified, name)
        }
    }

    func testABrokenPackageStopsEvenWithAGoodSignature() async throws {
        let app = "/AgentOvertime.app"
        let cases: [(String, (String) throws -> Void)] = [
            (
                "two apps",
                {
                    try self.makeApp(at: $0 + app)
                    try self.makeApp(at: $0 + "/Other.app")
                }
            ),
            (
                "a link instead of the app",
                { source in
                    try self.makeApp(at: source + "/Real.app")
                    try FileManager.default.removeItem(atPath: source + "/Real.app")
                    try FileManager.default.createSymbolicLink(
                        atPath: source + app, withDestinationPath: "/Applications")
                }
            ),
            (
                "an app and a link",
                {
                    try self.makeApp(at: $0 + app)
                    try FileManager.default.createSymbolicLink(
                        atPath: $0 + "/Applications", withDestinationPath: "/Applications")
                }
            ),
            ("another identifier", { try self.makeApp(at: $0 + app, identifier: "com.example.Other") }),
            ("a lower number", { try self.makeApp(at: $0 + app, number: "0.4.9") }),
            ("another number", { try self.makeApp(at: $0 + app, number: "0.5.2") }),
            ("another program name", { try self.makeApp(at: $0 + app, executable: "Other") }),
            ("no helper", { try self.makeApp(at: $0 + app, hook: false) }),
            ("not for this macOS", { try self.makeApp(at: $0 + app, minimum: "99.0") }),
            ("no code signature", { try self.makeApp(at: $0 + app, signed: false) }),
            (
                "changed after signing",
                { source in
                    try self.makeApp(at: source + app)
                    try Data([1]).write(to: URL(fileURLWithPath: source + app + "/Contents/added"))
                }
            ),
        ]
        for (name, fill) in cases {
            let dmg = try image(fill)
            let outcome = try await failure(dmg: .file(dmg), sig: .file(try signature(of: dmg)))
            XCTAssertEqual(outcome, .unverified, name)
        }
    }

    func testNotAReleaseImageAtAllFailsToOpen() async throws {
        let dmg = Data("not a disk image".utf8)
        let outcome = try await failure(dmg: .file(dmg), sig: .file(try signature(of: dmg)))
        XCTAssertEqual(outcome, .install)
    }

    func testFilesThatDontArriveAreANetworkFailureAndLeaveNothing() async throws {
        let dmg = try goodImage()
        let good = try signature(of: dmg)
        let offline = try await failure(dmg: .file(dmg), sig: .offline)
        XCTAssertEqual(offline, .network)
        let midway = try await failure(dmg: .offline, sig: .file(good))
        XCTAssertEqual(midway, .network, "the signature had already landed")
        let server = try await failure(dmg: .status(500), sig: .file(good))
        XCTAssertEqual(server, .network)
        let noDisk = try await failure(dmg: .status(404), sig: .file(good))
        XCTAssertEqual(noDisk, .network)
    }

    func testAReleaseWithoutItsSignatureOrThatRedirectsIsInDoubt() async throws {
        let dmg = try goodImage()
        let missing = try await failure(dmg: .file(dmg), sig: .status(404))
        XCTAssertEqual(missing, .unverified, "or the download page would lead to the unsigned file")
        let redirect = try await failure(dmg: .status(302), sig: .file(try signature(of: dmg)))
        XCTAssertEqual(redirect, .unverified)
    }

    func testAUsedNameIsCleared() async throws {
        let dmg = try goodImage()
        FakeReleases.replies = [dmgName: .file(dmg), sigName: .file(try signature(of: dmg))]
        let stage = try stage()
        try makeApp(at: stage.place.copy, number: "0.4.0", signed: false)
        let failure = await stage.update.prepare(version, current: current)
        XCTAssertNil(failure)
        XCTAssertEqual(number(stage.place.copy), "0.5.1")
    }
}

final class ReleaseSignatureTests: XCTestCase {
    private let version = ReleaseVersion(tag: "v0.5.1")!

    func testTheLineSignedIsOneLineOfThisShape() {
        XCTAssertEqual(ReleaseSignature.line(version, sha256: "abc"), "agent-overtime 0.5.1 abc")
    }

    func testTheReleaseKeyIsAnEd25519Key() throws {
        let data = try XCTUnwrap(Data(base64Encoded: ReleaseSignature.publicKey))
        XCTAssertEqual(data.count, 32)
        XCTAssertNoThrow(try Curve25519.Signing.PublicKey(rawRepresentation: data))
    }

    func testChecksAgainstTheHashOfTheFileItself() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ao-sig-\(UUID().uuidString)")
        try Data("a release".utf8).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let hash = SHA256.hash(data: Data("a release".utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try ReleaseSignature.sha256(of: file), hash)

        let key = Curve25519.Signing.PrivateKey()
        let good = try key.signature(for: Data("agent-overtime 0.5.1 \(hash)".utf8))
        let raw = key.publicKey.rawRepresentation
        XCTAssertTrue(ReleaseSignature.isValid(signature: good, of: file, version: version, publicKey: raw))
        XCTAssertFalse(
            ReleaseSignature.isValid(
                signature: good, of: file, version: ReleaseVersion(tag: "v0.5.2")!, publicKey: raw))
        XCTAssertFalse(ReleaseSignature.isValid(signature: Data(), of: file, version: version, publicKey: raw))
        XCTAssertFalse(ReleaseSignature.isValid(signature: good + [0], of: file, version: version, publicKey: raw))
        XCTAssertFalse(
            ReleaseSignature.isValid(signature: good, of: file, version: version, publicKey: Data(raw.dropLast())))
    }
}

final class ReleaseDownloadTests: XCTestCase {
    private let version = ReleaseVersion(tag: "v0.5.1")!

    func testAddressesAreBuiltFromTheNumbers() {
        XCTAssertEqual(
            UpdateCheck.assetURL(version, signature: false).absoluteString,
            "https://github.com/ykwimk/agent-overtime/releases/download/v0.5.1/AgentOvertime-0.5.1.dmg")
        XCTAssertEqual(
            UpdateCheck.assetURL(version, signature: true).absoluteString,
            "https://github.com/ykwimk/agent-overtime/releases/download/v0.5.1/AgentOvertime-0.5.1.dmg.sig")
    }

    func testLimitsAndTimes() {
        let asset = UpdateCheck.request(UpdateCheck.assetURL(version, signature: false), current: version)
        XCTAssertEqual(asset.allHTTPHeaderFields?.count, 3)
        XCTAssertFalse(asset.httpShouldHandleCookies)
        XCTAssertEqual(UpdateCheck.maxDMG, 64 * 1024 * 1024)
        XCTAssertEqual(UpdateCheck.maxSignature, 1024)
        XCTAssertEqual(UpdateCheck.downloadConfiguration.timeoutIntervalForRequest, 15)
        XCTAssertEqual(UpdateCheck.downloadConfiguration.timeoutIntervalForResource, 300)
        XCTAssertNil(UpdateCheck.downloadConfiguration.urlCache)
        XCTAssertNil(UpdateCheck.downloadConfiguration.httpCookieStorage)
        XCTAssertEqual(UpdateCheck.configuration.timeoutIntervalForResource, 30, "the check keeps its own limit")
    }

    func testRedirectsStayOnGitHubAndHttps() {
        func allows(_ address: String, after hops: Int = 1) -> Bool {
            UpdateCheck.allowsRedirect(to: URL(string: address), after: hops)
        }
        XCTAssertTrue(allows("https://github.com/a"))
        XCTAssertTrue(allows("https://release-assets.githubusercontent.com/a"))
        XCTAssertTrue(allows("https://objects.githubusercontent.com/a", after: 3))
        XCTAssertFalse(allows("https://objects.githubusercontent.com/a", after: 4), "three hops")
        XCTAssertFalse(allows("http://github.com/a"))
        XCTAssertFalse(allows("https://github.com.example.com/a"))
        XCTAssertFalse(allows("https://evilgithubusercontent.com/a"))
        XCTAssertFalse(allows("https://githubusercontent.com.evil.com/a"))
        XCTAssertFalse(allows("https://github.com:8443/a"))
        XCTAssertFalse(allows("https://user@github.com/a"))
        XCTAssertFalse(UpdateCheck.allowsRedirect(to: nil, after: 1))
    }

    func testSizeIsCountedWhileReceiving() {
        let file = URL(fileURLWithPath: "/nonexistent")
        let download = Download(to: file, limit: 100)
        let session = URLSession(configuration: .ephemeral)
        let task = session.downloadTask(with: UpdateCheck.latest)
        download.urlSession(
            session, downloadTask: task, didWriteData: 50, totalBytesWritten: 100, totalBytesExpectedToWrite: -1)
        XCTAssertEqual(task.state, .suspended, "at the limit it goes on")
        download.urlSession(
            session, downloadTask: task, didWriteData: 1, totalBytesWritten: 101, totalBytesExpectedToWrite: -1)
        XCTAssertNotEqual(task.state, .suspended, "cut off at once")
    }

    func testAFileOverTheLimitDoesNotLand() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ao-dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let name = UUID().uuidString
        FakeReleases.replies = [name: .file(Data(repeating: 1, count: 11))]
        let target = folder.appendingPathComponent("file")
        let configuration = UpdateCheck.downloadConfiguration
        configuration.protocolClasses = [FakeReleases.self]
        let url = URL(string: "https://github.com/\(name)")!
        do {
            try await UpdateCheck.download(url, to: target, limit: 10, current: version, configuration: configuration)
            XCTFail("over the limit")
        } catch {
            XCTAssertEqual(error as? UpdateCheck.DownloadFailure, .tooLong)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        try await UpdateCheck.download(url, to: target, limit: 11, current: version, configuration: configuration)
        XCTAssertEqual(try Data(contentsOf: target).count, 11)
    }
}

final class AppPlaceTests: XCTestCase {
    private func folder() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ao-place-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return try XCTUnwrap(realpath(url.path, nil).map { String(cString: $0) })
    }

    func testARealFolderOfThisUsersIsFine() throws {
        let home = try folder()
        let bundle = home + "/AgentOvertime.app"
        try FileManager.default.createDirectory(atPath: bundle, withIntermediateDirectories: true)
        let place = try XCTUnwrap(AppPlace(checking: bundle))
        XCTAssertEqual(place.copy, home + "/.AgentOvertime-update.app")
    }

    func testOnlyTheTwoApplicationsPlaces() throws {
        let bundle = try folder() + "/AgentOvertime.app"
        try FileManager.default.createDirectory(atPath: bundle, withIntermediateDirectories: true)
        XCTAssertNotNil(AppPlace(bundlePath: bundle, location: .ok))
        XCTAssertNil(AppPlace(bundlePath: bundle, location: .translocated))
        XCTAssertNil(AppPlace(bundlePath: bundle, location: .notInApplications))
    }

    func testLinksMissingAppsAndOtherOwnersAreRefused() throws {
        let home = try folder()
        let real = home + "/real"
        try FileManager.default.createDirectory(atPath: real + "/AgentOvertime.app", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: home + "/linked", withDestinationPath: real)
        try FileManager.default.createSymbolicLink(
            atPath: home + "/AgentOvertime.app", withDestinationPath: real + "/AgentOvertime.app")
        XCTAssertNil(AppPlace(checking: home + "/AgentOvertime.app"), "the app is a link")
        XCTAssertNil(AppPlace(checking: home + "/linked/AgentOvertime.app"), "a link on the way")
        XCTAssertNil(AppPlace(checking: home + "/none/AgentOvertime.app"))
        XCTAssertNil(AppPlace(checking: "/System/Applications/Calculator.app"), "not this user's")
        try Data().write(to: URL(fileURLWithPath: home + "/plain"))
        XCTAssertNil(AppPlace(checking: home + "/plain"))
    }

    func testRemoveCopyTakesOnlyARealFolderOfThatName() throws {
        let home = try folder()
        let bundle = home + "/AgentOvertime.app"
        let elsewhere = home + "/elsewhere"
        try FileManager.default.createDirectory(atPath: bundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
        let place = try XCTUnwrap(AppPlace(checking: bundle))

        place.removeCopy()  // nothing there: no complaint
        try FileManager.default.createSymbolicLink(atPath: place.copy, withDestinationPath: elsewhere)
        place.removeCopy()
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: place.copy), elsewhere, "a link is left alone")
        XCTAssertTrue(FileManager.default.fileExists(atPath: elsewhere))
        try FileManager.default.removeItem(atPath: place.copy)

        try FileManager.default.createDirectory(atPath: place.copy, withIntermediateDirectories: true)
        place.removeCopy()
        XCTAssertFalse(FileManager.default.fileExists(atPath: place.copy))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle), "the app stays")
    }

    func testSwapChecksThePlaceAgain() throws {
        let home = try folder()
        let bundle = home + "/AgentOvertime.app"
        try FileManager.default.createDirectory(atPath: bundle, withIntermediateDirectories: true)
        let place = try XCTUnwrap(AppPlace(checking: bundle))
        try FileManager.default.createDirectory(atPath: place.copy, withIntermediateDirectories: true)
        try FileManager.default.removeItem(atPath: bundle)
        try FileManager.default.createSymbolicLink(atPath: bundle, withDestinationPath: home)
        XCTAssertFalse(place.swap(), "the app became a link since launch")
        XCTAssertTrue(FileManager.default.fileExists(atPath: place.copy), "nothing moved")
    }

    func testSwapWithoutACopyFailsAndLeavesTheApp() throws {
        let bundle = try folder() + "/AgentOvertime.app"
        try FileManager.default.createDirectory(atPath: bundle, withIntermediateDirectories: true)
        let place = try XCTUnwrap(AppPlace(checking: bundle))
        XCTAssertFalse(place.swap())
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle))
    }
}

final class UpdateDownloadStateTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let newer = ReleaseVersion(tag: "v0.5.1")!

    private func available() -> UpdateState {
        var state = UpdateState(isOn: true, lastChecked: nil, now: start)
        state.finish(.newer(newer), at: start)
        return state
    }

    func testOnePressAtATimeAndOnlyWithANewVersion() {
        var none = UpdateState(isOn: true, lastChecked: nil, now: start)
        XCTAssertFalse(none.beginDownload())

        var state = available()
        XCTAssertTrue(state.beginDownload())
        XCTAssertFalse(state.beginDownload(), "a second press does nothing")
    }

    func testAFailedTryCanBeRetriedUnlessTheReleaseWasInDoubt() {
        for failure in [UpdateFailure.network, .install] {
            var state = available()
            _ = state.beginDownload()
            state.endDownload(failure)
            XCTAssertEqual(state.shownFailure, failure)
            XCTAssertEqual(state.newVersion, newer)
            XCTAssertTrue(state.beginDownload())
            XCTAssertNil(state.shownFailure)
        }
        var state = available()
        _ = state.beginDownload()
        state.endDownload(.unverified)
        XCTAssertFalse(state.beginDownload(), "no retry of that number in this run")
        XCTAssertEqual(state.shownFailure, .unverified)
    }

    func testTheSameNumberAgainKeepsTheRefusalAndANewOneClearsIt() {
        var state = available()
        _ = state.beginDownload()
        state.endDownload(.unverified)
        state.finish(.newer(newer), at: start + 60)
        XCTAssertFalse(state.beginDownload())
        state.finish(.newer(ReleaseVersion(tag: "v0.5.2")!), at: start + 120)
        XCTAssertNil(state.shownFailure)
        XCTAssertTrue(state.beginDownload())
    }

    func testAnAnswerOfNothingNewClearsIt() {
        var state = available()
        _ = state.beginDownload()
        state.endDownload(.network)
        state.finish(.upToDate, at: start + 60)
        XCTAssertNil(state.shownFailure)
        XCTAssertNil(state.newVersion)
    }

    func testOffHidesTheFailure() {
        var state = available()
        _ = state.beginDownload()
        state.endDownload(.network)
        state.turn(on: false)
        XCTAssertNil(state.shownFailure)
    }
}

/// What the update's source may and may not do.
final class SelfUpdateSourceTests: XCTestCase {
    private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    private let file = "Sources/AgentOvertimeCore/SelfUpdate.swift"

    private func sources() throws -> [String: String] {
        var all: [String: String] = [:]
        for folder in ["App", "Sources/AgentOvertimeCore", "Helper", "tools/fake-events"] {
            let url = repo.appendingPathComponent(folder)
            for name in try FileManager.default.contentsOfDirectory(atPath: url.path) where name.hasSuffix(".swift") {
                all[folder + "/" + name] = try String(contentsOf: url.appendingPathComponent(name), encoding: .utf8)
            }
        }
        return all
    }

    private func count(_ word: String, in text: String) -> Int { text.components(separatedBy: word).count - 1 }

    func testOneKeyOneSwapOneNameAndNothingFromOutside() throws {
        let all = try sources()
        let text = try XCTUnwrap(all[file])
        let keys = try NSRegularExpression(pattern: #""[A-Za-z0-9+/]{43}=""#)
        var found: [String] = []
        for (name, source) in all {
            found += keys.matches(in: source, range: NSRange(source.startIndex..., in: source)).map { _ in name }
            if name != file {
                XCTAssertFalse(source.contains("renamex_np"), name)
                XCTAssertFalse(source.contains("hdiutil"), name)
                XCTAssertFalse(source.contains(".AgentOvertime-update"), name)
            }
        }
        XCTAssertEqual(found, [file], "one key, in one place")
        XCTAssertEqual(count("renamex_np(", in: text), 1)
        XCTAssertTrue(text.contains("RENAME_SWAP | RENAME_NOFOLLOW_ANY"))
        for word in ["ProcessInfo.processInfo.environment", "getenv", "UserDefaults", "CFPreferences"] {
            XCTAssertFalse(text.contains(word), word)
        }
        XCTAssertFalse(try XCTUnwrap(all["App/Launcher.swift"]).contains("environment"))
    }

    func testTheImageIsOpenedAsAgreedAndNothingInItRuns() throws {
        let text = try XCTUnwrap(try sources()[file])
        XCTAssertTrue(
            text.contains(#"["attach", dmg, "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mountPoint]"#))
        XCTAssertTrue(text.contains(#"["detach", mountPoint, "-force"]"#))
        XCTAssertTrue(text.contains(#"["--verify", "--deep", "--strict", copy]"#))
        XCTAssertEqual(count("Process()", in: text), 1, "one way to run a tool")
        XCTAssertEqual(count("Self.tool(\"", in: text) + count("await Self.tool(", in: text) > 0, true)
        for tool in text.components(separatedBy: "\"").filter({ $0.hasPrefix("/") && !$0.contains(" ") }) {
            XCTAssertTrue(
                ["/usr/bin/hdiutil", "/usr/bin/codesign"].contains(tool) || tool.hasPrefix("/Contents")
                    || ["/m", "/update.sig", "/update.dmg"].contains(tool), tool)
        }
        XCTAssertFalse(text.contains("--version"))
    }

    func testTheSignatureIsCheckedBeforeTheImageOpens() throws {
        let text = try XCTUnwrap(try sources()[file])
        let verify = try XCTUnwrap(text.range(of: "try await fetchAndVerify("))
        let open = try XCTUnwrap(text.range(of: "try await copyApp("))
        XCTAssertLessThan(verify.lowerBound, open.lowerBound)
    }

    func testTheAppUsesOnlyTheCheckedPlaceAndNotTheHomebrewReopen() throws {
        let all = try sources()
        for (name, source) in all where name.hasPrefix("App/") {
            XCTAssertFalse(source.contains("AppPlace(checking"), name)
            XCTAssertFalse(source.contains("publicKey:"), name)
            XCTAssertFalse(source.contains("tempRoot"), name)
        }
        let model = try XCTUnwrap(all["App/AppModel.swift"])
        let install = try XCTUnwrap(model.range(of: "private func install("))
        let end = try XCTUnwrap(model.range(of: "private func startInTerminal"))
        let body = model[install.lowerBound..<end.lowerBound]
        XCTAssertFalse(body.contains("reopen"), "Process.run says nothing about the new app having started")
        for (first, then) in [
            ("selfUpdate.prepare", "selfUpdate.swap()"), ("save()", "selfUpdate.swap()"),
            ("selfUpdate.swap()", "server?.stop()"), ("server?.stop()", "selfUpdate.open"),
            ("selfUpdate.isListening()", "selfUpdate.removeCopy()\n                selfUpdate.quit()"),
        ] {
            let a = try XCTUnwrap(body.range(of: first), first)
            let b = try XCTUnwrap(body.range(of: then), then)
            XCTAssertLessThan(a.lowerBound, b.lowerBound, "\(first) before \(then)")
        }
    }

    func testTheOneTestSwitchOnlyTakesTheNetworkAway() throws {
        let model = try XCTUnwrap(try sources()["App/AppModel.swift"])
        XCTAssertEqual(count("XCTestConfigurationFilePath", in: model), 1)
        let start = try XCTUnwrap(model.range(of: "XCTestConfigurationFilePath"))
        let end = try XCTUnwrap(model[start.upperBound...].range(of: "} else {"))
        let branch = model[start.upperBound..<end.lowerBound]
        XCTAssertTrue(branch.contains("askLatest: { _ in .failed }"))
        XCTAssertFalse(branch.contains("route"), "no update route, no key, no place")
    }

    func testTheHelperBuildsNoneOfIt() throws {
        let project = try String(
            contentsOf: repo.appendingPathComponent("AgentOvertime.xcodeproj/project.pbxproj"), encoding: .utf8)
        let builds = project.components(separatedBy: "\n").filter { $0.contains("SelfUpdate.swift in Sources") }
        XCTAssertFalse(builds.isEmpty)
        XCTAssertFalse(builds.contains { $0.contains("AD00") })
    }
}
