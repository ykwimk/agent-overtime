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
    /// The nickname given to its name on this Mac, if any, and its number among those shown under the same
    /// name: shown in place of `name` and `number`, which stay for its look.
    public internal(set) var nickname: String? = nil
    public internal(set) var labelNumber = 1
    /// The teammate that called it, when another teammate did (nil: the session itself). When the caller leaves,
    /// whoever called the caller takes its place.
    public internal(set) var calledBy: String? = nil

    mutating func set(_ newState: WorkState, now: Date) {
        if state != newState { since = now }
        state = newState
    }

    /// The name it shows, without its number: its nickname, else its own name (nil: the default helper).
    var shownName: String? { nickname ?? name }
}

public struct Session: Equatable, Identifiable {
    public let id: String
    /// The folder's name, with " 2" and up when another running session already has that name. Numbers go by
    /// arrival, the smallest free one first, and never change while the session runs. Its look goes by it.
    public internal(set) var name = ""
    public internal(set) var number = 1
    /// What it shows: its folder's nickname or name, then " 2" and up while another running session shows the
    /// same, numbered the same way.
    public var label: String { labelNumber == 1 ? labelBase : "\(labelBase) \(labelNumber)" }
    var labelBase = ""
    var labelNumber = 1
    public var pid: Int32?
    public var state: WorkState
    public var since: Date
    public var teammates: [Teammate] = []
    /// When it started while the app was listening (SessionStart); nil for one opened before the app.
    public var arrived: Date? = nil
    /// Since the last teammate came, while two or more are out and the session has done nothing of its own
    /// (it hands work out and waits). `OfficeState.advance` makes it a meeting after `OfficeState.meetingDelay`.
    public internal(set) var quietSince: Date? = nil
    /// In a meeting. Its own prompt, tool or stop ends it, and so does its last teammate leaving; waiting for the
    /// user's answer does not.
    public internal(set) var meets = false

    /// `since` only moves when the state changes, so "waiting · 3 min" counts from the first prompt.
    mutating func set(_ newState: WorkState, now: Date) {
        if state != newState { since = now }
        state = newState
    }

    mutating func endMeeting() {
        quietSince = nil
        meets = false
    }

    /// The teammates the session called itself: the ones that meet with it.
    public var direct: [Teammate] { teammates.filter { $0.calledBy == nil } }

    /// After a teammate came or went. Coming counts again from the newcomer until the meeting starts; once it has,
    /// it goes on with one teammate and ends with none. Only the session's own teammates count.
    mutating func recount(_ kind: HookEvent.Kind, now: Date) {
        let started = meets || quietSince.map { now >= $0 + OfficeState.meetingDelay } ?? false
        let count = direct.count
        switch kind {
        case .subagentStart where count >= 2 && !started: quietSince = now
        case .subagentStop where count == 0 || (count < 2 && !started): endMeeting()
        default: break
        }
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

/// Names given on this Mac: a session's by its folder path, a teammate's by its name (agent_type; "" for the
/// default helper). The office shows them in place of the folder's or the teammate's own name.
public struct Nicknames: Equatable, Codable {
    public static let maxLength = 32
    /// Of each kind. As many as the office counts sessions or teammates at once, far more than anyone names by
    /// hand; a config.json edited outside the app can't make it carry thousands.
    public static let maxCount = 64
    public internal(set) var folders: [String: String] = [:]
    public internal(set) var agents: [String: String] = [:]

    public init() {}

    /// A nickname as typed: hidden characters dropped, spaces at the ends trimmed. nil when nothing is left or it
    /// is longer than `maxLength` characters (an emoji counts as one).
    public static func cleaned(_ text: String) -> String? {
        guard let clean = Sanitize.clean(text, max: Limits.line) else { return nil }
        return clean.count <= maxLength ? clean : nil
    }

    private enum CodingKeys: String, CodingKey { case folders, agents }

    /// One entry as text, or nothing when it is anything else.
    private struct Entry: Decodable {
        let text: String?
        init(from decoder: Decoder) throws { text = try? decoder.singleValueContainer().decode(String.self) }
    }

    /// Read back from config.json, which can be edited outside the app: each entry is checked again as if it were
    /// typed, and one that would not have passed is dropped on its own (too long, hidden characters, not text, a
    /// key that is not a folder path or a name), as is anything past `maxCount`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let folders = (try? container.decodeIfPresent([String: Entry].self, forKey: .folders)) ?? nil
        let agents = (try? container.decodeIfPresent([String: Entry].self, forKey: .agents)) ?? nil
        for (folder, entry) in (folders ?? [:]).sorted(by: { $0.key < $1.key }) where self.folders.count < Self.maxCount
        {
            guard let name = entry.text, Self.cleaned(name) == name, folder.hasPrefix("/"),
                Sanitize.clean(folder, max: Limits.cwd) == folder
            else { continue }
            self.folders[folder] = name
        }
        for (agent, entry) in (agents ?? [:]).sorted(by: { $0.key < $1.key }) where self.agents.count < Self.maxCount {
            guard let name = entry.text, Self.cleaned(name) == name,
                agent.isEmpty || Sanitize.clean(agent, max: Limits.agentType) == agent
            else { continue }
            self.agents[agent] = name
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(folders, forKey: .folders)
        try container.encode(agents, forKey: .agents)
    }
}

public struct OfficeState: Equatable {
    public static let maxDesks = 24
    /// Guards against a runaway process flooding the socket, far above real use, so every real session and
    /// teammate is counted in the summary and the menu bar.
    public static let maxSessions = 64
    public static let maxTeammates = 64
    /// 128 seats. Anyone past them is still counted, and a session's tag shows its unseated teammates as "+n".
    public static let maxIslands = 32
    /// How long a session stays quiet with two or more teammates out before they meet, so a short pause between
    /// two tools doesn't send everyone to the meeting room and back.
    public static let meetingDelay: TimeInterval = 10
    /// The meeting room's table: the session and five teammates.
    public static let meetingSeats = 6

    /// Who sits in the one meeting room.
    public struct Meeting: Equatable {
        public let session: Session
        /// Its teammates at the table, first come first.
        public let members: [Teammate]
        /// Teammates who stay at their desks: the table is full.
        public let more: Int
    }

    public private(set) var desks: [Desk]
    /// Islands in use, nearest the door first. Kept in memory only: after a restart nobody's seat is remembered.
    public private(set) var islands: [Island] = []
    /// When each session ("s:" and its id) and teammate ("a:" and its id) last sent news while the app listened,
    /// by the app's clock, and the kind of tool each is running. Memory only, and gone with them.
    private var news: [String: Date] = [:]
    private var kinds: [String: HookEvent.ToolKind] = [:]
    /// For each session, who called a teammate and is still waiting for it to come, first first: a teammate's id,
    /// or nil for the session itself. A SubagentStart says nothing of who called, so the next one to come goes with
    /// the first call still open; with none open, the session called it.
    private var calls: [String: [String?]] = [:]
    /// Open calls kept per session: a call that never brought anyone (refused, say) can't pile up.
    static let maxCalls = 16

    public private(set) var nicknames: Nicknames

    /// `folders` are remembered from earlier runs, for Start Work, and so are `nicknames`. Nobody sits anywhere
    /// yet.
    public init(folders: [String] = [], nicknames: Nicknames = Nicknames()) {
        desks = folders.prefix(Self.maxDesks).map { Desk(folder: $0) }
        self.nicknames = nicknames
    }

    /// Equal when everything drawn is: the time of the last news alone changes nothing on screen but the side
    /// panel, which keeps its own clock, so one more tool doesn't draw the whole room again.
    public static func == (a: OfficeState, b: OfficeState) -> Bool {
        a.desks == b.desks && a.islands == b.islands && a.nicknames == b.nicknames
    }

    /// The folder a session runs in.
    public func folder(ofSession id: String) -> String? {
        desks.first { $0.sessions.contains { $0.id == id } }?.folder
    }

    /// Gives a folder's sessions a nickname, or takes it away (nil, or nothing visible typed). False when it is
    /// longer than `Nicknames.maxLength`, or a new one past `Nicknames.maxCount`.
    @discardableResult
    public mutating func rename(folder: String, to text: String?) -> Bool {
        let name = text.flatMap { Sanitize.clean($0, max: Limits.line) }
        if let name, Nicknames.cleaned(name) == nil { return false }
        if name != nil, nicknames.folders[folder] == nil, nicknames.folders.count >= Nicknames.maxCount { return false }
        nicknames.folders[folder] = name
        relabelSessions { $0 == folder }
        return true
    }

    /// The same for teammates of a name (nil: the default helper).
    @discardableResult
    public mutating func rename(agent: String?, to text: String?) -> Bool {
        let name = text.flatMap { Sanitize.clean($0, max: Limits.line) }
        if let name, Nicknames.cleaned(name) == nil { return false }
        if name != nil, nicknames.agents[agent ?? ""] == nil, nicknames.agents.count >= Nicknames.maxCount {
            return false
        }
        nicknames.agents[agent ?? ""] = name
        relabelTeammates { $0.name == agent }
        return true
    }

    /// Takes every nickname away.
    public mutating func forgetNicknames() {
        nicknames = Nicknames()
        relabelSessions { _ in true }
        relabelTeammates { _ in true }
    }

    public var folders: [String] { desks.map(\.folder) }

    /// When the app last heard from a session or a teammate; nil before any news since the app started.
    public func lastNews(session id: String) -> Date? { news["s:" + id] }
    public func lastNews(teammate id: String) -> Date? { news["a:" + id] }

    /// The kind of tool a session or teammate last started, until its turn ends or it is asked something new.
    public func toolKind(session id: String) -> HookEvent.ToolKind? { kinds["s:" + id] }
    public func toolKind(teammate id: String) -> HookEvent.ToolKind? { kinds["a:" + id] }

    /// Keeps the latest kind of tool under `key`, and forgets it when a new prompt or the end of a turn comes. A
    /// call for a teammate (a teammate tool other than SendMessage) waits for the next newcomer.
    private mutating func note(_ event: HookEvent, at key: String) {
        if let kind = event.toolKind {
            kinds[key] = kind
        } else if [.userPromptSubmit, .stop, .sessionStart, .subagentStop].contains(event.kind) {
            kinds[key] = nil
        }
        if event.toolKind == .team, !event.sendsMessage {
            calls[event.session, default: []].append(event.agentID)
            if calls[event.session]!.count > Self.maxCalls { calls[event.session]!.removeFirst() }
        }
    }

    public func session(_ id: String) -> Session? {
        desks.lazy.flatMap(\.sessions).first { $0.id == id }
    }

    /// A teammate and the session it works for.
    public func teammate(_ id: String) -> (teammate: Teammate, of: Session)? {
        for session in desks.flatMap(\.sessions) {
            if let mate = session.teammates.first(where: { $0.id == id }) { return (mate, session) }
        }
        return nil
    }

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
            news["s:" + event.session] = now
            note(event, at: "s:" + event.session)
            if let newState = Self.state(for: event, from: desks[d].sessions[s].state) {
                desks[d].sessions[s].set(newState, now: now)
            }
            if Self.isOwnWork(event) { desks[d].sessions[s].endMeeting() }
            return desksChanged
        }

        var mates = desks[d].sessions[s].teammates
        let index = mates.firstIndex { $0.id == agentID }
        news["a:" + agentID] = now
        note(event, at: "a:" + agentID)
        switch (event.kind, index) {
        case (.subagentStop, let i?):
            let leaving = mates.remove(at: i)
            for k in mates.indices where mates[k].calledBy == agentID { mates[k].calledBy = leaving.calledBy }
            news["a:" + agentID] = nil
            vacate(.teammate(agentID))
            closeEmptyIslands()
        case (.subagentStop, nil):
            news["a:" + agentID] = nil
        case (_, let i?):
            if let newState = Self.state(for: event, from: mates[i].state) { mates[i].set(newState, now: now) }
        case (_, nil):
            if mates.count < Self.maxTeammates {
                let taken = desks.flatMap(\.teammates).filter { $0.name == event.agentType }.map(\.number)
                var mate = Teammate(
                    id: agentID, name: event.agentType, number: Self.firstFree(taken),
                    state: Self.state(for: event, from: .working) ?? .working, since: now,
                    arrived: event.kind == .subagentStart ? now : nil)
                mate.nickname = nicknames.agents[event.agentType ?? ""]
                mate.labelNumber = Self.number(
                    keeping: mate.nickname == nil ? mate.number : nil,
                    taken: teammateNumbers(showing: mate.shownName))
                if event.kind == .subagentStart, let caller = calls[event.session]?.first {
                    calls[event.session]!.removeFirst()
                    mate.calledBy = caller.flatMap { id in mates.contains { $0.id == id } ? id : nil }
                }
                mates.append(mate)
                sit(.teammate(agentID), folder: desks[d].folder, near: event.session, caller: mate.calledBy)
            }
        }
        desks[d].sessions[s].teammates = mates
        desks[d].sessions[s].recount(event.kind, now: now)
        return desksChanged
    }

    /// The session's own work: a prompt, a tool that doesn't ask the user, a stop. Calling or messaging teammates is
    /// not: handing out more work keeps the meeting going.
    static func isOwnWork(_ event: HookEvent) -> Bool {
        guard event.agentID == nil else { return false }
        switch event.kind {
        case .userPromptSubmit, .stop: return true
        case .preToolUse: return !event.asksUser && event.toolKind != .team
        default: return false
        }
    }

    /// Starts the meetings whose quiet time is up at `now`. The app calls it at `nextMeeting`.
    public mutating func advance(to now: Date) {
        for d in desks.indices {
            for s in desks[d].sessions.indices {
                guard let quiet = desks[d].sessions[s].quietSince, now >= quiet + Self.meetingDelay else { continue }
                desks[d].sessions[s].meets = true
            }
        }
    }

    /// When the next meeting starts, if nothing else happens first.
    public var nextMeeting: Date? {
        desks.flatMap(\.sessions).filter { !$0.meets }.compactMap { $0.quietSince }.min().map {
            $0 + Self.meetingDelay
        }
    }

    /// The one meeting room is the session's that met first. Other sessions in a meeting stay at their desks.
    public var meeting: Meeting? {
        let first = desks.flatMap(\.sessions).filter(\.meets).min {
            ($0.quietSince ?? .distantPast, $0.id) < ($1.quietSince ?? .distantPast, $1.id)
        }
        return first.map { session in
            let direct = session.direct
            return Meeting(
                session: session, members: Array(direct.prefix(Self.meetingSeats - 1)),
                more: max(0, direct.count - (Self.meetingSeats - 1)))
        }
    }

    /// Ends sessions whose Claude Code process is gone (a killed terminal sends no SessionEnd).
    public mutating func endSessions(where isGone: (Int32) -> Bool) {
        removeSessions { session in session.pid.map(isGone) ?? false }
    }

    /// Forgets the recent folders nobody works in. Folders with a session running stay.
    public mutating func forgetIdleFolders() {
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
        var session = Session(
            id: event.session, name: number == 1 ? name : "\(name) \(number)", number: number, pid: event.pid,
            state: .resting, since: now, arrived: event.kind == .sessionStart ? now : nil)
        session.labelBase = nicknames.folders[event.cwd] ?? name
        session.labelNumber = Self.number(
            keeping: nicknames.folders[event.cwd] == nil ? number : nil,
            taken: sessionNumbers(showing: session.labelBase))
        desks[d].sessions.append(session)
        sit(.session(event.session), folder: event.cwd)
        return (d, desks[d].sessions.count - 1)
    }

    // MARK: nicknames

    /// The numbers taken among those showing a name (0 is a session or teammate being renamed).
    private func sessionNumbers(showing base: String) -> [Int] {
        desks.flatMap(\.sessions).filter { $0.labelBase == base && $0.labelNumber > 0 }.map(\.labelNumber)
    }

    private func teammateNumbers(showing name: String?) -> [Int] {
        desks.flatMap(\.teammates).filter { $0.shownName == name && $0.labelNumber > 0 }.map(\.labelNumber)
    }

    /// Shows the current nicknames on the sessions of the folders picked. Each takes the smallest number free
    /// among the others showing the same name, so nobody else's number changes.
    private mutating func relabelSessions(_ picks: (String) -> Bool) {
        let picked = desks.indices.filter { picks(desks[$0].folder) }
        for d in picked {
            for s in desks[d].sessions.indices { desks[d].sessions[s].labelNumber = 0 }
        }
        for d in picked {
            for s in desks[d].sessions.indices {
                let nickname = nicknames.folders[desks[d].folder]
                let base = nickname ?? desks[d].name
                desks[d].sessions[s].labelBase = base
                desks[d].sessions[s].labelNumber = Self.number(
                    keeping: nickname == nil ? desks[d].sessions[s].number : nil, taken: sessionNumbers(showing: base))
            }
        }
    }

    /// The same for the teammates picked.
    private mutating func relabelTeammates(_ picks: (Teammate) -> Bool) {
        var picked: [(Int, Int, Int)] = []
        for d in desks.indices {
            for s in desks[d].sessions.indices {
                for m in desks[d].sessions[s].teammates.indices where picks(desks[d].sessions[s].teammates[m]) {
                    desks[d].sessions[s].teammates[m].labelNumber = 0
                    picked.append((d, s, m))
                }
            }
        }
        for (d, s, m) in picked {
            let nickname = nicknames.agents[desks[d].sessions[s].teammates[m].name ?? ""]
            desks[d].sessions[s].teammates[m].nickname = nickname
            desks[d].sessions[s].teammates[m].labelNumber = Self.number(
                keeping: nickname == nil ? desks[d].sessions[s].teammates[m].number : nil,
                taken: teammateNumbers(showing: desks[d].sessions[s].teammates[m].shownName))
        }
    }

    /// Without a nickname the shown number is the automatic one, so taking a nickname away gives the automatic
    /// name back; otherwise (or if it is taken) the smallest free.
    private static func number(keeping automatic: Int?, taken: [Int]) -> Int {
        if let automatic, !taken.contains(automatic) { return automatic }
        return firstFree(taken)
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
    /// sits at its caller's island (the teammate that called it, else its session), else at the island with room
    /// nearest to it, else at a new island. A new island takes the free place nearest the door; no island ever
    /// moves.
    private mutating func sit(_ who: Occupant, folder: String, near session: String? = nil, caller: String? = nil) {
        let placed = islands
        let callers = [caller.map(Occupant.teammate), session.map(Occupant.session)].compactMap { $0 }
        let home = callers.compactMap { occupant in placed.first { $0.seats.contains(occupant) }?.slot }.first ?? 0
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
                vacate(.session(session.id), leaving: .off(folder: desks[d].folder, name: session.label))
                news["s:" + session.id] = nil
                kinds["s:" + session.id] = nil
                calls[session.id] = nil
                for mate in session.teammates {
                    vacate(.teammate(mate.id))
                    news["a:" + mate.id] = nil
                    kinds["a:" + mate.id] = nil
                }
            }
            desks[d].sessions.removeAll { session in leaving.contains { $0.id == session.id } }
        }
        closeEmptyIslands()
    }
}
