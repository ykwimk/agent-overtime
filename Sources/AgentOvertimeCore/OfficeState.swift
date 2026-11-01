import Foundation

public enum WorkState: String, Codable, CaseIterable {
    case working, waiting, resting
}

public struct Teammate: Equatable, Identifiable {
    public let id: String
    /// The subagent's name (agent_type). nil is the default helper agent.
    public var name: String?
    /// 1 for the first teammate of a name, then the smallest number free when another of that name arrives
    /// ("Explore 2"). It never changes while the teammate works.
    public internal(set) var number = 1
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
    /// The folder's name, with " 2" and up when another running session already has that name. Numbers go by
    /// arrival, the smallest free one first, and never change while the session runs.
    public internal(set) var name = ""
    public internal(set) var number = 1
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

    /// The session itself does not wait, but a teammate does (the summary and menu count it as waiting).
    public var teammateWaiting: Bool { state != .waiting && shown.state == .waiting }
}

/// A folder sessions ran in. Running sessions are kept here; the folders themselves are remembered (up to
/// `OfficeState.maxDesks`) for Start Work's recent folders. Where people sit is `OfficeState.islands`.
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

/// Who sits at a seat of an island.
public enum Occupant: Equatable {
    case session(String)
    case teammate(String)
    /// A session that went home from this seat. Its name stays, faded, while others still work at the island.
    case off(folder: String, name: String)

    var isAtWork: Bool {
        if case .off = self { return false }
        return true
    }
}

/// Four desks facing each other: two seats with their backs to the room (0, 2) and two across (1, 3). An island
/// is there only while someone at it works, and keeps its place in the room until then.
public struct Island: Equatable, Identifiable {
    public static let size = 4
    /// Its place in the room, 0 nearest the door.
    public let slot: Int
    public internal(set) var seats: [Occupant?] = Array(repeating: nil, count: Island.size)
    public var id: Int { slot }

    /// The seat a newcomer from `folder` takes: one its own folder went home from, then an empty one, then one
    /// anyone went home from; lower seats first. nil when everyone here is at work.
    func seat(for folder: String) -> Int? {
        let ranked = seats.indices.compactMap { i -> (rank: Int, seat: Int)? in
            switch seats[i] {
            case .off(let from, _)?: return (from == folder ? 0 : 2, i)
            case nil: return (1, i)
            case .session?, .teammate?: return nil
            }
        }
        return ranked.min { ($0.rank, $0.seat) < ($1.rank, $1.seat) }?.seat
    }
}

/// One seat as the office draws it.
public enum Seat: Equatable {
    /// A session at work; `unseated` of its teammates found no seat (only past `OfficeState.maxIslands`).
    case session(Session, unseated: Int)
    case teammate(Teammate, of: Session)
    case off(name: String, folder: String)
}

public struct OfficeState: Equatable {
    public static let maxDesks = 24
    /// Guards against a runaway process flooding the socket, far above real use, so every real session and
    /// teammate is counted in the summary and the menu bar.
    public static let maxSessions = 64
    public static let maxTeammates = 64
    /// 128 seats. Anyone past them is still counted, and a session's tag shows its unseated teammates as "+n".
    public static let maxIslands = 32

    public private(set) var desks: [Desk]
    /// Islands in use, nearest the door first. Kept in memory only: after a restart nobody's seat is remembered.
    public private(set) var islands: [Island] = []

    /// `folders` are remembered from earlier runs, for Start Work. Nobody sits anywhere yet.
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
            vacate(.teammate(agentID))
            closeEmptyIslands()
        case (.subagentStop, nil):
            break
        case (_, let i?):
            if let newState = Self.state(for: event, from: mates[i].state) { mates[i].set(newState, now: now) }
        case (_, nil):
            if mates.count < Self.maxTeammates {
                let taken = desks.flatMap(\.teammates).filter { $0.name == event.agentType }.map(\.number)
                mates.append(
                    Teammate(
                        id: agentID, name: event.agentType, number: Self.firstFree(taken),
                        state: Self.state(for: event, from: .working) ?? .working, since: now,
                        arrived: event.kind == .subagentStart ? now : nil))
                sit(.teammate(agentID), folder: desks[d].folder, near: event.session)
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
        let name = desks[d].name
        let number = Self.firstFree(desks.filter { $0.name == name }.flatMap(\.sessions).map(\.number))
        desks[d].sessions.append(
            Session(
                id: event.session, name: number == 1 ? name : "\(name) \(number)", number: number, pid: event.pid,
                state: .resting, since: now, arrived: event.kind == .sessionStart ? now : nil))
        sit(.session(event.session), folder: event.cwd)
        return (d, desks[d].sessions.count - 1)
    }

    // MARK: islands

    /// Every island with the people at its seats, nearest the door first.
    public var pods: [Pod] {
        var sessions: [String: Session] = [:]
        var mates: [String: (Teammate, Session)] = [:]
        for session in desks.flatMap(\.sessions) {
            sessions[session.id] = session
            for mate in session.teammates { mates[mate.id] = (mate, session) }
        }
        var seated: Set<String> = []
        for case .teammate(let id)? in islands.flatMap(\.seats) { seated.insert(id) }
        return islands.map { island in
            let seats = island.seats.map { occupant -> Seat? in
                switch occupant {
                case .session(let id)?:
                    return sessions[id].map {
                        .session($0, unseated: $0.teammates.filter { !seated.contains($0.id) }.count)
                    }
                case .teammate(let id)?:
                    return mates[id].map { .teammate($0.0, of: $0.1) }
                case .off(let folder, let name)?:
                    return .off(name: name, folder: folder)
                case nil:
                    return nil
                }
            }
            return Pod(slot: island.slot, seats: seats)
        }
    }

    /// Seats someone who just arrived. A session takes the island nearest the door that has room. A teammate
    /// sits at its session's island, else at the island with room nearest to it, else at a new island. A new
    /// island takes the free place nearest the door; no island ever moves.
    private mutating func sit(_ who: Occupant, folder: String, near session: String? = nil) {
        let home = session.flatMap { id in islands.first { $0.seats.contains(.session(id)) }?.slot } ?? 0
        let open = islands.indices.filter { islands[$0].seat(for: folder) != nil }.map { i in
            (i: i, distance: abs(islands[i].slot - home), slot: islands[i].slot)
        }
        if let i = open.min(by: { ($0.distance, $0.slot) < ($1.distance, $1.slot) })?.i,
            let seat = islands[i].seat(for: folder)
        {
            islands[i].seats[seat] = who
        } else if islands.count < Self.maxIslands {
            let used = Set(islands.map(\.slot))
            var island = Island(slot: (0...).first { !used.contains($0) }!)
            island.seats[0] = who
            islands.append(island)
            islands.sort { $0.slot < $1.slot }
        }
    }

    /// Empties `who`'s seat, or leaves `mark` there.
    private mutating func vacate(_ who: Occupant, leaving mark: Occupant? = nil) {
        for i in islands.indices {
            if let seat = islands[i].seats.firstIndex(of: who) { islands[i].seats[seat] = mark }
        }
    }

    /// An island where nobody works any more goes, with the names of those who went home from it.
    private mutating func closeEmptyIslands() {
        islands.removeAll { island in !island.seats.contains { $0?.isAtWork ?? false } }
    }

    /// The smallest number from 1 that is not taken, so a newcomer never renumbers anyone already there.
    static func firstFree(_ taken: [Int]) -> Int {
        var number = 1
        while taken.contains(number) { number += 1 }
        return number
    }

    /// A session that ends leaves its name on its seat; its teammates leave with it.
    private mutating func removeSessions(where shouldRemove: (Session) -> Bool) {
        for d in desks.indices {
            let leaving = desks[d].sessions.filter(shouldRemove)
            for session in leaving {
                vacate(.session(session.id), leaving: .off(folder: desks[d].folder, name: session.name))
                for mate in session.teammates { vacate(.teammate(mate.id)) }
            }
            desks[d].sessions.removeAll { session in leaving.contains { $0.id == session.id } }
        }
        closeEmptyIslands()
    }
}
