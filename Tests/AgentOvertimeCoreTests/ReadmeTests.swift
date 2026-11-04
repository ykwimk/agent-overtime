import XCTest

@testable import AgentOvertimeCore

/// README.md and README.ko.md say the same thing: the same sections, the same commands, and the connect commands
/// letter for letter as the app copies them. Bumping the tag in one place only fails here.
final class ReadmeTests: XCTestCase {
    private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    static let brewInstall = "brew install --cask ykwimk/tap/agent-overtime"

    private func lines(_ name: String) throws -> [String] {
        try String(contentsOf: repo.appendingPathComponent(name), encoding: .utf8).components(separatedBy: "\n")
    }

    func testBothReadmesMatchTheAppAndEachOther() throws {
        let english = try lines("README.md")
        let korean = try lines("README.ko.md")
        let sections = { (lines: [String]) in lines.filter { $0.hasPrefix("## ") }.count }
        XCTAssertGreaterThan(sections(english), 0)
        XCTAssertEqual(sections(english), sections(korean), "same sections in both")

        // Commands people copy: whole lines in code blocks, and inline `brew …` commands.
        func commands(_ lines: [String]) -> Set<String> {
            var found: Set<String> = []
            for line in lines {
                let text = line.trimmingCharacters(in: .whitespaces)
                if text.hasPrefix("/plugin ") || text.hasPrefix("brew ") || text.hasPrefix("shasum ") {
                    found.insert(text)
                }
                for (index, part) in line.components(separatedBy: "`").enumerated()
                where index % 2 == 1 && part.hasPrefix("brew ") {
                    found.insert(part)
                }
            }
            return found
        }
        XCTAssertEqual(commands(english), commands(korean))
        for (name, text) in [("README.md", english), ("README.ko.md", korean)] {
            XCTAssertTrue(text.joined(separator: "\n").contains(Release.connectCommands), name)
            XCTAssertTrue(text.contains(Self.brewInstall), name)
        }
    }

    /// What the documents promise about the network, in step with the app.
    func testNetworkPromisesMatchTheApp() throws {
        for name in ["README.md", "README.ko.md"] {
            let text = try lines(name).joined(separator: "\n")
            XCTAssertTrue(text.contains(UpdateCheck.latest.absoluteString), name)
            XCTAssertTrue(text.contains("brew upgrade --cask ykwimk/tap/agent-overtime"), name)
        }
        let english = try lines("README.md").joined(separator: "\n")
        XCTAssertFalse(english.contains("never checks for updates"))
        XCTAssertFalse(english.contains("Network: none"))
        let korean = try lines("README.ko.md").joined(separator: "\n")
        XCTAssertFalse(korean.contains("업데이트를 확인하지 않습니다"))
        XCTAssertFalse(korean.contains("네트워크: 없음"))
        XCTAssertFalse(try lines("CONTRIBUTING.md").joined().contains("no network access"))
        XCTAssertFalse(try lines("SECURITY.md").joined().contains("nothing over the network"))
    }
}
