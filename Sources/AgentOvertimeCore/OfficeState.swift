import Foundation

public enum WorkState: String, Codable, CaseIterable {
    case working, waiting, resting
}

public struct Teammate: Equatable, Identifiable {
    public let id: String
    /// The subagent's name (agent_type). nil is the default helper agent.
    public var name: String?
    public var state: WorkState
    public var since: Date
    /// When it started while the app was listening; nil for one already at work, who sits down without walking in.
    public var arrived: Date? = nil

    mutating func set(_ newState: WorkState, now: Date) {
        if state != newState { since = now }
        state = newState
    }
}

public struct Session: Equatable, Identifiable {
    public let id: String
    public var pid: Int32?
    public var state: WorkState
    public var since: Date
    public var teammates: [Teammate] = []
    /// When it started while the app was listening (SessionStart); nil for one opened before the app.
    public var arrived: Date? = nil

    /// `since` only moves when the state changes, so "waiting · 3 min" counts from the first prompt.
    mutating func set(_ newState: WorkState, now: Date) {
        if state != newState { since = now }
        state = newState
    }

    /// The one rule for counting: the session waits if it or any of its teammates waits, because a subagent's
    /// prompt is answered in the session's terminal too. `since` is the earliest wait.
    public var shown: (state: WorkState, since: Date) {
        let waits = teammates.filter { $0.state == .waiting }.map(\.since) + (state == .waiting ? [since] : [])
        if let first = waits.min() { return (.waiting, first) }
        return (state, since)
    }
}

/// A desk island is one folder. Sessions started in that folder sit at it; an island with no session is "off duty".
public struct Desk: Equatable, Identifiable {
    public let folder: String
    public var sessions: [Session] = []
    public var id: String { folder }
    public var name: String {
        let last = (folder as NSString).lastPathComponent
        return last.isEmpty ? folder : last
    }
    public var isOff: Bool { sessions.isEmpty }
    public var teammates: [Teammate] { sessions.flatMap(\.teammates) }
}

public struct OfficeState: Equatable {
    public static let maxDesks = 24
    /// Guards against a runaway process flooding the socket, far above real use, so every real session and
    /// teammate is counted in the summary and the menu bar. Teammates without a desk show as "+n".
    public static let maxSessions = 64
    public static let maxTeammates = 64

    public private(set) var desks: [Desk]

    /// `folders` are the desks remembered from earlier runs; they start off duty.
    public init(folders: [String] = []) {
        desks = folders.prefix(Self.maxDesks).map { Desk(folder: $0) }
    }

    public var folders: [String] { desks.map(\.folder) }

    /// The state a session or teammate in `current` takes for an event, or nil when the event does not set one.
    static func state(for event: HookEvent, from current: WorkState) -> WorkState? {
        switch event.kind {
        case .sessionStart, .stop: return .resting
        case .userPromptSubmit: return .working
        case .preToolUse: return event.asksUser ? .waiting : .working
        case .permissionRequest: return .waiting
        case .notification:
            guard event.notification == "idle_prompt" else { return .waiting }
            // idle_prompt also comes while a question or permission prompt is still open: that stays a wait.
            return current == .waiting ? nil : .resting
        case .sessionEnd, .subagentStart, .subagentStop: return nil
        }
    }

    /// Applies one event. Returns true when the list of desks changed, so the caller can save it.
    @discardableResult
    public mutating func apply(_ event: HookEvent, now: Date) -> Bool {
        if event.kind == .sessionEnd {
            removeSessions { $0.id == event.session }
            return false
        }
        var desksChanged = false
        guard let (d, s) = locate(event.session) ?? seat(event, now: now, desksChanged: &desksChanged) else {
            return false
        }
        if let pid = event.pid { desks[d].sessions[s].pid = pid }
        guard let agentID = event.agentID else {
            if let newState = Self.state(for: event, from: desks[d].sessions[s].state) {
                desks[d].sessions[s].set(newState, now: now)
            }
            return desksChanged
        }

        var mates = desks[d].sessions[s].teammates
        let index = mates.firstIndex { $0.id == agentID }
        switch (event.kind, index) {
        case (.subagentStop, let i?):
            mates.remove(at: i)
        case (.subagentStop, nil):
            break
        case (_, let i?):
            if let newState = Self.state(for: event, from: mates[i].state) { mates[i].set(newState, now: now) }
        case (_, nil):
            if mates.count < Self.maxTeammates {
                mates.append(
                    Teammate(
                        id: agentID, name: event.agentType,
                        state: Self.state(for: event, from: .working) ?? .working, since: now,
                        arrived: event.kind == .subagentStart ? now : nil))
            }
        }
        desks[d].sessions[s].teammates = mates
        return desksChanged
    }

    /// Ends sessions whose Claude Code process is gone (a killed terminal sends no SessionEnd).
    public mutating func endSessions(where isGone: (Int32) -> Bool) {
        removeSessions { session in session.pid.map(isGone) ?? false }
    }

    /// Forgets desks that are off duty. Desks with someone at them stay.
    public mutating func forgetEmptyDesks() {
        desks.removeAll(where: \.isOff)
    }

    public func count(_ state: WorkState) -> Int {
        desks.reduce(0) { $0 + $1.sessions.filter { $0.shown.state == state }.count }
    }

    public var liveSessionCount: Int { desks.reduce(0) { $0 + $1.sessions.count } }

    /// True when someone works in `folder` or below it (a start script may open sessions in subfolders).
    public func hasLiveSession(in folder: String) -> Bool {
        desks.contains { !$0.isOff && Self.isInside($0.folder, folder) }
    }

    public static func isInside(_ path: String, _ folder: String) -> Bool {
        let base = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        return path == base || path.hasPrefix(base + "/")
    }

    // MARK: private

    private func locate(_ session: String) -> (Int, Int)? {
        for (d, desk) in desks.enumerated() {
            if let s = desk.sessions.firstIndex(where: { $0.id == session }) { return (d, s) }
        }
        return nil
    }

    /// Seats a session the office has not seen yet (a new one, or one started before the app).
    private mutating func seat(_ event: HookEvent, now: Date, desksChanged: inout Bool) -> (Int, Int)? {
        if event.kind == .subagentStop || liveSessionCount >= Self.maxSessions { return nil }
        var d = desks.firstIndex { $0.folder == event.cwd }
        if d == nil {
            // A new folder takes over the off-duty desk nearest the door, so it is in view without scrolling.
            // Other remembered desks keep their places. Only with no off-duty desk does it go at the end.
            if let off = desks.firstIndex(where: \.isOff) {
                desks[off] = Desk(folder: event.cwd)
                d = off
            } else if desks.count < Self.maxDesks {
                desks.append(Desk(folder: event.cwd))
                d = desks.count - 1
            }
            desksChanged = d != nil
        }
        guard let d else { return nil }
        desks[d].sessions.append(
            Session(
                id: event.session, pid: event.pid, state: .resting, since: now,
                arrived: event.kind == .sessionStart ? now : nil))
        return (d, desks[d].sessions.count - 1)
    }

    private mutating func removeSessions(where shouldRemove: (Session) -> Bool) {
        for d in desks.indices { desks[d].sessions.removeAll(where: shouldRemove) }
    }
}
