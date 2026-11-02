import XCTest

@testable import AgentOvertimeCore

/// Checks the files users install into Claude Code: the exact hook command, which hooks block, and the names.
final class PluginTests: XCTestCase {
    private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private func json(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: repo.appendingPathComponent(path))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testHooksCallOnlyTheFixedHelperPaths() throws {
        let hooks = try XCTUnwrap(try json("plugin/hooks/hooks.json")["hooks"] as? [String: [[String: Any]]])
        XCTAssertEqual(Set(hooks.keys), Set(HookEvent.Kind.allCases.map(\.rawValue)))
        XCTAssertEqual(hooks.count, 10)
        XCTAssertNil(hooks["PostModelSwitch"]?.first?["matcher"], "every switch")

        for (event, groups) in hooks {
            for group in groups {
                let handlers = try XCTUnwrap(group["hooks"] as? [[String: Any]])
                for handler in handlers {
                    XCTAssertEqual(handler["type"] as? String, "command")
                    XCTAssertEqual(handler["command"] as? String, HookCommand.line, event)
                    if event == "SessionEnd" {
                        XCTAssertNil(handler["async"], "SessionEnd runs in the foreground so it is not cut off")
                        XCTAssertEqual(handler["timeout"] as? Int, 1)
                    } else {
                        XCTAssertEqual(handler["async"] as? Bool, true, "\(event) must never block Claude Code")
                    }
                }
            }
        }
        let notification = try XCTUnwrap(hooks["Notification"]?.first?["matcher"] as? String)
        XCTAssertEqual(Set(notification.split(separator: "|").map(String.init)), HookEvent.notifications)
    }

    /// The helper reads Show Details as the app writes it, from another process, by the app's id: on only for an
    /// exact true. A scratch domain stands in for the app's, so the real settings are never touched.
    func testTheHelperReadsShowDetailsOnlyWhenExactlyTrue() throws {
        let domain = "io.github.ykwimk.AgentOvertime.test-\(UUID().uuidString)"
        func defaults(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
        }
        defer { try? defaults(["delete", domain]) }
        XCTAssertFalse(ShowDetails.isOn(in: domain), "missing: off")
        for (type, value, on) in [("-bool", "true", true), ("-bool", "false", false), ("-int", "1", false)] {
            try defaults(["write", domain, ShowDetails.key, type, value])
            XCTAssertEqual(ShowDetails.isOn(in: domain), on, "\(type) \(value)")
        }
        try defaults(["write", domain, ShowDetails.key, "-string", "true"])
        XCTAssertFalse(ShowDetails.isOn(in: domain), "text: off")
    }

    /// The helper never opens the app's config.json, where nicknames and the start command live.
    func testTheHelperNeverNamesTheConfigFile() throws {
        let helper = repo.appendingPathComponent("Helper")
        for file in try FileManager.default.contentsOfDirectory(atPath: helper.path) {
            let text = try String(contentsOf: helper.appendingPathComponent(file), encoding: .utf8)
            XCTAssertFalse(text.contains("config.json"), file)
        }
    }

    func testHookCommandQuoting() {
        XCTAssertEqual(
            HookCommand.line,
            #"test -x '/Applications/AgentOvertime.app/Contents/MacOS/agent-overtime-hook' && exec '/Applications/AgentOvertime.app/Contents/MacOS/agent-overtime-hook'; test -x "$HOME/Applications/AgentOvertime.app/Contents/MacOS/agent-overtime-hook" && exec "$HOME/Applications/AgentOvertime.app/Contents/MacOS/agent-overtime-hook"; exit 0"#
        )
    }

    func testNamesMatchAndAvoidReservedWords() throws {
        let plugin = try json("plugin/.claude-plugin/plugin.json")
        let market = try json(".claude-plugin/marketplace.json")
        let entry = try XCTUnwrap((market["plugins"] as? [[String: Any]])?.first)
        XCTAssertEqual(plugin["name"] as? String, "agent-overtime")
        XCTAssertEqual(entry["name"] as? String, plugin["name"] as? String)
        XCTAssertEqual(entry["source"] as? String, "./plugin")
        let text =
            try String(contentsOf: repo.appendingPathComponent("plugin/.claude-plugin/plugin.json"), encoding: .utf8)
            + String(contentsOf: repo.appendingPathComponent(".claude-plugin/marketplace.json"), encoding: .utf8)
        XCTAssertNil(text.range(of: "claude|anthropic", options: [.regularExpression, .caseInsensitive]))
    }

    func testAppLocation() {
        XCTAssertEqual(AppLocation.check(bundlePath: "/Applications/AgentOvertime.app", home: "/Users/me"), .ok)
        XCTAssertEqual(
            AppLocation.check(bundlePath: "/Users/me/Applications/AgentOvertime.app", home: "/Users/me"), .ok)
        XCTAssertEqual(
            AppLocation.check(
                bundlePath: "/private/var/folders/x/AppTranslocation/ABC/d/AgentOvertime.app", home: "/Users/me"),
            .translocated)
        XCTAssertEqual(
            AppLocation.check(bundlePath: "/Users/me/Downloads/AgentOvertime.app", home: "/Users/me"),
            .notInApplications)
        XCTAssertEqual(
            AppLocation.check(bundlePath: "/Applications/Agent Overtime 2.app", home: "/Users/me"), .notInApplications)
    }
}
