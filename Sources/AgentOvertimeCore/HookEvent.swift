import Foundation

/// One status event, cut down to the fields the office needs.
/// Claude Code's hook input also carries tool names and input, prompts, file paths and transcripts. `fromHookInput`
/// derives only a coarse tool kind (and a SendMessage recipient) from them; nothing else crosses the socket.
public struct HookEvent: Codable, Equatable {
    /// What a PreToolUse is about to do, from a fixed list of Claude Code's built-in tools. One short value on the
    /// socket; the tool's name never is. The first six are v0.3's values, read the same; an app that doesn't know a
    /// value reads none.
    public enum ToolKind: String, Codable, CaseIterable {
        case read, edit, command, web, team, other
        case find, grep, lsp, write, monitor, fetch, talk, tasks, skill

        /// Compared letter for letter with the built-in tools' names (code.claude.com/docs/en/tools-reference).
        /// MCP tools (`mcp__server__tool`), names not on the list and anything that is not text are `.other`; no
        /// prefix or substring test, so a server's own naming never lands in a built-in kind.
        public static func of(_ toolName: Any?) -> ToolKind {
            switch toolName as? String {
            case "Read", "NotebookRead": return .read
            case "Glob", "LS": return .find
            case "Grep": return .grep
            case "LSP": return .lsp
            case "Edit", "MultiEdit", "NotebookEdit": return .edit
            case "Write": return .write
            case "Bash", "PowerShell": return .command
            case "Monitor": return .monitor
            case "WebSearch": return .web
            case "WebFetch": return .fetch
            case "Agent", "Task": return .team
            case "SendMessage": return .talk
            case "TodoWrite", "TaskCreate", "TaskGet", "TaskUpdate", "TaskList": return .tasks
            case "Skill": return .skill
            default: return .other
            }
        }
    }

    public enum Kind: String, Codable, CaseIterable {
        case sessionStart = "SessionStart"
        case sessionEnd = "SessionEnd"
        case userPromptSubmit = "UserPromptSubmit"
        case preToolUse = "PreToolUse"
        case permissionRequest = "PermissionRequest"
        case notification = "Notification"
        case stop = "Stop"
        case subagentStart = "SubagentStart"
        case subagentStop = "SubagentStop"
    }

    /// Notification types that change a state. Everything else (auth_success, quota_*, plugin_notification…) is dropped.
    static let notifications: Set<String> = [
        "permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input", "idle_prompt",
    ]

    public var kind: Kind
    public var session: String
    public var cwd: String
    public var agentID: String?
    public var agentType: String?
    public var notification: String?
    /// True only for PreToolUse of AskUserQuestion. The tool name itself is not kept.
    public var asksUser = false
    /// The kind of tool a PreToolUse is about to run; nil for anything else and for AskUserQuestion.
    public var toolKind: ToolKind?
    /// True only for PreToolUse of SendMessage, and then its recipient (the `to` field, nothing else of its
    /// input). The app matches the recipient against teammates at a desk and drops it.
    public var sendsMessage = false
    public var recipient: String?
    /// The Claude Code process, so the app can tell when a session is gone without a SessionEnd.
    public var pid: Int32?

    /// What a task tool did to the task list.
    public enum TaskAction: String, Codable {
        /// TodoWrite: the whole list again.
        case todo
        /// TaskCreate: one more task, its id not known yet.
        case create
        /// TaskUpdate: one task by its id.
        case update
    }

    public enum TaskStatus: String, Codable {
        case pending, completed, deleted
        case inProgress = "in_progress"
    }

    // Details, only with Show Details on (see `fromHookInput`), each one that is wrong or too long dropped on its own.
    /// The file a Read, Write, Edit or NotebookEdit works on, shortened in the helper (`Detail.shortPath`).
    public var file: String?
    /// Lines an edit adds and removes, counted in the helper; the text itself never leaves it.
    public var linesAdded: Int?
    public var linesRemoved: Int?
    public var taskAction: TaskAction?
    /// TodoWrite's whole list: how many tasks, and how many done.
    public var todoTotal: Int?
    public var todoDone: Int?
    /// TaskUpdate's task.
    public var taskID: String?
    public var taskStatus: TaskStatus?
    /// The task in progress (TodoWrite), the new one (TaskCreate) or the one changed (TaskUpdate).
    public var taskTitle: String?
    /// The session's model, from SessionStart.
    public var model: String?

    enum CodingKeys: String, CodingKey {
        case kind = "e"
        case session = "s"
        case cwd = "d"
        case agentID = "a"
        case agentType = "t"
        case notification = "n"
        case asksUser = "q"
        case toolKind = "k"
        case sendsMessage = "m"
        case recipient = "r"
        case pid = "p"
        case file = "f"
        case linesAdded = "la"
        case linesRemoved = "lr"
        case taskAction = "ta"
        case todoTotal = "tn"
        case todoDone = "td"
        case taskID = "ti"
        case taskStatus = "ts"
        case taskTitle = "tt"
        case model = "mo"
    }

    public init(
        kind: Kind, session: String, cwd: String, agentID: String? = nil, agentType: String? = nil,
        notification: String? = nil, asksUser: Bool = false, toolKind: ToolKind? = nil, sendsMessage: Bool = false,
        recipient: String? = nil, pid: Int32? = nil
    ) {
        self.kind = kind
        self.session = session
        self.cwd = cwd
        self.agentID = agentID
        self.agentType = agentType
        self.notification = notification
        self.asksUser = asksUser
        self.toolKind = toolKind
        self.sendsMessage = sendsMessage
        self.recipient = recipient
        self.pid = pid
    }

    /// A helper older than the app sends none of the newer fields, and they read as empty; a kind this app doesn't
    /// know reads as none, the event itself stays. (An older app ignores fields it doesn't know.)
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        session = try c.decode(String.self, forKey: .session)
        cwd = try c.decode(String.self, forKey: .cwd)
        agentID = try c.decodeIfPresent(String.self, forKey: .agentID)
        agentType = try c.decodeIfPresent(String.self, forKey: .agentType)
        notification = try c.decodeIfPresent(String.self, forKey: .notification)
        asksUser = try c.decodeIfPresent(Bool.self, forKey: .asksUser) ?? false
        toolKind = (try? c.decodeIfPresent(String.self, forKey: .toolKind)).flatMap { $0.flatMap(ToolKind.init) }
        sendsMessage = (try? c.decodeIfPresent(Bool.self, forKey: .sendsMessage)) ?? false
        recipient = try? c.decodeIfPresent(String.self, forKey: .recipient)
        pid = try c.decodeIfPresent(Int32.self, forKey: .pid)
        file = (try? c.decodeIfPresent(String.self, forKey: .file)) ?? nil
        linesAdded = (try? c.decodeIfPresent(Int.self, forKey: .linesAdded)) ?? nil
        linesRemoved = (try? c.decodeIfPresent(Int.self, forKey: .linesRemoved)) ?? nil
        taskAction = (try? c.decodeIfPresent(TaskAction.self, forKey: .taskAction)) ?? nil
        todoTotal = (try? c.decodeIfPresent(Int.self, forKey: .todoTotal)) ?? nil
        todoDone = (try? c.decodeIfPresent(Int.self, forKey: .todoDone)) ?? nil
        taskID = (try? c.decodeIfPresent(String.self, forKey: .taskID)) ?? nil
        taskStatus = (try? c.decodeIfPresent(TaskStatus.self, forKey: .taskStatus)) ?? nil
        taskTitle = (try? c.decodeIfPresent(String.self, forKey: .taskTitle)) ?? nil
        model = (try? c.decodeIfPresent(String.self, forKey: .model)) ?? nil
    }

    // MARK: helper side

    /// Reads Claude Code's hook JSON and keeps only the allowlisted fields; with `details`, also the few fields
    /// `readDetails` opens.
    public static func fromHookInput(_ data: Data, pid: Int32?, details: Bool = false) -> HookEvent? {
        guard data.count <= Limits.hookInput,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let name = object["hook_event_name"] as? String,
            let kind = Kind(rawValue: name),
            let session = object["session_id"] as? String,
            let cwd = object["cwd"] as? String
        else { return nil }
        // Only a PreToolUse's tool is looked at (a PermissionRequest's tool name and input are not read), and only
        // SendMessage's input is opened, for its `to` alone.
        let tool = kind == .preToolUse ? object["tool_name"] : nil
        let sendsMessage = tool as? String == "SendMessage"
        var event = HookEvent(
            kind: kind, session: session, cwd: cwd,
            agentID: object["agent_id"] as? String,
            agentType: object["agent_type"] as? String,
            notification: object["notification_type"] as? String,
            asksUser: tool as? String == "AskUserQuestion",
            toolKind: kind == .preToolUse ? ToolKind.of(tool) : nil,
            sendsMessage: sendsMessage,
            recipient: sendsMessage ? (object["tool_input"] as? [String: Any])?["to"] as? String : nil,
            pid: pid
        )
        if details { event.readDetails(object) }
        return event.cleaned()
    }

    /// The detail fields, each from the one or two input fields named here and nothing else of the input; a field
    /// of another type is dropped. Edit texts and file contents only ever become line counts.
    private mutating func readDetails(_ object: [String: Any]) {
        if kind == .sessionStart { model = object["model"] as? String }
        guard kind == .preToolUse, let input = object["tool_input"] as? [String: Any] else { return }
        let folder = cwd
        let path = { (key: String) in (input[key] as? String).flatMap { Detail.shortPath($0, in: folder) } }
        switch object["tool_name"] as? String {
        case "Read":
            file = path("file_path")
        case "Write":
            file = path("file_path")
            if let content = input["content"] as? String { (linesAdded, linesRemoved) = (Detail.lines(content), 0) }
        case "Edit":
            // replace_all changes every match, but how many there are is not known: counted as one.
            file = path("file_path")
            if let old = input["old_string"] as? String, let new = input["new_string"] as? String {
                (linesAdded, linesRemoved) = Detail.lineChange(old: old, new: new)
            }
        case "MultiEdit":
            file = path("file_path")
            if let edits = input["edits"] as? [[String: Any]] {
                let changes = edits.compactMap { edit -> (added: Int, removed: Int)? in
                    guard let old = edit["old_string"] as? String, let new = edit["new_string"] as? String else {
                        return nil
                    }
                    return Detail.lineChange(old: old, new: new)
                }
                linesAdded = min(changes.reduce(0) { $0 + $1.added }, Detail.maxLines)
                linesRemoved = min(changes.reduce(0) { $0 + $1.removed }, Detail.maxLines)
            }
        case "NotebookEdit":
            file = path("notebook_path")
        case "TodoWrite":
            // The statuses of all, the words of the one in progress only.
            guard let todos = input["todos"] as? [[String: Any]] else { return }
            taskAction = .todo
            todoTotal = min(todos.count, Detail.maxTasks)
            todoDone = min(todos.filter { $0["status"] as? String == "completed" }.count, Detail.maxTasks)
            if let doing = todos.first(where: { $0["status"] as? String == "in_progress" }) {
                taskTitle = doing["content"] as? String ?? doing["activeForm"] as? String
            }
        case "TaskCreate":
            taskAction = .create
            taskTitle = input["subject"] as? String ?? input["activeForm"] as? String
        case "TaskUpdate":
            guard let id = input["taskId"] as? String else { return }
            taskAction = .update
            taskID = id
            taskStatus = (input["status"] as? String).flatMap(TaskStatus.init)
            taskTitle = input["subject"] as? String
        default:
            break
        }
    }

    /// One line for the socket, newline included, at most `Limits.line` bytes: past that the details go one at a
    /// time (the task title, the model, the file, the line counts) and the rest is kept.
    public func wireLine() -> Data {
        var event = self
        let drops: [(inout HookEvent) -> Void] = [
            { $0.taskTitle = nil }, { $0.model = nil }, { $0.file = nil },
            {
                $0.linesAdded = nil
                $0.linesRemoved = nil
            },
        ]
        var data = (try? JSONEncoder().encode(event)) ?? Data()
        for drop in drops where data.count >= Limits.line {
            drop(&event)
            data = (try? JSONEncoder().encode(event)) ?? Data()
        }
        data.append(0x0A)
        return data
    }

    // MARK: app side

    /// The socket is a trust boundary: any process of this user can write to it, so everything is checked again.
    public static func fromWire(_ line: Data) -> HookEvent? {
        guard line.count <= Limits.line, let event = try? JSONDecoder().decode(HookEvent.self, from: line) else {
            return nil
        }
        return event.cleaned()
    }

    /// Strips hidden characters, caps lengths and drops events the office does not use.
    func cleaned() -> HookEvent? {
        guard let session = Sanitize.clean(session, max: Limits.id),
            let cwd = Sanitize.clean(cwd, max: Limits.cwd), cwd.hasPrefix("/")
        else { return nil }
        var event = self
        event.session = session
        event.cwd = cwd
        event.agentID = agentID.flatMap { Sanitize.clean($0, max: Limits.id) }
        event.agentType = agentType.flatMap { Sanitize.clean($0, max: Limits.agentType) }
        event.notification = nil
        if kind == .notification {
            guard let type = notification, Self.notifications.contains(type) else { return nil }
            event.notification = type
        }
        if kind != .preToolUse || asksUser { event.toolKind = nil }
        // A recipient only with a SendMessage about to go; hidden characters dropped, and one longer than an id is
        // dropped whole rather than cut (a cut name could match another teammate).
        event.sendsMessage = kind == .preToolUse && sendsMessage
        event.recipient = nil
        if event.sendsMessage, let to = recipient, let clean = Sanitize.clean(to, max: .max),
            clean.unicodeScalars.count <= Limits.id
        {
            event.recipient = clean
        }
        if let pid, pid <= 1 { event.pid = nil }
        event.cleanDetails()
        return event
    }

    /// The details again, each on its own: only on the events that carry them, in range, hidden characters dropped
    /// and capped. One that fails is dropped, the event kept.
    private mutating func cleanDetails() {
        let tool = kind == .preToolUse
        let within = { (value: Int?, max: Int) in value.flatMap { (0...max).contains($0) ? $0 : nil } }
        file = tool ? file.flatMap { Detail.capped($0, Detail.file) } : nil
        linesAdded = tool ? within(linesAdded, Detail.maxLines) : nil
        linesRemoved = tool ? within(linesRemoved, Detail.maxLines) : nil
        if !tool { taskAction = nil }
        let todo = taskAction == .todo
        todoTotal = todo ? within(todoTotal, Detail.maxTasks) : nil
        todoDone = todo ? todoTotal.flatMap { within(todoDone, $0) } : nil
        if todoDone == nil { todoTotal = nil }
        // An id is matched against others, so one too long is dropped whole rather than cut.
        let update = taskAction == .update
        taskID =
            update ? taskID.flatMap { Sanitize.clean($0, max: .max) }.flatMap { $0.count <= Limits.id ? $0 : nil } : nil
        if update, taskID == nil { taskAction = nil }
        taskStatus = taskAction == .update ? taskStatus : nil
        taskTitle = taskAction == nil ? nil : taskTitle.flatMap { Detail.capped($0, Detail.title) }
        model = kind == .sessionStart ? model.flatMap { Detail.capped($0, Detail.model) } : nil
    }
}

/// What the side panel's details show of the file a tool works on and of how much an edit changes, worked out
/// inside the helper from the text alone: nothing here looks at the file system.
public enum Detail {
    public static let file = 128
    public static let title = 80
    public static let model = 64
    public static let maxLines = 999_999
    public static let maxTasks = 999

    /// A file as the side panel shows it. Inside the session's folder, its path from there (`src/app.ts`) or, deeper,
    /// `…/` and its last two parts; anywhere else, and for any path with a `.` or `..` part, its name alone. Never
    /// the full path. nil for a path that isn't absolute or leaves nothing to show.
    public static func shortPath(_ path: String, in folder: String) -> String? {
        guard path.hasPrefix("/"), let name = path.split(separator: "/").last else { return nil }
        let parts = path.split(separator: "/")
        let base = folder.split(separator: "/")
        let dotted = { (parts: [Substring]) in parts.contains { $0 == "." || $0 == ".." } }
        var shown = String(name)
        // Part by part, never by the text's start (/a/proj2 is not inside /a/proj); and a folder of fewer than two
        // parts (/, /Users) would put an account's name in the last two parts.
        if base.count >= 2, parts.count > base.count, !dotted(parts), !dotted(base), parts.starts(with: base) {
            let inside = parts.dropFirst(base.count)
            shown = inside.count <= 2 ? inside.joined(separator: "/") : "…/" + inside.suffix(2).joined(separator: "/")
        }
        return capped(shown, file)
    }

    /// Hidden characters dropped and at most `max` characters, with "…" at the end of one cut short; nil if empty.
    public static func capped(_ text: String, _ max: Int) -> String? {
        guard let clean = Sanitize.clean(text, max: max + 1) else { return nil }
        guard clean.unicodeScalars.count > max else { return clean }
        return String(String.UnicodeScalarView(clean.unicodeScalars.prefix(max - 1))) + "…"
    }

    /// The lines an edit adds and removes: `new` against `old`, leaving out the whole lines both begin and end with.
    /// One pass over the bytes from each end, no diff and no list of lines, so a huge edit stays fast. Capped.
    public static func lineChange(old: String, new: String) -> (added: Int, removed: Int) {
        var old = old
        var new = new
        // Native UTF-8, read in place.
        return old.withUTF8 { a in new.withUTF8 { b in lineChange(a, b) } }
    }

    private static func lineChange(_ a: UnsafeBufferPointer<UInt8>, _ b: UnsafeBufferPointer<UInt8>) -> (Int, Int) {
        // Whole lines in common at the start: up to the last newline of the common prefix.
        var i = 0
        var head = 0
        while i < a.count, i < b.count, a[i] == b[i] {
            if a[i] == 0x0A { head = i + 1 }
            i += 1
        }
        if i == a.count, i == b.count { return (0, 0) }
        // Whole lines in common at the end: a common suffix that starts a line in both, past the head.
        var j = 0
        var tail = 0
        while j < a.count - head, j < b.count - head, a[a.count - 1 - j] == b[b.count - 1 - j] {
            j += 1
            let (x, y) = (a.count - j, b.count - j)
            if x == head || a[x - 1] == 0x0A, y == head || b[y - 1] == 0x0A { tail = j }
        }
        return (lines(b, head..<(b.count - tail)), lines(a, head..<(a.count - tail)))
    }

    /// Lines in some text: its newlines, and one more for a last line without one. Capped.
    public static func lines(_ text: String) -> Int {
        var text = text
        return text.withUTF8 { lines($0, 0..<$0.count) }
    }

    private static func lines(_ bytes: UnsafeBufferPointer<UInt8>, _ range: Range<Int>) -> Int {
        guard let base = bytes.baseAddress, !range.isEmpty else { return 0 }
        var count = 0
        var at = base + range.lowerBound
        let end = base + range.upperBound
        while at < end, let found = memchr(at, 0x0A, end - at) {
            count += 1
            at = UnsafePointer(found.assumingMemoryBound(to: UInt8.self)) + 1
        }
        return min(count + (bytes[range.upperBound - 1] == 0x0A ? 0 : 1), maxLines)
    }
}

public enum Limits {
    public static let id = 128
    public static let cwd = 1024
    public static let agentType = 64
    public static let line = 4096
    public static let hookInput = 8 << 20
}

public enum Sanitize {
    /// Control, format (zero-width, bidi overrides) and line/paragraph separators.
    public static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator: return true
        default: return false
        }
    }

    /// Removes hidden characters and keeps at most `max` scalars. Empty results become nil.
    public static func clean(_ value: String, max: Int) -> String? {
        var scalars = String.UnicodeScalarView()
        var count = 0
        for scalar in value.unicodeScalars where !isHidden(scalar) {
            guard count < max else { break }
            scalars.append(scalar)
            count += 1
        }
        let result = String(scalars).trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? nil : result
    }
}
