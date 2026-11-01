import Foundation

/// Day or night by this Mac's clock only (no location, no network): day 07:00–18:59, night 19:00–06:59.
public enum Daylight: Equatable {
    case day, night

    public static func at(_ date: Date, calendar: Calendar = .current) -> Daylight {
        (7..<19).contains(calendar.component(.hour, from: date)) ? .day : .night
    }

    /// 0 by day, 1 at night. The first `fade` seconds after 07:00 and 19:00 blend, so the room dims gently.
    public static func darkness(at date: Date, calendar: Calendar = .current, fade: TimeInterval = 3) -> Double {
        let night = at(date, calendar: calendar) == .night
        let parts = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        guard parts.hour == 7 || parts.hour == 19, parts.minute == 0 else { return night ? 1 : 0 }
        let seconds = Double(parts.second ?? 0) + Double(parts.nanosecond ?? 0) / 1e9
        let progress = min(1, seconds / fade)
        return night ? progress : 1 - progress
    }
}

/// One row of four desks: a session at the left desk, its teammates at the three beside it.
public struct Pod: Equatable, Identifiable {
    public static let sideDesks = 3

    /// The session id, or "off:" + folder for a remembered desk nobody is at.
    public let id: String
    public let folder: String
    /// The folder's name; a folder's second session is "name 2".
    public let name: String
    /// nil when off duty.
    public let session: Session?
    /// The three side desks, left to right.
    public let mates: [Teammate?]
    /// Teammates without a desk, shown as "+n".
    public let extra: Int

    public var isOff: Bool { session == nil }

    /// The session itself does not wait, but a teammate does (the summary and menu count it as waiting).
    public var teammateWaiting: Bool {
        guard let session else { return false }
        return session.state != .waiting && session.shown.state == .waiting
    }

    /// Which of the four desks have someone at them. Only these get a lit lamp at night.
    public var occupied: [Bool] { [session != nil] + mates.map { $0 != nil } }
}

/// Keeps every teammate at the same side desk while it works; the list order alone would shuffle them.
public struct SeatPlan {
    /// Session id → the teammate id at each side desk.
    private var desks: [String: [String?]] = [:]

    public init() {}

    /// One pod per running session (a folder's sessions side by side), then one per remembered empty folder.
    public mutating func pods(for office: OfficeState) -> [Pod] {
        var pods: [Pod] = []
        var running: Set<String> = []
        for desk in office.desks {
            guard !desk.isOff else {
                pods.append(
                    Pod(
                        id: "off:" + desk.folder, folder: desk.folder, name: desk.name, session: nil,
                        mates: Array(repeating: nil, count: Pod.sideDesks), extra: 0))
                continue
            }
            for (index, session) in desk.sessions.enumerated() {
                running.insert(session.id)
                let present = Set(session.teammates.map(\.id))
                var ids = (desks[session.id] ?? Array(repeating: nil, count: Pod.sideDesks)).map { id in
                    id.flatMap { present.contains($0) ? $0 : nil }
                }
                for mate in session.teammates where !ids.contains(mate.id) {
                    guard let free = ids.firstIndex(of: nil) else { break }
                    ids[free] = mate.id
                }
                desks[session.id] = ids
                let byID = Dictionary(session.teammates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let mates = ids.map { $0.flatMap { byID[$0] } }
                pods.append(
                    Pod(
                        id: session.id, folder: desk.folder, name: index == 0 ? desk.name : "\(desk.name) \(index + 1)",
                        session: session, mates: mates, extra: session.teammates.count - mates.compactMap { $0 }.count))
            }
        }
        desks = desks.filter { running.contains($0.key) }
        return pods
    }
}

/// Where things sit in the office, in art pixels. The art is drawn at a fixed 2 points per pixel, so a wider
/// window fits more pods in a row and nothing is ever scaled by a fraction.
public struct RoomLayout: Equatable {
    public static let pointsPerPixel = 2
    /// The back wall, door at its left end.
    public static let wall = 96
    public static let deskWidth = 58
    public static let podWidth = deskWidth * 4
    /// The strip under the door that people walk down.
    public static let lane = 40
    public static let gap = 24
    public static let margin = 8
    /// The top of the first row of desks, the distance between rows, and how far a pod reaches below its
    /// desk top (chairs and three lines of name tag).
    public static let firstRow = wall + 14
    public static let rowPitch = 100
    public static let podDepth = 90
    /// Window sizes in points. Two pods side by side need the lane plus 2 × 464 pt of desks, and two rows need
    /// the wall, the rows and the top bar, so four pods fit without scrolling.
    public static let defaultWindow = (width: 1080, height: 680)
    public static let minWindow = (width: 560, height: 470)

    /// Room width in pixels.
    public let width: Int
    public let podCount: Int
    public let columns: Int

    public init(width: Int, podCount: Int) {
        self.width = width
        self.podCount = podCount
        columns = max(1, (width - Self.lane - Self.margin + Self.gap) / (Self.podWidth + Self.gap))
    }

    /// Room width for a window (or scroll view) this many points wide.
    public init(points: Double, podCount: Int) {
        self.init(width: Int(points) / Self.pointsPerPixel, podCount: podCount)
    }

    public var rows: Int { max(1, (podCount + columns - 1) / columns) }

    /// Pixels from the top of the wall to the bottom of the last row's name tags.
    public var contentHeight: Int { Self.firstRow + (rows - 1) * Self.rowPitch + Self.podDepth }

    /// The top-left corner of a pod's first desk. Pods fill rows left to right, starting next to the door.
    public func origin(of pod: Int) -> (x: Int, y: Int) {
        (Self.lane + (pod % columns) * (Self.podWidth + Self.gap), Self.firstRow + (pod / columns) * Self.rowPitch)
    }

    /// Where a person stands at a desk (their feet), and the line in front of the chairs people walk along.
    public func standPoint(pod: Int, desk: Int) -> (x: Int, y: Int) {
        let o = origin(of: pod)
        return (o.x + desk * Self.deskWidth + 30, o.y + 62)
    }

    /// The door's feet point and the walking route from it to a desk: down the lane, then along the row.
    public func route(pod: Int, desk: Int) -> [(x: Int, y: Int)] {
        let stand = standPoint(pod: pod, desk: desk)
        let laneX = Self.lane / 2 + 4
        return [(laneX, Self.wall + 2), (laneX, stand.y), stand]
    }
}
