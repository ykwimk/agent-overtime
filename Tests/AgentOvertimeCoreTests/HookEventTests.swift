import XCTest

@testable import AgentOvertimeCore

final class HookEventTests: XCTestCase {
    private func input(_ fields: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: fields)
    }

    func testKeepsOnlyAllowlistedFields() throws {
        let data = input([
            "hook_event_name": "PreToolUse", "session_id": "abc", "cwd": "/Users/me/shop",
            "tool_name": "Bash", "tool_input": ["command": "cat ~/.ssh/id_rsa"],
            "prompt": "secret plan", "transcript_path": "/Users/me/.claude/projects/x.jsonl",
            "permission_mode": "default",
        ])
        let event = try XCTUnwrap(HookEvent.fromHookInput(data, pid: 4242))
        XCTAssertEqual(event, HookEvent(kind: .preToolUse, session: "abc", cwd: "/Users/me/shop", pid: 4242))

        let wire = String(decoding: event.wireLine(), as: UTF8.self)
        for leaked in ["Bash", "ssh", "secret", "transcript", "projects", "default"] {
            XCTAssertFalse(wire.contains(leaked), "\(leaked) crossed the socket: \(wire)")
        }
        XCTAssertTrue(wire.hasSuffix("\n"))
    }

    func testAskUserQuestionIsTheOnlyToolFactKept() {
        let ask = HookEvent.fromHookInput(
            input(["hook_event_name": "PreToolUse", "session_id": "a", "cwd": "/x", "tool_name": "AskUserQuestion"]),
            pid: nil)
        let read = HookEvent.fromHookInput(
            input(["hook_event_name": "PreToolUse", "session_id": "a", "cwd": "/x", "tool_name": "Read"]), pid: nil)
        XCTAssertEqual(ask?.asksUser, true)
        XCTAssertEqual(read?.asksUser, false)
    }

    func testDropsUnknownEventsAndUnusedNotifications() {
        XCTAssertNil(
            HookEvent.fromHookInput(
                input(["hook_event_name": "PostToolUse", "session_id": "a", "cwd": "/x"]), pid: nil))
        for type in ["auth_success", "quota_auto_resume_fired", "plugin_notification", "agent_completed"] {
            XCTAssertNil(
                HookEvent.fromHookInput(
                    input([
                        "hook_event_name": "Notification", "session_id": "a", "cwd": "/x", "notification_type": type,
                    ]), pid: nil), type)
        }
        let idle = HookEvent.fromHookInput(
            input([
                "hook_event_name": "Notification", "session_id": "a", "cwd": "/x", "notification_type": "idle_prompt",
                "message": "Claude is waiting",
            ]), pid: nil)
        XCTAssertEqual(idle?.notification, "idle_prompt")
    }

    func testRejectsMissingOrRelativeFields() {
        XCTAssertNil(HookEvent.fromHookInput(input(["hook_event_name": "Stop", "cwd": "/x"]), pid: nil))
        XCTAssertNil(
            HookEvent.fromHookInput(
                input(["hook_event_name": "Stop", "session_id": "a", "cwd": "relative/path"]), pid: nil))
        XCTAssertNil(HookEvent.fromHookInput(Data("not json".utf8), pid: nil))
        XCTAssertNil(
            HookEvent.fromHookInput(
                input(["hook_event_name": "Stop", "session_id": "\u{200B}", "cwd": "/x"]), pid: nil))
    }

    func testStripsHiddenCharactersAndCapsLengths() throws {
        let data = input([
            "hook_event_name": "SubagentStart", "session_id": "s", "cwd": "/Users/me/ev\u{202E}il\n",
            "agent_id": String(repeating: "a", count: 500),
            "agent_type": "re\u{0}search\u{200B}er" + String(repeating: "x", count: 100),
        ])
        let event = try XCTUnwrap(HookEvent.fromHookInput(data, pid: 1))
        XCTAssertEqual(event.cwd, "/Users/me/evil")
        XCTAssertEqual(event.agentID?.count, Limits.id)
        XCTAssertEqual(event.agentType?.unicodeScalars.count, Limits.agentType)
        XCTAssertTrue(event.agentType!.hasPrefix("researcherxx"))
        XCTAssertNil(event.pid, "pid 1 (launchd) is never a session")
    }

    func testWireRoundTripAndRecheck() throws {
        let event = HookEvent(
            kind: .subagentStart, session: "s", cwd: "/a/b", agentID: "x", agentType: "planner", pid: 77)
        XCTAssertEqual(HookEvent.fromWire(event.wireLine().dropLast()), event)

        // Anything on this Mac can write to the socket: the app checks again.
        XCTAssertNil(HookEvent.fromWire(Data(#"{"e":"Exec","s":"s","d":"/a"}"#.utf8)))
        XCTAssertNil(HookEvent.fromWire(Data(#"{"e":"Stop","s":"s","d":"a"}"#.utf8)))
        XCTAssertNil(HookEvent.fromWire(Data(#"{"e":"Notification","s":"s","d":"/a","n":"auth_success"}"#.utf8)))
        let sneaky = try XCTUnwrap(HookEvent.fromWire(Data(#"{"e":"Stop","s":"s","d":"/a‮","t":"\u0007bell"}"#.utf8)))
        XCTAssertEqual(sneaky.cwd, "/a")
        XCTAssertEqual(sneaky.agentType, "bell")
        XCTAssertNil(HookEvent.fromWire(Data(repeating: 0x20, count: Limits.line + 1)))
    }
}
