import XCTest

@testable import AgentOvertimeCore

/// One release number everywhere: the app version, the plugin version, the top CHANGELOG entry and the tag the
/// connect commands pin. If the plugin version stays the same, Claude Code does not give users the new hooks.
final class VersionTests: XCTestCase {
    private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private func text(_ path: String) throws -> String {
        try String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8)
    }

    /// The first capture group of every match of `pattern` in `text`.
    private func captures(_ pattern: String, in text: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern, options: .anchorsMatchLines)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    func testAppPluginChangelogAndTagShareOneVersion() throws {
        let marketing = try captures(
            #"MARKETING_VERSION = ([^;]+);"#, in: text("AgentOvertime.xcodeproj/project.pbxproj"))
        XCTAssertFalse(marketing.isEmpty, "no MARKETING_VERSION in project.pbxproj")
        let plugin =
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: repo.appendingPathComponent("plugin/.claude-plugin/plugin.json")))
            as? [String: Any]
        let changelog = try captures(#"^## (v\S+)"#, in: text("CHANGELOG.md")).first

        let found: [(name: String, value: String)] =
            marketing.map { ("project.pbxproj MARKETING_VERSION", "v" + $0) } + [
                ("plugin.json version", (plugin?["version"] as? String).map { "v" + $0 } ?? "missing"),
                ("CHANGELOG.md top", changelog ?? "missing"),
                ("Release.tag", Release.tag),
            ]
        XCTAssertEqual(
            Set(found.map { $0.value }).count, 1,
            "versions differ: " + found.map { "\($0.name) = \($0.value)" }.joined(separator: ", "))
    }
}
