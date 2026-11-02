import Foundation

/// One status event, cut down to the fields the office needs.
/// Claude Code's hook input also carries tool names and input, prompts, file paths and transcripts. `fromHookInput`
/// derives only a coarse tool kind (and a SendMessage recipient) from them; nothing else crosses the socket.
public struct HookEvent: Codable, Equatable {
    /// What a PreToolUse is about to do, from a fixed list of Claude Code's built-in tools. One short value on the
    /// socket; the tool's name never is.
    public enum ToolKind: String, Codable, CaseIterable {
        case read, edit, command, web, team, other

        /// Compared letter for letter with the built-in tools' names (code.claude.com/docs/en/tools-reference).
        /// MCP tools (`mcp__server__tool`), names not on the list and anything that is not text are `.other`; no
        /// prefix or substring test, so a server's own naming never lands in a built-in kind.
        public static func of(_ toolName: Any?) -> ToolKind {
            switch toolName as? String {
            case "Read", "Glob", "Grep", "LS", "LSP", "NotebookRead": return .read
            case "Edit", "Write", "MultiEdit", "NotebookEdit": return .edit
            case "Bash", "PowerShell", "Monitor": return .command
            case "WebSearch", "WebFetch": return .web
            case "Agent", "Task", "SendMessage": return .team
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
    }

    // MARK: helper side

    /// Reads Claude Code's hook JSON and keeps only the allowlisted fields.
    public static func fromHookInput(_ data: Data, pid: Int32?) -> HookEvent? {
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
        let event = HookEvent(
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
        return event.cleaned()
    }

    public func wireLine() -> Data {
        var data = (try? JSONEncoder().encode(self)) ?? Data()
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
        if event.sendsMessage, let to = recipient, let clean = Sanitize.clean(to, max: Limits.id + 1),
            clean.unicodeScalars.count <= Limits.id
        {
            event.recipient = clean
        }
        if let pid, pid <= 1 { event.pid = nil }
        return event
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
