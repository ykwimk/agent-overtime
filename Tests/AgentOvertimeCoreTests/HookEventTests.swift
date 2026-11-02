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
        XCTAssertEqual(
            event, HookEvent(kind: .preToolUse, session: "abc", cwd: "/Users/me/shop", toolKind: .command, pid: 4242))

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
            "agent_type": "Ex\u{0}plo\u{200B}re" + String(repeating: "x", count: 100),
        ])
        let event = try XCTUnwrap(HookEvent.fromHookInput(data, pid: 1))
        XCTAssertEqual(event.cwd, "/Users/me/evil")
        XCTAssertEqual(event.agentID?.count, Limits.id)
        XCTAssertEqual(event.agentType?.unicodeScalars.count, Limits.agentType)
        XCTAssertTrue(event.agentType!.hasPrefix("Explorexx"))
        XCTAssertNil(event.pid, "pid 1 (launchd) is never a session")
    }

    private func preToolUse(_ tool: Any?, input toolInput: Any? = nil, agent: String? = nil) -> HookEvent? {
        var fields: [String: Any] = ["hook_event_name": "PreToolUse", "session_id": "s", "cwd": "/Users/me/my-project"]
        fields["tool_name"] = tool
        fields["tool_input"] = toolInput
        fields["agent_id"] = agent
        return HookEvent.fromHookInput(input(fields), pid: nil)
    }

    /// The built-in tools fall in their kinds by exact name; MCP tools, unknown and look-alike names and anything
    /// that is not text are "other", and the name never crosses the socket.
    func testToolKindsComeFromAFixedListOfNames() throws {
        let kinds: [(Any?, HookEvent.ToolKind)] = [
            ("Read", .read), ("NotebookRead", .read), ("Glob", .find), ("LS", .find), ("Grep", .grep), ("LSP", .lsp),
            ("Edit", .edit), ("MultiEdit", .edit), ("NotebookEdit", .edit), ("Write", .write), ("Bash", .command),
            ("PowerShell", .command), ("Monitor", .monitor), ("WebSearch", .web), ("WebFetch", .fetch),
            ("Agent", .team), ("Task", .team), ("SendMessage", .talk), ("TodoWrite", .tasks),
            ("TaskCreate", .tasks), ("TaskGet", .tasks), ("TaskUpdate", .tasks), ("TaskList", .tasks),
            ("Skill", .skill),
            // (a) MCP tools, with a server name in them, even one named like a built-in tool
            ("mcp__acme-payroll__read_file", .other), ("mcp__srv__TodoWrite", .other),
            // (b) unknown and look-alike names
            ("ReadX", .other), ("read", .other), ("todowrite", .other), ("Bash ", .other), ("SomethingNew", .other),
            (42, .other), (NSNull(), .other), (nil, .other),
        ]
        for (name, kind) in kinds {
            let event = try XCTUnwrap(preToolUse(name), "\(String(describing: name))")
            XCTAssertEqual(event.toolKind, kind, "\(String(describing: name))")
        }
        let mcp = String(decoding: try XCTUnwrap(preToolUse("mcp__acme-payroll__read_file")).wireLine(), as: UTF8.self)
        for leaked in ["mcp", "acme", "payroll", "read_file"] {
            XCTAssertFalse(mcp.contains(leaked), "\(leaked) crossed the socket: \(mcp)")
        }
        XCTAssertTrue(mcp.contains(#""k":"other""#), mcp)
    }

    /// (c) Only a PreToolUse has a kind: not a PermissionRequest (its tool name is not read) or any other event,
    /// and not AskUserQuestion, which is a wait.
    func testOnlyAPreToolUseHasAKind() throws {
        for name in ["PermissionRequest", "Stop", "SubagentStart", "UserPromptSubmit"] {
            let event = HookEvent.fromHookInput(
                input([
                    "hook_event_name": name, "session_id": "s", "cwd": "/x", "tool_name": "SendMessage",
                    "tool_input": ["to": "Plan", "message": "secret"],
                ]), pid: nil)
            XCTAssertNil(event?.toolKind, name)
            XCTAssertEqual(event?.sendsMessage, false, name)
            XCTAssertNil(event?.recipient, name)
        }
        let ask = try XCTUnwrap(preToolUse("AskUserQuestion"))
        XCTAssertTrue(ask.asksUser)
        XCTAssertNil(ask.toolKind)
        // Faked on the socket, the app drops them too.
        let faked = try XCTUnwrap(
            HookEvent.fromWire(Data(#"{"e":"PermissionRequest","s":"s","d":"/x","k":"edit","m":true,"r":"Plan"}"#.utf8))
        )
        XCTAssertNil(faked.toolKind)
        XCTAssertFalse(faked.sendsMessage)
        XCTAssertNil(faked.recipient)
    }

    /// (d) A kind the app doesn't know is no kind, and the event is kept; only fixed words come out of a kind.
    func testAnUnknownKindOnTheSocketIsNoKind() throws {
        let event = try XCTUnwrap(
            HookEvent.fromWire(Data(#"{"e":"PreToolUse","s":"s","d":"/x","k":"rm -rf ~/","a":"x"}"#.utf8)))
        XCTAssertNil(event.toolKind)
        XCTAssertEqual(event.agentID, "x")
        // v0.3's six values still read the same.
        for old in ["read", "edit", "command", "web", "team", "other"] {
            let line = Data(#"{"e":"PreToolUse","s":"s","d":"/x","k":"\#(old)"}"#.utf8)
            XCTAssertEqual(try XCTUnwrap(HookEvent.fromWire(line)).toolKind?.rawValue, old)
        }
        XCTAssertEqual(HookEvent.ToolKind.allCases.count, 15)
    }

    /// Values 2: the recipient is read only from a SendMessage's `to` (a); nothing else of its input crosses the
    /// socket (b); hidden characters are dropped and one longer than 128 is dropped whole, never cut (c).
    func testOnlyASendMessageRecipientIsKept() throws {
        let other = try XCTUnwrap(preToolUse("Agent", input: ["to": "Plan", "prompt": "do it"]))
        XCTAssertFalse(other.sendsMessage)
        XCTAssertNil(other.recipient, "(a) not SendMessage")

        let message = try XCTUnwrap(
            preToolUse(
                "SendMessage",
                input: [
                    "to": "Plan", "message": "the launch codes", "summary": "secret summary", "notify_when_idle": true,
                ], agent: "e1"))
        XCTAssertTrue(message.sendsMessage)
        XCTAssertEqual(message.recipient, "Plan")
        XCTAssertEqual(message.toolKind, .talk)
        let wire = String(decoding: message.wireLine(), as: UTF8.self)
        for leaked in ["launch", "secret", "summary", "notify", "SendMessage", "message\""] {
            XCTAssertFalse(wire.contains(leaked), "(b) \(leaked) crossed the socket: \(wire)")
        }

        XCTAssertEqual(
            try XCTUnwrap(preToolUse("SendMessage", input: ["to": "Pl\u{200B}a\u{202E}n"])).recipient, "Plan")
        let long = String(repeating: "a", count: 129)
        XCTAssertNil(try XCTUnwrap(preToolUse("SendMessage", input: ["to": long])).recipient, "(c) dropped, not cut")
        // Counted whole, before spaces are trimmed: a space at 129 doesn't let a cut name through.
        for spaced in [
            String(repeating: "a", count: 128) + " bbb", "Plan" + String(repeating: " ", count: 125) + "Other",
        ] {
            XCTAssertNil(
                try XCTUnwrap(preToolUse("SendMessage", input: ["to": spaced])).recipient, "(c) \(spaced.count)")
        }
        let fits = String(repeating: "a", count: 128)
        XCTAssertEqual(try XCTUnwrap(preToolUse("SendMessage", input: ["to": fits])).recipient, fits)
        XCTAssertNil(try XCTUnwrap(preToolUse("SendMessage", input: ["to": ["Plan"]])).recipient, "not text")
        XCTAssertNil(try XCTUnwrap(preToolUse("SendMessage", input: "to")).recipient)
        // The socket is checked the same way.
        let sneaky = try XCTUnwrap(
            HookEvent.fromWire(Data(#"{"e":"PreToolUse","s":"s","d":"/x","m":true,"r":"Pl​an"}"#.utf8)))
        XCTAssertEqual(sneaky.recipient, "Plan")
        let unsent = try XCTUnwrap(HookEvent.fromWire(Data(#"{"e":"PreToolUse","s":"s","d":"/x","r":"Plan"}"#.utf8)))
        XCTAssertNil(unsent.recipient, "no recipient without a SendMessage")
        let tooLong = try XCTUnwrap(
            HookEvent.fromWire(Data(#"{"e":"PreToolUse","s":"s","d":"/x","m":true,"r":"\#(long)"}"#.utf8)))
        XCTAssertNil(tooLong.recipient)
    }

    /// Everything one socket line can carry, from a hook input full of other things: these fields and no others.
    func testTheSocketLineCarriesOnlyTheseFields() throws {
        let event = try XCTUnwrap(
            HookEvent.fromHookInput(
                input([
                    "hook_event_name": "PreToolUse", "session_id": "abc", "cwd": "/Users/me/my-project",
                    "agent_id": "e1", "agent_type": "Explore", "tool_name": "SendMessage", "tool_use_id": "toolu_1",
                    "tool_input": ["to": "Plan", "message": "hello", "summary": "hi"], "mcp_server": "srv",
                    "prompt": "p", "transcript_path": "/t.jsonl", "permission_mode": "default",
                ]), pid: 4242))
        let line = event.wireLine()
        print("socket line:", String(decoding: line, as: UTF8.self), terminator: "")
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
        XCTAssertEqual(Set(fields.keys), ["e", "s", "d", "a", "t", "q", "k", "m", "r", "p"])
        XCTAssertEqual(fields["k"] as? String, "talk")
        XCTAssertEqual(fields["r"] as? String, "Plan")
    }

    /// (d)/(e) With the kind and a 128-character recipient, an event from an ordinary path with ids and a name still
    /// fits in one socket line.
    func testTheNewFieldsStillFitInOneLine() throws {
        let path = "/Users/someone-with-a-long-name/Documents/Projects/2026/clients/my-project/packages/web-app"
        let message = try XCTUnwrap(
            HookEvent.fromHookInput(
                input([
                    "hook_event_name": "PreToolUse", "session_id": String(repeating: "s", count: 128), "cwd": path,
                    "agent_id": String(repeating: "a", count: 128), "agent_type": String(repeating: "t", count: 64),
                    "tool_name": "SendMessage", "tool_input": ["to": String(repeating: "r", count: 128)],
                ]), pid: 99_999))
        XCTAssertLessThan(message.wireLine().count, Limits.line / 4)
        XCTAssertEqual(HookEvent.fromWire(message.wireLine().dropLast()), message)
    }

    /// A v0.2 helper with this app, and this helper with a v0.2 app, keep each other's events: missing fields read as
    /// none, unknown ones are ignored.
    func testOlderAndNewerHelpersAndAppsKeepEachOthersEvents() throws {
        let older = Data(#"{"e":"PreToolUse","s":"s","d":"/x","a":"e1","t":"Explore","q":false,"p":42}"#.utf8)
        let read = try XCTUnwrap(HookEvent.fromWire(older))
        XCTAssertNil(read.toolKind)
        XCTAssertFalse(read.sendsMessage)
        XCTAssertNil(read.recipient)

        struct OlderApp: Decodable {
            let e: String
            let s: String
            let d: String
            let a: String?
            let q: Bool?
        }
        let newer = try XCTUnwrap(preToolUse("SendMessage", input: ["to": "Plan"], agent: "e1")).wireLine()
        let seen = try JSONDecoder().decode(OlderApp.self, from: newer)
        XCTAssertEqual(seen.e, "PreToolUse")
        XCTAssertEqual(seen.a, "e1")
    }

    func testWireRoundTripAndRecheck() throws {
        let event = HookEvent(
            kind: .subagentStart, session: "s", cwd: "/a/b", agentID: "x", agentType: "Plan", pid: 77)
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
