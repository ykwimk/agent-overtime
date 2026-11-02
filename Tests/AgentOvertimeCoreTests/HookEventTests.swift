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

    private func details(_ tool: String, _ toolInput: [String: Any], on: Bool = true) throws -> HookEvent {
        let fields: [String: Any] = [
            "hook_event_name": "PreToolUse", "session_id": "s", "cwd": "/Users/me/my-project", "tool_name": tool,
            "tool_input": toolInput,
        ]
        return try XCTUnwrap(HookEvent.fromHookInput(input(fields), pid: nil, details: on))
    }

    private func wire(_ event: HookEvent) -> String { String(decoding: event.wireLine(), as: UTF8.self) }

    /// Each tool opens only its own fields; text becomes line counts, other fields and other items stay closed.
    func testDetailsOpenOnlyTheirFields() throws {
        let read = try details("Read", ["file_path": "/Users/me/my-project/src/app.ts", "offset": 10])
        XCTAssertEqual(read.file, "src/app.ts")
        XCTAssertNil(read.linesAdded)

        let write = try details(
            "Write", ["file_path": "/Users/me/my-project/notes.md", "content": "the launch codes\nline two\n"])
        XCTAssertEqual(write.file, "notes.md")
        XCTAssertEqual(write.linesAdded, 2)
        XCTAssertEqual(write.linesRemoved, 0)

        let edit = try details(
            "Edit",
            [
                "file_path": "/Users/me/my-project/src/ui/button.css", "old_string": "a\nthe old secret\nc",
                "new_string": "a\nthe new secret\nmore\nc", "replace_all": true,
            ])
        XCTAssertEqual(edit.file, "…/ui/button.css")
        XCTAssertEqual(edit.linesAdded, 2)
        XCTAssertEqual(edit.linesRemoved, 1)

        let multi = try details(
            "MultiEdit",
            [
                "file_path": "/Users/me/my-project/a.swift",
                "edits": [["old_string": "x", "new_string": "y\nz"], ["old_string": 4, "new_string": "w"]],
            ])
        XCTAssertEqual(multi.linesAdded, 2, "only the edit with text fields counts")

        let notebook = try details(
            "NotebookEdit", ["notebook_path": "/Users/me/my-project/n.ipynb", "new_source": "the secret cell"])
        XCTAssertEqual(notebook.file, "n.ipynb")
        XCTAssertNil(notebook.linesAdded, "new_source is not opened")

        let todo = try details(
            "TodoWrite",
            [
                "todos": [
                    ["content": "Match the button colours", "status": "completed", "activeForm": "Matching"],
                    ["content": "Fix the header", "status": "in_progress", "activeForm": "Fixing the header"],
                    ["content": "a private plan", "status": "pending", "activeForm": "Planning privately"],
                ]
            ])
        XCTAssertEqual(todo.taskAction, .todo)
        XCTAssertEqual(todo.todoTotal, 3)
        XCTAssertEqual(todo.todoDone, 1)
        XCTAssertEqual(todo.taskTitle, "Fix the header")

        let create = try details(
            "TaskCreate", ["subject": "Write tests", "description": "the secret details", "metadata": ["k": "v"]])
        XCTAssertEqual(create.taskAction, .create)
        XCTAssertEqual(create.taskTitle, "Write tests")
        let update = try details(
            "TaskUpdate",
            ["taskId": "3", "status": "in_progress", "owner": "secret-owner", "description": "the secret details"])
        XCTAssertEqual(update.taskID, "3")
        XCTAssertEqual(update.taskStatus, .inProgress)
        XCTAssertNil(update.taskTitle)

        // A command, a search or a fetch that has a path in it is never opened.
        let bash = try details("Bash", ["command": "cat /Users/me/secret", "file_path": "/Users/me/secret"])
        XCTAssertNil(bash.file)
        let session = try XCTUnwrap(
            HookEvent.fromHookInput(
                input([
                    "hook_event_name": "SessionStart", "session_id": "s", "cwd": "/x", "model": "claude-opus-4-7",
                    "pricing": ["input": 5], "source": "startup",
                ]), pid: nil, details: true))
        XCTAssertEqual(session.model, "claude-opus-4-7")

        for event in [read, write, edit, multi, notebook, todo, create, update, bash, session] {
            let line = wire(event)
            for leaked in [
                "launch", "secret", "private", "Planning", "Matching", "colours", "metadata", "offset", "pricing",
                "startup", "replace",
            ] {
                XCTAssertFalse(line.contains(leaked), "\(leaked) crossed the socket: \(line)")
            }
            XCTAssertFalse(event.file?.contains("/Users") ?? false, "never the full path")
        }
    }

    /// A model switch: the new model's name only, never the old one or the cost figures.
    func testAModelSwitchKeepsOnlyTheNewModel() throws {
        let data = input([
            "hook_event_name": "PostModelSwitch", "session_id": "s", "cwd": "/x", "from_model": "claude-earlier",
            "to_model": "claude-sonnet-4-5", "estimated_cache_write_usd": 1.25, "pricing": ["input": 3],
        ])
        let event = try XCTUnwrap(HookEvent.fromHookInput(data, pid: nil, details: true))
        XCTAssertEqual(event.kind, .postModelSwitch)
        XCTAssertEqual(event.model, "claude-sonnet-4-5")
        let line = wire(event)
        for leaked in ["earlier", "1.25", "pricing", "usd"] { XCTAssertFalse(line.contains(leaked), line) }
        XCTAssertNil(try XCTUnwrap(HookEvent.fromHookInput(data, pid: nil)).model, "off")
    }

    /// With Show Details off nothing of it is opened: v0.3's line.
    func testDetailsOffOpensNothing() throws {
        let edit = try details(
            "Edit", ["file_path": "/Users/me/my-project/a.swift", "old_string": "a", "new_string": "b"], on: false)
        XCTAssertEqual(edit, HookEvent(kind: .preToolUse, session: "s", cwd: "/Users/me/my-project", toolKind: .edit))
        let todo = try details("TodoWrite", ["todos": [["content": "x", "status": "in_progress"]]], on: false)
        XCTAssertNil(todo.taskAction)
        XCTAssertNil(todo.taskTitle)
    }

    /// Near the 8 MiB input limit the helper's work stays well inside 0.5 s, and no text crosses.
    func testAHugeWriteIsCountedQuicklyAndNeverSent() throws {
        let content = String(repeating: "secret line of code\n", count: 380_000)  // 7.6 MB
        let data = input([
            "hook_event_name": "PreToolUse", "session_id": "s", "cwd": "/Users/me/my-project", "tool_name": "Write",
            "tool_input": ["file_path": "/Users/me/my-project/big.txt", "content": content],
        ])
        XCTAssertLessThan(data.count, Limits.hookInput)
        // Reading the JSON is v0.3's own cost at this size; counting is what details add. The helper stops itself at
        // 0.5 s (a test build on a busy Mac runs well behind the release helper, hence the whole at 1 s).
        let started = Date()
        let event = try XCTUnwrap(HookEvent.fromHookInput(data, pid: nil, details: true))
        let line = event.wireLine()
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        let counting = Date()
        XCTAssertEqual(Detail.lines(content), 380_000)
        XCTAssertLessThan(Date().timeIntervalSince(counting), 0.5)
        XCTAssertEqual(event.linesAdded, 380_000)
        XCTAssertFalse(String(decoding: line, as: UTF8.self).contains("secret"))
    }

    /// One socket line at most: past it the details go in turn (title, model, file, line counts), the rest stays.
    func testAnOverlongLineDropsTheDetailsInTurn() throws {
        // A folder of 3801 bytes: with the file the line is too long, without it and the title it fits.
        var event = HookEvent(
            kind: .preToolUse, session: "s", cwd: "/" + String(repeating: "😀", count: 950), toolKind: .edit)
        event.file = String(repeating: "파", count: 128)
        event.linesAdded = 5
        event.linesRemoved = 2
        event.taskAction = .create
        event.taskTitle = String(repeating: "제", count: 80)
        let line = event.wireLine()
        XCTAssertLessThanOrEqual(line.count, Limits.line)
        let back = try XCTUnwrap(HookEvent.fromWire(line.dropLast()))
        XCTAssertNil(back.taskTitle, "the title goes first")
        XCTAssertNil(back.file, "then the file")
        XCTAssertEqual(back.linesAdded, 5, "the counts stay while they fit")
        XCTAssertEqual(back.cwd, event.cwd, "v0.3's fields are never touched")

        event.taskTitle = "short"
        event.file = "app.ts"
        XCTAssertEqual(try XCTUnwrap(HookEvent.fromWire(event.wireLine().dropLast())).taskTitle, "short", "fits")
    }

    /// The app checks every detail again; one that fails is dropped on its own and the event is kept.
    func testTheAppChecksEachDetailOnItsOwn() throws {
        let long = String(repeating: "a", count: 300)
        let line = Data(
            #"{"e":"PreToolUse","s":"s","d":"/x","k":"edit","f":"ev‮il\#(long)","la":-1,"lr":3,"ta":"update","ti":"\#(long)","ts":"bogus","tt":"t","mo":"claude-x"}"#
                .utf8)
        let event = try XCTUnwrap(HookEvent.fromWire(line))
        XCTAssertEqual(event.file?.count, Detail.file)
        XCTAssertEqual(event.file?.hasPrefix("evil"), true)
        XCTAssertNil(event.linesAdded, "out of range")
        XCTAssertEqual(event.linesRemoved, 3)
        XCTAssertNil(event.taskID, "too long: dropped whole")
        XCTAssertNil(event.taskAction, "an update needs its id")
        XCTAssertNil(event.taskTitle)
        XCTAssertNil(event.model, "only on SessionStart")
        XCTAssertEqual(event.toolKind, .edit)

        let todo = try XCTUnwrap(
            HookEvent.fromWire(Data(#"{"e":"PreToolUse","s":"s","d":"/x","ta":"todo","tn":3,"td":5}"#.utf8)))
        XCTAssertNil(todo.todoDone, "more done than there are")
        XCTAssertNil(todo.todoTotal)
        let stop = try XCTUnwrap(
            HookEvent.fromWire(Data(#"{"e":"Stop","s":"s","d":"/x","f":"a.ts","la":1,"ta":"todo","tn":1,"td":1}"#.utf8))
        )
        XCTAssertNil(stop.file, "details only on the events that have them")
        XCTAssertNil(stop.linesAdded)
        XCTAssertNil(stop.taskAction)
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
