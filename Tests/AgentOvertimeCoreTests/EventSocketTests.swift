@testable import AgentOvertimeCore
import XCTest

final class EventSocketTests: XCTestCase {
    private var folder: String!

    override func setUp() {
        // Short on purpose: socket paths must stay under 104 bytes.
        folder = (Paths.userTempFolder as NSString).appendingPathComponent("ao-\(UUID().uuidString.prefix(8))")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: folder)
    }

    func testRoundTripAndPermissions() throws {
        let path = folder + "/events.sock"
        let received = expectation(description: "event")
        var got: HookEvent?
        let server = EventServer(path: path) { got = $0; received.fulfill() }
        try server.start()
        defer { server.stop() }

        XCTAssertEqual(try mode(folder), 0o700)
        XCTAssertEqual(try mode(path), 0o600)

        let sent = HookEvent(kind: .permissionRequest, session: "s", cwd: "/x", pid: 123)
        XCTAssertTrue(EventClient.send(sent.wireLine(), to: path))
        wait(for: [received], timeout: 2)
        XCTAssertEqual(got, sent)
    }

    func testDropsGarbageAndOversizedLines() throws {
        let path = folder + "/events.sock"
        let good = expectation(description: "only the valid line arrives")
        var events: [HookEvent] = []
        let server = EventServer(path: path) { events.append($0); good.fulfill() }
        try server.start()
        defer { server.stop() }

        EventClient.send(Data("hello\n".utf8), to: path)
        EventClient.send(Data(repeating: 0x41, count: Limits.line * 2), to: path)
        EventClient.send(HookEvent(kind: .stop, session: "s", cwd: "/x").wireLine(), to: path)
        wait(for: [good], timeout: 2)
        XCTAssertEqual(events.map(\.kind), [.stop])
    }

    func testReplacesOnlyAStaleSocket() throws {
        let path = folder + "/events.sock"
        let first = EventServer(path: path) { _ in }
        try first.start()
        let second = EventServer(path: path) { _ in }
        XCTAssertNoThrow(try second.start(), "a leftover socket is ours to replace")
        second.stop()
        first.stop()

        try "not a socket".write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try EventServer(path: path) { _ in }.start()) {
            XCTAssertEqual($0 as? EventServer.Failure, .notASocket)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "a regular file is never deleted")
    }

    func testRefusesALinkedFolder() throws {
        let real = folder + "-real"
        try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: real) }
        try FileManager.default.createSymbolicLink(atPath: folder, withDestinationPath: real)
        XCTAssertThrowsError(try EventServer(path: folder + "/events.sock") { _ in }.start())
    }

    func testSendWithoutAppIsQuiet() {
        XCTAssertFalse(EventClient.send(Data("x\n".utf8), to: folder + "/nobody.sock"))
    }

    func testSocketPathFallsBackWhenHomeIsLong() {
        XCTAssertEqual(Paths.socket(home: "/Users/me", tempFolder: "/tmp/u/"), "/Users/me/Library/Application Support/AgentOvertime/events.sock")
        let long = "/Users/" + String(repeating: "x", count: 80)
        XCTAssertEqual(Paths.socket(home: long, tempFolder: "/var/folders/ab/T/"), "/var/folders/ab/T/agent-overtime.sock")
    }

    private func mode(_ path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return (attributes[.posixPermissions] as! NSNumber).intValue
    }
}
