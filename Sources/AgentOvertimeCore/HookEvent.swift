import Foundation

/// One status event, cut down to the fields the office needs.
/// Claude Code's hook input also carries tool input, prompts, file paths and transcripts;
/// none of that is read past `fromHookInput`, and none of it crosses the socket.
public struct HookEvent: Codable, Equatable {
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
        case pid = "p"
    }

    public init(
        kind: Kind, session: String, cwd: String, agentID: String? = nil, agentType: String? = nil,
        notification: String? = nil, asksUser: Bool = false, pid: Int32? = nil
    ) {
        self.kind = kind
        self.session = session
        self.cwd = cwd
        self.agentID = agentID
        self.agentType = agentType
        self.notification = notification
        self.asksUser = asksUser
        self.pid = pid
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        session = try c.decode(String.self, forKey: .session)
        cwd = try c.decode(String.self, forKey: .cwd)
        agentID = try c.decodeIfPresent(String.self, forKey: .agentID)
        agentType = try c.decodeIfPresent(String.self, forKey: .agentType)
        notification = try c.decodeIfPresent(String.self, forKey: .notification)
        asksUser = try c.decodeIfPresent(Bool.self, forKey: .asksUser) ?? false
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
        let event = HookEvent(
            kind: kind, session: session, cwd: cwd,
            agentID: object["agent_id"] as? String,
            agentType: object["agent_type"] as? String,
            notification: object["notification_type"] as? String,
            asksUser: kind == .preToolUse && object["tool_name"] as? String == "AskUserQuestion",
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
