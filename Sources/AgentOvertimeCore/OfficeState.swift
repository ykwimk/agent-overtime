import Foundation

public enum WorkState: String, Codable, CaseIterable {
    case working, waiting, resting
    /// Running, but not heard from yet: found on this Mac before any news. It may be waiting for an answer, so it is
    /// never shown as resting.
    case quiet
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
    /// When it started while the app was listening, or got a seat after waiting for one; nil for one already at
    /// work, who sits down without walking in.
    public var arrived: Date? = nil
    /// The nickname given to its name on this Mac, if any, and its number among those shown under the same
    /// name: shown in place of `name` and `number`, which stay for its look.
    public internal(set) var nickname: String? = nil
    public internal(set) var labelNumber = 1
    /// The teammate that called it, when another teammate did (nil: the session itself). When the caller leaves,
    /// whoever called the caller takes its place.
    public internal(set) var calledBy: String? = nil
    /// Working on its own: its caller went on with work of its own after it came, so it isn't waited on. It keeps
    /// them on until it leaves, and doesn't meet.
    public internal(set) var headphones = false

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
    /// When its process started, once found running on this Mac. With `pid` it tells that process from a later
    /// one given the same number.
    public internal(set) var started: Date? = nil
    /// False while it is only found running on this Mac, with no news from it yet.
    public internal(set) var heard = true

    /// `since` only moves when the state changes, so "waiting · 3 min" counts from the first prompt.
    mutating func set(_ newState: WorkState, now: Date) {
        if state != newState { since = now }
        state = newState
    }

    mutating func endMeeting() {
        quietSince = nil
        meets = false
    }

    /// The teammates the session called itself and waits on: the ones that meet with it (not those with headphones).
    public var direct: [Teammate] { teammates.filter { $0.calledBy == nil && !$0.headphones } }

    /// Whether a teammate is in its meeting: at the table, or one of the "+n" past its seats. Teammates with
    /// headphones and those another teammate called go on as they are.
    public func meets(with mate: Teammate) -> Bool { meets && direct.contains { $0.id == mate.id } }

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

/// A folder sessions run in, while one does. Start Work's recent folders are `OfficeState.folders`, kept apart;
/// where people sit is `OfficeState.islands`.
public struct Desk: Equatable, Identifiable {
    public let folder: String
    public var sessions: [Session] = []
    public var id: String { folder }
    /// The folder's last name; "~" for the home folder rather than the account's name.
    public var name: String {
        if folder == Paths.home { return "~" }
        let last = (folder as NSString).lastPathComponent
        return last.isEmpty ? folder : last
    }
    public var teammates: [Teammate] { sessions.flatMap(\.teammates) }
}

/// Who sits at a seat of an island.
public enum Occupant: Equatable {
    case session(String)
    case teammate(String)
}

/// Four desks facing each other: two seats with their backs to the room (0, 2) and two across (1, 3). One
/// session's island: the session at seat 0, its teammates (and theirs) at 1, 2 and 3 as they come. It keeps its
/// place in the room while the session runs.
public struct Island: Equatable, Identifiable {
    public static let size = 4
    /// Its place in the room, 0 nearest the door.
    public let slot: Int
    public internal(set) var seats: [Occupant?] = Array(repeating: nil, count: Island.size)
    public var id: Int { slot }
}

/// One seat as the office draws it.
public enum Seat: Equatable {
    /// A session at work; `unseated` of its teammates wait for a free seat at its island, shown as "+n".
    case session(Session, unseated: Int)
    case teammate(Teammate, of: Session)
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
    /// Recent folders kept for Start Work.
    public static let maxDesks = 24
    /// Guards against a runaway process flooding the socket, far above real use, so every real session and
    /// teammate is counted in the summary and the menu bar.
    public static let maxSessions = 64
    public static let maxTeammates = 64
    /// One island a session. Sessions past them are still counted in the summary and the menu bar.
    // shortcut: a session past them never gets an island, even after another leaves; seat it then if 32 sessions at
    // once turn out to be real.
    public static let maxIslands = 32
    /// How long a session stays quiet with two or more teammates out before they meet, so a short pause between
    /// two tools doesn't send everyone to the meeting room and back.
    public static let meetingDelay: TimeInterval = 10
    /// The meeting room's table: the session and five teammates.
    public static let meetingSeats = 6

    /// The last message one person in a session sent another, by who they are (nil: the session itself); the
    /// recipient as written is not kept. `serial` tells one message from the next.
    public struct Talk: Equatable {
        public let session: String
        public let from: String?
        public let to: String?
        public let serial: Int
    }

    /// A Claude Code process found running on this Mac, news or not: its number, when it started, the folder it
    /// runs in, and whether it is busy (its CPU time grew since the last look).
    public struct Found: Equatable {
        public let pid: Int32
        public let started: Date
        public let folder: String
        public let busy: Bool

        public init(pid: Int32, started: Date, folder: String, busy: Bool) {
            self.pid = pid
            self.started = started
            self.folder = folder
            self.busy = busy
        }
    }

    /// Who sits in the one meeting room.
    public struct Meeting: Equatable {
        public let session: Session
        /// Its teammates at the table, first come first: those with a seat at its island.
        public let members: [Teammate]
        /// Teammates in the meeting but not at the table: past its seats, or still waiting for a seat at the island.
        public let more: Int
    }

    /// Folders with a session running, in the order they came.
    public private(set) var desks: [Desk] = []
    /// Start Work's recent folders, oldest first: those remembered from earlier runs, then each new folder a session
    /// sends news from. Who sits where never changes them.
    public private(set) var folders: [String]
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
    /// The session id news comes under, for a session first found on this Mac (its own id is kept, so it stays the
    /// same person in the room). One for each such session at most.
    private var links: [String: String] = [:]

    public private(set) var nicknames: Nicknames
    /// The latest message between two people at their desks, for the walk over to talk.
    public private(set) var talk: Talk?

    /// `folders` are remembered from earlier runs, for Start Work, and so are `nicknames`. Nobody sits anywhere
    /// yet.
    public init(folders: [String] = [], nicknames: Nicknames = Nicknames()) {
        self.folders = Array(folders.prefix(Self.maxDesks))
        self.nicknames = nicknames
    }

    /// Equal when everything drawn is: the time of the last news alone changes nothing on screen but the side
    /// panel, which keeps its own clock, so one more tool doesn't draw the whole room again.
    public static func == (a: OfficeState, b: OfficeState) -> Bool {
        a.desks == b.desks && a.islands == b.islands && a.nicknames == b.nicknames && a.talk == b.talk
            && a.folders == b.folders
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

    /// Applies one event. Returns true when the recent folders changed, so the caller can save them.
    @discardableResult
    public mutating func apply(_ event: HookEvent, now: Date) -> Bool {
        var event = event
        if let id = links[event.session] { event.session = id }
        if event.kind == .sessionEnd {
            removeSessions { $0.id == event.session }
            return false
        }
        let seated = locate(event.session) != nil
        guard let (d, s) = locate(event.session) ?? takeOver(&event, now: now) ?? seat(event, now: now) else {
            return false
        }
        let desksChanged = remember(desks[d].folder)
        if let pid = event.pid { desks[d].sessions[s].pid = pid }
        if seated, event.sendsMessage, let to = event.recipient { overhear(event, to: to, in: desks[d].sessions[s]) }
        guard let agentID = event.agentID else {
            news["s:" + event.session] = now
            note(event, at: "s:" + event.session)
            if let newState = Self.state(for: event, from: desks[d].sessions[s].state) {
                desks[d].sessions[s].set(newState, now: now)
            }
            if Self.isWork(event) {
                desks[d].sessions[s].endMeeting()
                putOnHeadphones(d, s, calledBy: nil)
            }
            return desksChanged
        }
        if Self.isWork(event) { putOnHeadphones(d, s, calledBy: agentID) }

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
            // The one that waited longest for a seat takes it, and walks in from the door now.
            let seated = seatedTeammates
            if let k = mates.firstIndex(where: { !seated.contains($0.id) }),
                sit(.teammate(mates[k].id), at: event.session)
            {
                mates[k].arrived = now
            }
        case (.subagentStop, nil):
            news["a:" + agentID] = nil
        case (_, let i?):
            if let newState = Self.state(for: event, from: mates[i].state) { mates[i].set(newState, now: now) }
        case (_, nil):
            if mates.count < Self.maxTeammates, !event.sendsMessage {
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
                sit(.teammate(agentID), at: event.session)
            }
        }
        // Only seated teammates keep news and a tool kind: a stranger's message, or one past the limit, leaves none.
        if !mates.contains(where: { $0.id == agentID }) {
            news["a:" + agentID] = nil
            kinds["a:" + agentID] = nil
        }
        desks[d].sessions[s].teammates = mates
        desks[d].sessions[s].recount(event.kind, now: now)
        return desksChanged
    }

    /// Work of its own, for the session or a teammate that sends it: a prompt, a tool that doesn't ask the user, a
    /// stop. Calling or messaging teammates is not: handing out more work keeps a meeting going.
    static func isWork(_ event: HookEvent) -> Bool {
        switch event.kind {
        case .userPromptSubmit, .stop: return true
        case .preToolUse: return !event.asksUser && event.toolKind != .team
        default: return false
        }
    }

    /// A message about to go from someone in `session` to `to`: kept as a talk between two people only when `to`
    /// is, in this same session, a teammate's id, a name exactly one teammate has, or "main" (the session). Anything
    /// else (another session, a name two have, nobody) is dropped, and nobody new is seated for it. `to` itself is
    /// not kept.
    private mutating func overhear(_ event: HookEvent, to: String, in session: Session) {
        if let sender = event.agentID, !session.teammates.contains(where: { $0.id == sender }) { return }
        let receiver: String??
        if session.teammates.contains(where: { $0.id == to }) {
            receiver = .some(to)
        } else if case let named = session.teammates.filter({ $0.name == to }), named.count == 1 {
            receiver = .some(named[0].id)
        } else if to == "main" {
            receiver = .some(nil)
        } else {
            receiver = nil
        }
        guard let receiver, receiver != event.agentID else { return }
        talk = Talk(session: session.id, from: event.agentID, to: receiver, serial: (talk?.serial ?? 0) + 1)
    }

    /// The teammates a caller (nil: the session) has out once it goes on with its own work: they work on their own.
    private mutating func putOnHeadphones(_ d: Int, _ s: Int, calledBy caller: String?) {
        for m in desks[d].sessions[s].teammates.indices where desks[d].sessions[s].teammates[m].calledBy == caller {
            desks[d].sessions[s].teammates[m].headphones = true
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
        let seated = seatedTeammates
        return first.map { session in
            let direct = session.direct
            let members = Array(direct.filter { seated.contains($0.id) }.prefix(Self.meetingSeats - 1))
            return Meeting(session: session, members: members, more: direct.count - members.count)
        }
    }

    /// Ends sessions whose Claude Code process is gone (a killed terminal sends no SessionEnd).
    public mutating func endSessions(where isGone: (Int32) -> Bool) {
        removeSessions { session in session.pid.map(isGone) ?? false }
    }

    /// The latest look at the Claude Code processes running on this Mac. One person for one process: a process
    /// nobody sits for yet takes a new island, quiet (or working while busy) until its first news, which goes on in
    /// the same seat. A session found before whose process is gone (or whose number a new process took) goes home
    /// with its teammates. On the first look after the app opened everyone found was there already and sits down
    /// without walking in; later ones walk in. The recent folders are left alone: nothing here is saved.
    public mutating func detect(_ found: [Found], now: Date, opening: Bool) {
        removeSessions { session in
            guard let started = session.started else { return false }
            return !found.contains { $0.pid == session.pid && $0.started == started }
        }
        for process in found {
            if let (d, s) = locate(pid: process.pid) {
                desks[d].sessions[s].started = process.started
                if !desks[d].sessions[s].heard { desks[d].sessions[s].set(process.busy ? .working : .quiet, now: now) }
                continue
            }
            guard let folder = Sanitize.clean(process.folder, max: Limits.cwd), folder.hasPrefix("/"),
                let (d, s) = seat(
                    "found-\(process.pid)-\(process.started.timeIntervalSince1970)", in: folder, pid: process.pid,
                    state: process.busy ? .working : .quiet, arrived: opening ? nil : now, now: now)
            else { continue }
            desks[d].sessions[s].started = process.started
            desks[d].sessions[s].heard = false
        }
    }

    /// The first news of a session the office seats as found on this Mac (the same process number): it goes on in
    /// that seat as the same person, without walking in, and its news comes under that person's id from now on.
    /// A session that already had news in that process is over: one process, one seat.
    private mutating func takeOver(_ event: inout HookEvent, now: Date) -> (Int, Int)? {
        guard event.kind != .subagentStop, !event.sendsMessage, let pid = event.pid,
            let (d, s) = locate(pid: pid)
        else { return nil }
        let id = desks[d].sessions[s].id
        guard !desks[d].sessions[s].heard else {
            removeSessions { $0.id == id }
            return nil
        }
        links[event.session] = id
        event.session = id
        desks[d].sessions[s].heard = true
        // Busy enough to send news; the news itself may say more.
        desks[d].sessions[s].set(.working, now: now)
        return (d, s)
    }

    /// Recent folders nobody works in now: what Clear Recent Folders takes away.
    public var idleFolders: [String] { folders.filter { folder in !desks.contains { $0.folder == folder } } }

    /// Forgets the recent folders nobody works in. Folders with a session running stay.
    public mutating func forgetIdleFolders() {
        let idle = idleFolders
        folders.removeAll(where: idle.contains)
    }

    /// Keeps a folder a session sent news from among the recent folders, newest last. Past `maxDesks` the oldest
    /// one nobody works in goes; with none such, the new one isn't kept. True when the list changed.
    private mutating func remember(_ folder: String) -> Bool {
        guard !folders.contains(folder) else { return false }
        if folders.count >= Self.maxDesks {
            guard let oldest = idleFolders.first else { return false }
            folders.removeAll { $0 == oldest }
        }
        folders.append(folder)
        return true
    }

    public func count(_ state: WorkState) -> Int {
        desks.reduce(0) { $0 + $1.sessions.filter { $0.shown.state == state }.count }
    }

    public var liveSessionCount: Int { desks.reduce(0) { $0 + $1.sessions.count } }

    /// True when someone works in `folder` or below it (a start script may open sessions in subfolders).
    public func hasLiveSession(in folder: String) -> Bool {
        desks.contains { Self.isInside($0.folder, folder) }
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

    private func locate(pid: Int32) -> (Int, Int)? {
        for (d, desk) in desks.enumerated() {
            if let s = desk.sessions.firstIndex(where: { $0.pid == pid }) { return (d, s) }
        }
        return nil
    }

    /// Seats a session the office has not seen yet (a new one, or one started before the app). The recent folders
    /// are left alone: `remember` keeps them.
    private mutating func seat(_ event: HookEvent, now: Date) -> (Int, Int)? {
        // A message seats nobody: it is only matched against those already here.
        if event.kind == .subagentStop || event.sendsMessage { return nil }
        return seat(
            event.session, in: event.cwd, pid: event.pid, state: .resting,
            arrived: event.kind == .sessionStart ? now : nil, now: now)
    }

    private mutating func seat(
        _ id: String, in folder: String, pid: Int32?, state: WorkState, arrived: Date?, now: Date
    ) -> (Int, Int)? {
        guard liveSessionCount < Self.maxSessions else { return nil }
        if !desks.contains(where: { $0.folder == folder }) { desks.append(Desk(folder: folder)) }
        let d = desks.firstIndex { $0.folder == folder }!
        let name = desks[d].name
        let number = Self.firstFree(desks.filter { $0.name == name }.flatMap(\.sessions).map(\.number))
        var session = Session(
            id: id, name: number == 1 ? name : "\(name) \(number)", number: number, pid: pid, state: state,
            since: now, arrived: arrived)
        session.labelBase = nicknames.folders[folder] ?? name
        session.labelNumber = Self.number(
            keeping: nicknames.folders[folder] == nil ? number : nil, taken: sessionNumbers(showing: session.labelBase))
        desks[d].sessions.append(session)
        openIsland(for: id)
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
        let seated = seatedTeammates
        return islands.map { island in
            let seats = island.seats.map { occupant -> Seat? in
                switch occupant {
                case .session(let id)?:
                    return sessions[id].map {
                        .session($0, unseated: $0.teammates.filter { !seated.contains($0.id) }.count)
                    }
                case .teammate(let id)?:
                    return mates[id].map { .teammate($0.0, of: $0.1) }
                case nil:
                    return nil
                }
            }
            return Pod(slot: island.slot, seats: seats)
        }
    }

    /// Teammates with a seat; the others wait for one at their session's island.
    private var seatedTeammates: Set<String> {
        var seated: Set<String> = []
        for case .teammate(let id)? in islands.flatMap(\.seats) { seated.insert(id) }
        return seated
    }

    /// A new session's own island, at the free place nearest the door. No island ever moves.
    private mutating func openIsland(for session: String) {
        guard islands.count < Self.maxIslands else { return }
        let used = Set(islands.map(\.slot))
        var island = Island(slot: (0...).first { !used.contains($0) }!)
        island.seats[0] = .session(session)
        islands.append(island)
        islands.sort { $0.slot < $1.slot }
    }

    /// Seats a teammate at the first free seat of its session's island, whoever called it. False when there is
    /// none: it waits, counted on the session's tag.
    @discardableResult
    private mutating func sit(_ who: Occupant, at session: String) -> Bool {
        guard let i = islands.firstIndex(where: { $0.seats[0] == .session(session) }),
            let seat = islands[i].seats.firstIndex(of: nil)
        else { return false }
        islands[i].seats[seat] = who
        return true
    }

    private mutating func vacate(_ who: Occupant) {
        for i in islands.indices {
            if let seat = islands[i].seats.firstIndex(of: who) { islands[i].seats[seat] = nil }
        }
    }

    /// The smallest number from 1 that is not taken, so a newcomer never renumbers anyone already there.
    static func firstFree(_ taken: [Int]) -> Int {
        var number = 1
        while taken.contains(number) { number += 1 }
        return number
    }

    /// A session that ends leaves with its teammates, and its island goes; no other island moves.
    private mutating func removeSessions(where shouldRemove: (Session) -> Bool) {
        let leaving = desks.flatMap(\.sessions).filter(shouldRemove)
        for session in leaving {
            islands.removeAll { $0.seats[0] == .session(session.id) }
            links = links.filter { $0.value != session.id }
            news["s:" + session.id] = nil
            kinds["s:" + session.id] = nil
            calls[session.id] = nil
            for mate in session.teammates {
                news["a:" + mate.id] = nil
                kinds["a:" + mate.id] = nil
            }
        }
        for d in desks.indices {
            desks[d].sessions.removeAll { session in leaving.contains { $0.id == session.id } }
        }
        desks.removeAll { $0.sessions.isEmpty }
    }
}
