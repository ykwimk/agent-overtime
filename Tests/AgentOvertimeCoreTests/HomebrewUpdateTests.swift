import XCTest

@testable import AgentOvertimeCore

final class HomebrewUpdateTests: XCTestCase {
    private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private func tempFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ao-brew-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    // MARK: telling a Homebrew install

    func testManagedOnlyWithItsCaskFolderAndItsBrew() {
        func manages(
            _ location: AppLocation = .ok, folders: Set<String>, tools: Set<String>
        ) -> Bool {
            HomebrewUpdate.manages(
                location: location, isFolder: { folders.contains($0) }, isExecutable: { tools.contains($0) })
        }
        let arm = "/opt/homebrew/Caskroom/agent-overtime"
        let intel = "/usr/local/Caskroom/agent-overtime"
        XCTAssertTrue(manages(folders: [arm], tools: ["/opt/homebrew/bin/brew"]))
        XCTAssertTrue(manages(folders: [intel], tools: ["/usr/local/bin/brew"]))
        XCTAssertFalse(manages(folders: [], tools: ["/opt/homebrew/bin/brew"]), "brew, but not this app")
        XCTAssertFalse(manages(folders: [arm], tools: []), "no brew to run")
        XCTAssertFalse(manages(folders: [arm], tools: ["/usr/local/bin/brew"]), "the brew of the other prefix")
        XCTAssertFalse(manages(.translocated, folders: [arm], tools: ["/opt/homebrew/bin/brew"]))
        XCTAssertFalse(manages(.notInApplications, folders: [arm], tools: ["/opt/homebrew/bin/brew"]))
    }

    func testReadsTheVersionOnDiskAsAFile() throws {
        let bundle = try tempFolder()
        XCTAssertNil(HomebrewUpdate.installedVersion(bundlePath: bundle.path), "brew is between two apps")
        let contents = bundle.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = contents.appendingPathComponent("Info.plist")
        func write(_ number: String) throws {
            try PropertyListSerialization.data(
                fromPropertyList: ["CFBundleShortVersionString": number], format: .xml, options: 0
            ).write(to: plist)
        }
        try write("0.5.1")
        XCTAssertEqual(HomebrewUpdate.installedVersion(bundlePath: bundle.path)?.tag, "v0.5.1")
        try write("0.5")
        XCTAssertNil(HomebrewUpdate.installedVersion(bundlePath: bundle.path))
        try Data("not a plist".utf8).write(to: plist)
        XCTAssertNil(HomebrewUpdate.installedVersion(bundlePath: bundle.path))
    }

    // MARK: the script's text

    func testScriptIsFixedText() throws {
        for korean in [false, true] {
            let script = HomebrewUpdate.script(korean: korean)
            XCTAssertTrue(script.hasPrefix("#!/bin/sh\nrm -f -- \"$0\"\n"), "deletes itself first")
            XCTAssertTrue(script.contains("run \"$brew\" update"))
            XCTAssertTrue(script.contains("run \"$brew\" upgrade --cask ykwimk/tap/agent-overtime"))
            XCTAssertNil(script.range(of: #"\d+\.\d+"#, options: .regularExpression), "no version number")
            XCTAssertFalse(script.contains(NSHomeDirectory()), "no path of this Mac")
            XCTAssertFalse(script.contains("Applications/"))
            for word in ["--no-quarantine", "xattr", "spctl", "osascript", "sudo", "curl", "PATH", "which "] {
                XCTAssertFalse(script.contains(word), word)
            }
        }
    }

    func testWordsCannotBreakOutOfTheirQuotes() throws {
        let opening = "#!/bin/sh\nrm -f -- \"$0\"\n\n"
        for korean in [false, true] {
            let words = HomebrewUpdate.script(korean: korean).dropFirst(opening.count).components(separatedBy: "\n")
                .prefix { !$0.hasPrefix("run()") && !$0.isEmpty }
            XCTAssertEqual(words.count, 7)
            for line in words {
                let parts = line.components(separatedBy: "=\"")
                XCTAssertEqual(parts.count, 2, line)
                let text = String(parts[1].dropLast())
                XCTAssertTrue(line.hasSuffix("\""), line)
                for mark in ["\"", "$", "`", "\\"] { XCTAssertFalse(text.contains(mark), line) }
            }
        }
    }

    func testSaysItInTheAppsLanguage() {
        let english = HomebrewUpdate.script(korean: false)
        let korean = HomebrewUpdate.script(korean: true)
        XCTAssertTrue(english.contains("System Settings > Privacy & Security > Open Anyway"))
        XCTAssertTrue(english.contains("sessions will not show in the office"))
        XCTAssertTrue(korean.contains("Homebrew 에 아직 안 올라왔어요. 조금 뒤 다시 해 주세요"))
        XCTAssertTrue(korean.contains("시스템 설정 > 개인정보 보호 및 보안 > 그래도 열기"))
        XCTAssertTrue(korean.contains("허용하기 전에는 세션이 사무실에 안 보여요"))
    }

    func testThisFileBuildsNoTextAtRunTime() throws {
        let text = try String(
            contentsOf: repo.appendingPathComponent("Sources/AgentOvertimeCore/HomebrewUpdate.swift"), encoding: .utf8)
        XCTAssertFalse(text.contains("\\("), "no string interpolation")
    }

    // MARK: the script running, with a made-up brew in a made-up prefix

    /// Runs the script at `prefix` instead of the two real ones: this never reaches a real brew. `brew` is the body
    /// of the fake brew, which gets the Caskroom folder as `$room`.
    private func run(korean: Bool = false, brew: String?) throws -> (output: String, script: URL) {
        let prefix = try tempFolder()
        let room = prefix.appendingPathComponent("Caskroom/agent-overtime/0.5.0")
        try FileManager.default.createDirectory(at: room, withIntermediateDirectories: true)
        if let brew {
            let bin = prefix.appendingPathComponent("bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let tool = bin.appendingPathComponent("brew")
            try "#!/bin/sh\nroom='\(room.deletingLastPathComponent().path)'\n\(brew)\n".write(
                to: tool, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
        }
        let text = HomebrewUpdate.script(korean: korean).replacingOccurrences(
            of: "in /opt/homebrew /usr/local;", with: "in '\(prefix.path)';")
        XCTAssertFalse(text.contains("/opt/homebrew"), "must not reach the real brew")
        let script = prefix.appendingPathComponent("update.command")
        try text.write(to: script, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: output, as: UTF8.self), script)
    }

    func testNewNumberSaysItReopensAndHowToAllowIt() throws {
        let (output, script) = try run(
            brew: #"if [ "$1" = upgrade ]; then mv "$room/0.5.0" "$room/0.5.1"; fi"#)
        XCTAssertTrue(output.contains("Updated. The app reopens"), output)
        XCTAssertTrue(output.contains("Open Anyway"), output)
        XCTAssertTrue(output.contains("sessions will not show"), output)
        XCTAssertFalse(output.contains("does not have the new version yet"), output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: script.path), "deleted itself")
    }

    func testShowsTheCommandsItRuns() throws {
        let (output, _) = try run(brew: "exit 0")
        XCTAssertTrue(output.contains("/brew update"), output)
        XCTAssertTrue(output.contains("/brew upgrade --cask ykwimk/tap/agent-overtime"), output)
    }

    func testSameNumberSaysHomebrewDoesNotHaveItYet() throws {
        let (output, _) = try run(korean: true, brew: "exit 0")
        XCTAssertTrue(output.contains("Homebrew 에 아직 안 올라왔어요"), output)
        XCTAssertFalse(output.contains("새 버전을 설치했어요"), output)
        XCTAssertFalse(output.contains("그래도 열기"), output)
    }

    func testFailureStopsAndSaysTheAppStays() throws {
        let (output, _) = try run(brew: #"[ "$1" = update ] && exit 1; echo upgrade ran"#)
        XCTAssertTrue(output.contains("The update did not finish"), output)
        XCTAssertFalse(output.contains("upgrade ran"), "no upgrade after a failed update")
    }

    func testNoBrewSaysSo() throws {
        let (output, _) = try run(brew: nil)
        XCTAssertTrue(output.contains("Homebrew was not found"), output)
    }
}

final class UpdateTerminalStateTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let current = ReleaseVersion(tag: "v0.5.0")!
    private let newer = ReleaseVersion(tag: "v0.5.1")!

    private func available() -> UpdateState {
        var state = UpdateState(isOn: true, lastChecked: nil, now: start)
        state.finish(.newer(newer), at: start)
        return state
    }

    func testStartsOnlyWithANewVersionAndOnlyOnce() {
        var none = UpdateState(isOn: true, lastChecked: nil, now: start)
        XCTAssertFalse(none.beginTerminal(at: start))

        var state = available()
        XCTAssertTrue(state.beginTerminal(at: start))
        XCTAssertTrue(state.isInTerminal)
        XCTAssertFalse(state.beginTerminal(at: start + 1), "a second press does nothing")
    }

    func testReopensOnlyAfterTwoTicksOfANewerAppOnDisk() {
        var state = available()
        _ = state.beginTerminal(at: start)
        XCTAssertFalse(state.follow(installed: current, current: current, at: start + 5))
        XCTAssertFalse(state.follow(installed: newer, current: current, at: start + 10), "brew may still be at it")
        XCTAssertTrue(state.follow(installed: newer, current: current, at: start + 15))
    }

    func testAMissingAppBetweenTicksStartsTheCountAgain() {
        var state = available()
        _ = state.beginTerminal(at: start)
        XCTAssertFalse(state.follow(installed: newer, current: current, at: start + 5))
        XCTAssertFalse(state.follow(installed: nil, current: current, at: start + 10))
        XCTAssertFalse(state.follow(installed: newer, current: current, at: start + 15))
        XCTAssertTrue(state.follow(installed: newer, current: current, at: start + 20))
    }

    func testAfterFiveMinutesWithNothingNewItIsANewVersionAgain() {
        var state = available()
        _ = state.beginTerminal(at: start)
        XCTAssertFalse(state.follow(installed: current, current: current, at: start + 299))
        XCTAssertTrue(state.isInTerminal)
        XCTAssertFalse(state.follow(installed: current, current: current, at: start + 300))
        XCTAssertFalse(state.isInTerminal)
        XCTAssertEqual(state.newVersion, newer)
        XCTAssertTrue(state.beginTerminal(at: start + 301), "can be pressed again")
    }

    func testAClockSetBackEndsTheWait() {
        var state = available()
        _ = state.beginTerminal(at: start)
        XCTAssertFalse(state.follow(installed: nil, current: current, at: start - 60))
        XCTAssertFalse(state.isInTerminal)
    }

    func testTurningTheCheckOffEndsIt() {
        var state = available()
        _ = state.beginTerminal(at: start)
        state.turn(on: false)
        XCTAssertFalse(state.isInTerminal)
    }

    func testNothingHappensWithoutAPress() {
        var state = available()
        XCTAssertFalse(state.follow(installed: newer, current: current, at: start + 5))
        XCTAssertFalse(state.follow(installed: newer, current: current, at: start + 10), "a number alone never reopens")
    }
}

/// What the Update path may and may not do, checked in the source.
final class HomebrewSourceTests: XCTestCase {
    private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private func text(_ path: String) throws -> String {
        try String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8)
    }

    func testNoAppleEventsAndNoWayAroundMacOSChecks() throws {
        for folder in ["App", "Sources/AgentOvertimeCore", "Helper"] {
            let url = repo.appendingPathComponent(folder)
            for file in try FileManager.default.contentsOfDirectory(atPath: url.path) where file.hasSuffix(".swift") {
                let source = try String(contentsOf: url.appendingPathComponent(file), encoding: .utf8)
                for word in [
                    "osascript", "NSAppleScript", "NSAppleEventDescriptor", "--no-quarantine", "quarantineProperties",
                    "LSFileQuarantineEnabled", "/usr/bin/xattr", "spctl", "--noqtn",
                ] {
                    XCTAssertFalse(source.contains(word), "\(file): \(word)")
                }
            }
        }
    }

    func testUpdateStaysOffTheStartCommandPath() throws {
        let launcher = try text("App/Launcher.swift")
        let route = try XCTUnwrap(launcher.range(of: "struct HomebrewRoute"))
        let routeText = launcher[route.lowerBound...]
        for word in ["StartCommand", "Launcher.run", "config.json"] {
            XCTAssertFalse(routeText.contains(word), word)
        }
        XCTAssertTrue(routeText.contains("HomebrewUpdate.script(korean: korean)"), "fixed text, by language only")
        XCTAssertTrue(routeText.contains(#"URL(fileURLWithPath: "/usr/bin/open")"#), "an absolute path")

        let model = try text("App/AppModel.swift")
        let start = try XCTUnwrap(model.range(of: "func startUpdate"))
        let end = try XCTUnwrap(model.range(of: "func followUpdate"))
        let body = model[start.lowerBound..<end.lowerBound]
        for word in ["startPhase", "Keys.approved", "start.", "launch(", "Process("] {
            XCTAssertFalse(body.contains(word), word)
        }
    }

    func testOnlyAPressStartsIt() throws {
        var starts: [String] = []
        let app = repo.appendingPathComponent("App")
        for file in try FileManager.default.contentsOfDirectory(atPath: app.path) where file.hasSuffix(".swift") {
            let source = try String(contentsOf: app.appendingPathComponent(file), encoding: .utf8)
            for line in source.components(separatedBy: "\n") where line.contains("startUpdate(version)") {
                starts.append(file + ":" + line.trimmingCharacters(in: .whitespaces))
            }
        }
        XCTAssertEqual(starts.count, 4, "\(starts)")
        for start in starts where !start.hasPrefix("MenuContent") {
            XCTAssertTrue(start.contains("Button(\"Update\")") || start.contains("Button(\"Try Again\")"), start)
        }
        XCTAssertFalse(try text("App/OfficeView.swift").contains("startUpdate(version) }.keyboardShortcut"))
    }
}
