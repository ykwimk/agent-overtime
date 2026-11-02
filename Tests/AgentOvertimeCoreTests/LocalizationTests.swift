import AgentOvertimeCore
import XCTest

/// Every word the app shows comes in English and Korean: each string in the catalog has its Korean, and the plain
/// strings the app's code shows are all in the catalog.
final class LocalizationTests: XCTestCase {
    private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    func testEveryStringHasKorean() throws {
        let data = try Data(contentsOf: repo.appendingPathComponent("App/Localizable.xcstrings"))
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
        XCTAssertGreaterThan(strings.count, 100)
        for (key, entry) in strings where entry["shouldTranslate"] as? Bool != false {
            let localizations = entry["localizations"] as? [String: Any]
            XCTAssertNotNil(localizations?["ko"], "no Korean for \(key)")
        }

        // Text("…"), Button("…"), Label("…", …) and String(localized: "…") without interpolation.
        let pattern = try NSRegularExpression(
            pattern: #"(?:Text|Button|Label|String\(localized:)\(?\s*"((?:[^"\\]|\\.)*)""#)
        let app = repo.appendingPathComponent("App")
        let files = try FileManager.default.contentsOfDirectory(atPath: app.path).filter { $0.hasSuffix(".swift") }
        var checked = 0
        for file in files {
            let source = try String(contentsOf: app.appendingPathComponent(file), encoding: .utf8)
            for match in pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                guard let range = Range(match.range(at: 1), in: source) else { continue }
                let key = String(source[range])
                guard !key.contains("\\("), !key.isEmpty else { continue }
                XCTAssertNotNil(strings[key], "\(file): \"\(key)\" is not in the catalog")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 50)
    }
}

/// File names, task titles and the model show only in the side panel: no other view of the app reads them, so they
/// never reach the office floor, a tooltip, the menu, a notification or Start Work.
final class DetailPlacementTests: XCTestCase {
    func testOnlyTheSidePanelReadsDetails() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("App")
        var readers: [String] = []
        for file in try FileManager.default.contentsOfDirectory(atPath: app.path) where file.hasSuffix(".swift") {
            let source = try String(contentsOf: app.appendingPathComponent(file), encoding: .utf8)
            if source.contains(".detail(") || source.contains("detail(session") || source.contains("detail(teammate") {
                readers.append(file)
            }
        }
        XCTAssertEqual(readers, ["OfficeView.swift"])
    }
}

/// What the app may do with other processes, checked in its source: no command lines, no list of every user's
/// processes, no task ports; process calls only in the session finder, which never takes a number from the socket;
/// one look on the 5 s tick.
final class ProcessReadingTests: XCTestCase {
    private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private func sources() throws -> [String: String] {
        var all: [String: String] = [:]
        for folder in ["App", "Sources/AgentOvertimeCore", "Helper"] {
            let url = repo.appendingPathComponent(folder)
            for file in try FileManager.default.contentsOfDirectory(atPath: url.path) where file.hasSuffix(".swift") {
                all[folder + "/" + file] = try String(contentsOf: url.appendingPathComponent(file), encoding: .utf8)
            }
        }
        return all
    }

    func testOnlyTheAllowedProcessCalls() throws {
        let all = try sources()
        XCTAssertGreaterThan(all.count, 10)
        for (file, text) in all {
            for name in [
                "KERN_PROCARGS", "KERN_PROC_ALL", "task_for_pid", "PROC_PIDLISTFDS", "PROC_PIDFDINFO", "REGIONPATH",
            ] {
                XCTAssertFalse(text.contains(name), "\(file): \(name)")
            }
            if text.contains("proc_pidinfo(") || text.contains("proc_pidpath(") || text.contains("proc_listpids(") {
                XCTAssertEqual(file, "Sources/AgentOvertimeCore/OfficeState.swift")
            }
        }
        let office = try XCTUnwrap(all["Sources/AgentOvertimeCore/OfficeState.swift"])
        let finder = try XCTUnwrap(office.range(of: "public struct SessionFinder")).lowerBound
        XCTAssertFalse(office[..<finder].contains("proc_"), "process calls only in the finder")
        XCTAssertFalse(office[finder...].contains("HookEvent"), "the finder never sees an event's process number")

        let model = try XCTUnwrap(all["App/AppModel.swift"])
        XCTAssertEqual(model.components(separatedBy: "finder.look(").count - 1, 1, "one place looks")
        XCTAssertEqual(model.components(separatedBy: "withTimeInterval: 5").count - 1, 1, "on the one 5 s tick")
    }

    /// Run inside a Claude Code session (as while building this app), the finder finds that session's Claude Code
    /// among this process's ancestors, in the folder it runs in. Prints only counts and yes or no: nothing of any
    /// other process. Only with AGENT_OVERTIME_SMOKE=1, from the session's folder; skipped otherwise.
    func testSmokeFindsTheClaudeCodeThisRunsIn() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["AGENT_OVERTIME_SMOKE"] == "1",
            "Looks through this Mac's processes: set AGENT_OVERTIME_SMOKE=1 to run it, from the session's folder")
        var finder = SessionFinder()
        let found = finder.look()
        var ancestors: [Int32] = []
        var pid = getpid()
        while pid > 1, ancestors.count < 16, let info = SessionFinder.ProcessTable.live.info(pid) {
            ancestors.append(pid)
            pid = info.parent
        }
        let mine = found.first { ancestors.contains($0.pid) }
        let folder = ProcessInfo.processInfo.environment["PWD"] ?? FileManager.default.currentDirectoryPath
        print(
            "smoke: found \(found.count); this session found: \(mine != nil); its folder matches: \(mine?.folder == folder)"
        )
        try XCTSkipIf(mine == nil, "not run inside a Claude Code session")
        XCTAssertEqual(mine?.folder, folder)
    }
}
