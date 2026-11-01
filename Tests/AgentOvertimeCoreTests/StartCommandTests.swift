@testable import AgentOvertimeCore
import XCTest

final class StartCommandTests: XCTestCase {
    let home = "/Users/me"

    func testQuote() {
        XCTAssertEqual(StartCommand.quote("claude"), "'claude'")
        XCTAssertEqual(StartCommand.quote("it's"), #"'it'\''s'"#)
        XCTAssertEqual(StartCommand.quote("$(rm -rf ~); `x`"), "'$(rm -rf ~); `x`'")
    }

    func testScriptShape() throws {
        let script = try StartCommand(folder: "~/my-project", run: ["./dev.sh", "up"]).script(home: home)
        XCTAssertEqual(script, """
        #!/bin/sh
        rm -f -- "$0"
        cd -- '/Users/me/my-project' || exit 1
        exec './dev.sh' 'up'

        """)
    }

    func testRejectsBadCommands() {
        XCTAssertThrowsError(try StartCommand(folder: "/x", run: []).script(home: home)) {
            XCTAssertEqual($0 as? StartCommand.Problem, .emptyCommand)
        }
        XCTAssertThrowsError(try StartCommand(folder: "/x", run: ["a\u{0}b"]).script(home: home)) {
            XCTAssertEqual($0 as? StartCommand.Problem, .nulCharacter)
        }
        XCTAssertThrowsError(try StartCommand(folder: "relative", run: ["claude"]).script(home: home)) {
            XCTAssertEqual($0 as? StartCommand.Problem, .folderNotAbsolute)
        }
    }

    /// Runs the generated script with /bin/sh and checks every argument arrives byte for byte.
    func testArgumentsSurviveTheShellExactly() throws {
        let tricky = ["it's", "a;b", "$(touch /tmp/agent-overtime-pwned)", "two words", "line\nbreak", "출근 시험", "`id`", "*", "~/x", "\"q\""]
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ao-start-\(UUID().uuidString)/한글 it's")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

        let command = StartCommand(folder: folder.path, run: ["/usr/bin/printf", "%s\\0"] + tricky)
        let scriptURL = folder.deletingLastPathComponent().appendingPathComponent("start.command")
        try command.script(home: "/nonexistent").write(to: scriptURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let received = output.split(separator: 0, omittingEmptySubsequences: false).dropLast().map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(received, tricky.map { $0 == "~/x" ? "/nonexistent/x" : $0 }, "only a leading ~/ changes, on purpose")
        XCTAssertFalse(FileManager.default.fileExists(atPath: scriptURL.path), "the script deletes itself")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/agent-overtime-pwned"))
    }

    func testTildeOnlyAtTheStart() {
        let resolved = StartCommand(folder: "~", run: ["~/bin/tool", "a~/b"]).resolved(home: home)
        XCTAssertEqual(resolved, StartCommand(folder: "/Users/me", run: ["/Users/me/bin/tool", "a~/b"]))
    }

    func testParse() {
        XCTAssertEqual(StartCommand.parse("claude"), ["claude"])
        XCTAssertEqual(StartCommand.parse("  ./dev.sh   up "), ["./dev.sh", "up"])
        XCTAssertEqual(StartCommand.parse(#"tool "two words" 'it"s' '' x"#), ["tool", "two words", #"it"s"#, "", "x"])
        XCTAssertEqual(StartCommand.parse("echo $(id); ls"), ["echo", "$(id);", "ls"], "no shell meaning")
        // What the sheet's hint promises: terminal symbols arrive as plain arguments, never as operators.
        XCTAssertEqual(StartCommand.parse("claude && tmux | cat $HOME"), ["claude", "&&", "tmux", "|", "cat", "$HOME"])
        XCTAssertEqual(StartCommand.parse(#"./run "my project""#), ["./run", "my project"])
        XCTAssertEqual(StartCommand.parse(""), [])
    }

    func testFingerprintFollowsEveryByte() {
        let base = StartCommand(folder: "/a", run: ["claude"])
        XCTAssertEqual(base.fingerprint, StartCommand(folder: "/a", run: ["claude"]).fingerprint)
        XCTAssertNotEqual(base.fingerprint, StartCommand(folder: "/b", run: ["claude"]).fingerprint)
        XCTAssertNotEqual(base.fingerprint, StartCommand(folder: "/a", run: ["claude", "-p"]).fingerprint)
        XCTAssertNotEqual(StartCommand(folder: "/a", run: ["b c"]).fingerprint, StartCommand(folder: "/a", run: ["b", "c"]).fingerprint)
        XCTAssertEqual(base.fingerprint.count, 64)
    }

    func testRevealedShowsHiddenCharacters() {
        XCTAssertEqual(StartCommand.revealed("claude"), "claude")
        XCTAssertEqual(StartCommand.revealed("cla\u{200B}ude"), "cla⟨U+200B⟩ude")
        XCTAssertEqual(StartCommand.revealed("rm\u{202E}fdp.sh"), "rm⟨U+202E⟩fdp.sh")
        XCTAssertEqual(StartCommand.revealed("a\nb\u{7}"), "a⟨U+000A⟩b⟨U+0007⟩")
        XCTAssertEqual(StartCommand.revealed("a\u{00A0}b c"), "a⟨U+00A0⟩b c")
        XCTAssertEqual(StartCommand.revealed("출근 시험"), "출근 시험")
    }
}
