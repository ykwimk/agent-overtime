import XCTest

@testable import AgentOvertimeCore

final class ReleaseVersionTests: XCTestCase {
    func testReadsTagsOfThreePlainNumbers() throws {
        let version = try XCTUnwrap(ReleaseVersion(tag: "v0.10.9999"))
        XCTAssertEqual([version.major, version.minor, version.patch], [0, 10, 9999])
        XCTAssertEqual(version.tag, "v0.10.9999")
        XCTAssertEqual(version.number, "0.10.9999")
    }

    func testRefusesEverythingElse() {
        for tag in [
            "", "v", "0.5.0", "V0.5.0", "v0.5", "v0.5.0.1", "v0.5.", "v.5.0", "v0..0", "v0.5.0-beta", "v0.5.0+1",
            "v 0.5.0", " v0.5.0", "v0.5.0 ", "v0.5.0\n", "v01.5.0", "v0.05.0", "v0.5.00", "v12345.0.0", "v-1.0.0",
            "v٠.٥.٠", "ｖ0.5.0", "v０.５.０", "v0.5.0\0", "v0.5.0/../../evil", "v0.5.0?x=1",
        ] {
            XCTAssertNil(ReleaseVersion(tag: tag), tag)
        }
    }

    func testComparesAsNumbers() throws {
        func version(_ tag: String) throws -> ReleaseVersion { try XCTUnwrap(ReleaseVersion(tag: tag)) }
        XCTAssertGreaterThan(try version("v0.10.0"), try version("v0.9.9"))
        XCTAssertGreaterThan(try version("v1.0.0"), try version("v0.99.99"))
        XCTAssertGreaterThan(try version("v0.4.10"), try version("v0.4.9"))
        XCTAssertEqual(try version("v0.4.0"), try version("v0.4.0"))
    }

    func testThisReleaseHasACheckableNumber() {
        XCTAssertNotNil(ReleaseVersion(tag: Release.tag))
    }

    func testReleasePageIsBuiltFromTheNumbers() throws {
        let version = try XCTUnwrap(ReleaseVersion(tag: "v0.5.1"))
        XCTAssertEqual(
            UpdateCheck.releaseURL(version).absoluteString,
            "https://github.com/ykwimk/agent-overtime/releases/tag/v0.5.1")
    }
}

/// Answers instead of the network: every request in these tests stays inside this process.
private final class FakeGitHub: URLProtocol {
    enum Reply {
        case answer(Int, Data)
        case offline
        case redirect
    }

    static var reply = Reply.offline
    static var seen: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.seen.append(request)
        let url = request.url!
        switch Self.reply {
        case .offline:
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        case .answer(let status, let body):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .redirect:
            let next = URL(string: "https://example.com/latest")!
            let response = HTTPURLResponse(
                url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": next.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: next), redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

final class UpdateCheckTests: XCTestCase {
    private let current = ReleaseVersion(tag: "v0.5.0")!

    private func json(_ tag: String) -> Data {
        Data(#"{"tag_name": "\#(tag)", "body": "ignored", "assets": [{"name": "x"}]}"#.utf8)
    }

    private func ask(_ reply: FakeGitHub.Reply) async -> UpdateCheck.Outcome {
        FakeGitHub.reply = reply
        FakeGitHub.seen = []
        let configuration = UpdateCheck.configuration
        configuration.protocolClasses = [FakeGitHub.self]
        return await UpdateCheck.ask(current: current, configuration: configuration)
    }

    func testNewerSameAndLowerNumbers() async throws {
        let outcome = await ask(.answer(200, json("v0.5.1")))
        XCTAssertEqual(outcome, .newer(try XCTUnwrap(ReleaseVersion(tag: "v0.5.1"))))
        let same = await ask(.answer(200, json("v0.5.0")))
        XCTAssertEqual(same, .upToDate)
        let lower = await ask(.answer(200, json("v0.4.9")))
        XCTAssertEqual(lower, .upToDate)
    }

    func testRateLimitOfflineAndBrokenAnswersFailQuietly() async {
        let replies: [FakeGitHub.Reply] = [
            .offline, .answer(403, json("v9.9.9")), .answer(404, Data()), .answer(500, json("v9.9.9")),
            .answer(200, Data()), .answer(200, Data("not json".utf8)), .answer(200, Data("[]".utf8)),
            .answer(200, Data(#"{"name": "v9.9.9"}"#.utf8)), .answer(200, Data(#"{"tag_name": 5}"#.utf8)),
            .answer(200, Data(#"{"tag_name": null}"#.utf8)),
        ]
        for reply in replies {
            let outcome = await ask(reply)
            XCTAssertEqual(outcome, .failed, "\(reply)")
        }
    }

    func testOddVersionTextFails() async {
        for tag in ["0.5.1", "v0.5.1-beta", "v0.5", "latest", "v99999.0.0", "v0.5.1<script>"] {
            let outcome = await ask(.answer(200, json(tag)))
            XCTAssertEqual(outcome, .failed, tag)
        }
    }

    func testAnswerLimitIsCountedWhileReceiving() async {
        let body = json("v0.5.1")
        let spaces = Data(repeating: UInt8(ascii: " "), count: UpdateCheck.maxResponse - body.count)
        let atTheLimit = await ask(.answer(200, body + spaces))
        XCTAssertEqual(atTheLimit, .newer(ReleaseVersion(tag: "v0.5.1")!))
        let over = await ask(.answer(200, body + spaces + Data(" ".utf8)))
        XCTAssertEqual(over, .failed)
    }

    func testRedirectsAreNotFollowed() async throws {
        let outcome = await ask(.redirect)
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(FakeGitHub.seen.map(\.url), [UpdateCheck.latest], "never asks the second address")
        let answered = await ask(.answer(301, json("v9.9.9")))
        XCTAssertEqual(answered, .failed)
    }

    func testRequestCarriesOnlyTheThreeHeaders() throws {
        let request = UpdateCheck.request(current: current)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(
            request.url?.absoluteString, "https://api.github.com/repos/ykwimk/agent-overtime/releases/latest")
        XCTAssertEqual(
            request.allHTTPHeaderFields,
            [
                "User-Agent": "AgentOvertime/0.5.0", "Accept": "application/vnd.github+json", "Accept-Language": "en",
            ])
        XCTAssertFalse(request.httpShouldHandleCookies)
    }

    func testSessionKeepsNothing() {
        let configuration = UpdateCheck.configuration
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertFalse(configuration.waitsForConnectivity)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 15)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 30)
    }
}

final class UpdateStateTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let day = UpdateState.interval
    private let newer = UpdateCheck.Outcome.newer(ReleaseVersion(tag: "v0.5.1")!)

    func testOffNeverAsks() {
        var state = UpdateState(isOn: false, lastChecked: nil, now: start)
        XCTAssertFalse(state.begin(at: start), "not even when the app opens")
        XCTAssertFalse(state.begin(at: start + 10 * day))
    }

    func testAsksWhenTheAppOpensThenOnceADay() {
        var state = UpdateState(isOn: true, lastChecked: start, now: start + 1)
        XCTAssertTrue(state.begin(at: start + 1), "every opening asks")
        XCTAssertFalse(state.begin(at: start + 2), "one at a time")
        state.finish(.upToDate, at: start + 2)
        XCTAssertFalse(state.begin(at: start + 7))
        XCTAssertFalse(state.begin(at: start + day))
        XCTAssertTrue(state.begin(at: start + 1 + day))
        state.finish(.upToDate, at: start + 2 + day)
        XCTAssertTrue(state.begin(at: start + 30 * day), "a Mac that slept asks as it wakes")
    }

    func testFailureWaitsADayToo() {
        var state = UpdateState(isOn: true, lastChecked: nil, now: start)
        XCTAssertTrue(state.begin(at: start))
        state.finish(.failed, at: start + 1)
        XCTAssertEqual(state.result, .failed)
        XCTAssertNil(state.lastChecked, "only an answer counts as checked")
        XCTAssertFalse(state.begin(at: start + 6), "no retry")
        XCTAssertTrue(state.begin(at: start + day))
    }

    func testSavedTimeInTheFutureIsIgnoredAndAClockSetBackAsks() {
        var state = UpdateState(isOn: true, lastChecked: start + day, now: start)
        XCTAssertNil(state.lastChecked)
        XCTAssertTrue(state.begin(at: start))
        state.finish(.upToDate, at: start)
        XCTAssertTrue(state.begin(at: start - 60))
    }

    func testNewVersionShowsOnlyWhileOnAndSurvivesAFailedTry() {
        var state = UpdateState(isOn: true, lastChecked: nil, now: start)
        XCTAssertNil(state.newVersion)
        _ = state.begin(at: start)
        state.finish(newer, at: start)
        XCTAssertEqual(state.newVersion?.number, "0.5.1")
        XCTAssertEqual(state.lastChecked, start)

        _ = state.begin(at: start + day)
        state.finish(.failed, at: start + day)
        XCTAssertEqual(state.newVersion?.number, "0.5.1", "still out there")
        XCTAssertEqual(state.lastChecked, start)

        state.turn(on: false)
        XCTAssertNil(state.newVersion)
        state.turn(on: true)
        XCTAssertEqual(state.newVersion?.number, "0.5.1")

        _ = state.begin(at: start + 2 * day)
        state.finish(.upToDate, at: start + 2 * day)
        XCTAssertNil(state.newVersion, "taken back: no newer release any more")
    }

    func testTurningOffMidwayDropsTheTry() {
        var state = UpdateState(isOn: true, lastChecked: nil, now: start)
        XCTAssertTrue(state.begin(at: start))
        state.turn(on: false)
        XCTAssertFalse(state.begin(at: start + 1))
        state.turn(on: true)
        XCTAssertTrue(state.begin(at: start + 2), "turned back on, it asks again")
    }

    func testTurningBackOnSoonAfterAnAnswerDoesNotAskAgain() {
        var state = UpdateState(isOn: true, lastChecked: nil, now: start)
        _ = state.begin(at: start)
        state.finish(.upToDate, at: start)
        state.turn(on: false)
        state.turn(on: true)
        XCTAssertFalse(state.begin(at: start + 60))
    }
}

/// What the app promises about the network, checked in its source.
final class UpdateSourceTests: XCTestCase {
    private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    private let checker = "Sources/AgentOvertimeCore/UpdateCheck.swift"

    private func sources() throws -> [String: String] {
        var all: [String: String] = [:]
        for folder in ["App", "Sources/AgentOvertimeCore", "Helper", "tools/fake-events"] {
            let url = repo.appendingPathComponent(folder)
            for file in try FileManager.default.contentsOfDirectory(atPath: url.path) where file.hasSuffix(".swift") {
                all[folder + "/" + file] = try String(contentsOf: url.appendingPathComponent(file), encoding: .utf8)
            }
        }
        return all
    }

    func testOneFileUsesTheNetwork() throws {
        let all = try sources()
        XCTAssertGreaterThan(all.count, 10)
        for (file, text) in all where file != checker {
            for word in [
                "URLSession", "URLRequest", "NSURLConnection", "api.github.com", "Data(contentsOf: URL(string",
            ] {
                XCTAssertFalse(text.contains(word), "\(file): \(word)")
            }
        }
        let text = try XCTUnwrap(all[checker])
        XCTAssertEqual(text.components(separatedBy: "URLSession(configuration").count - 1, 2, "ask and download")
        XCTAssertEqual(text.components(separatedBy: "api.github.com").count - 1, 1, "one address")
    }

    func testOnlyTheVersionIsReadAndNothingChangesTheCheckFromOutside() throws {
        let text = try XCTUnwrap(try sources()[checker])
        XCTAssertEqual(text.components(separatedBy: "forHTTPHeaderField").count - 1, 3, "three headers")
        XCTAssertEqual(text.components(separatedBy: "case tag = \"tag_name\"").count - 1, 1)
        for word in [
            "browser_download_url", "\"assets\"", "\"body\"", "\"html_url\"", "digest", "ProcessInfo", "getenv",
            "UserDefaults", "CFPreferences",
        ] {
            XCTAssertFalse(text.contains(word), word)
        }
    }

    func testTheHelperDoesNotBuildTheCheckAndNoTransportExceptions() throws {
        let project = try String(
            contentsOf: repo.appendingPathComponent("AgentOvertime.xcodeproj/project.pbxproj"), encoding: .utf8)
        let builds = project.components(separatedBy: "\n").filter { $0.contains("UpdateCheck.swift in Sources") }
        XCTAssertFalse(builds.isEmpty, "the app builds it")
        XCTAssertFalse(builds.contains { $0.contains("AD00") }, "AD… are the helper's build files")
        XCTAssertFalse(project.contains("NSAppTransportSecurity"))
        XCTAssertFalse(project.contains("NSAllowsArbitraryLoads"))
    }
}
