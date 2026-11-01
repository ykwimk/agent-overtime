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

/// An island as the office draws it: its place in the room and who is at each seat.
public struct Pod: Equatable, Identifiable {
    /// The island's place, 0 nearest the door.
    public let slot: Int
    public let seats: [Seat?]
    public var id: Int { slot }
}

/// Where things sit in the office, in art pixels. The art is drawn at a fixed 2 points per pixel, so a wider
/// window fits more islands in a row and nothing is ever scaled by a fraction.
///
/// An island from its top down: the name tags of the two seats across the desks (people facing the room), their
/// heads behind the far desks, the near desks, the chairs of the two seats with their backs to the room, and
/// their name tags. Rows of islands sit one after another; every other row is moved right, so islands don't
/// line up in columns.
public struct RoomLayout: Equatable {
    public static let pointsPerPixel = 2
    /// The back wall, door at its left end.
    public static let wall = 96
    public static let deskWidth = 58
    public static let islandWidth = deskWidth * 2
    /// The strip under the door that people walk down.
    public static let lane = 40
    /// Clear floor (one floor tile) between islands side by side, and before the right-hand column.
    public static let gap = 32
    /// How far every other row moves right. The gap it leaves at a row's end holds a plant, a tile clear of the
    /// island.
    public static let stagger = 64
    /// Floor kept free at the right for the meeting room and lounge.
    public static let pillarWidth = 192
    public static let margin = 8
    /// The first row's top (its far name tags reach over the foot of the wall), the distance between rows, and
    /// an island from the top of its far name tags to the bottom of its near ones (three lines each).
    public static let firstRow = 62
    public static let rowPitch = 145
    public static let islandDepth = 143
    /// From an island's top: the back edge of the far desks, and the top of the near desks' picture.
    public static let farDesk = 50
    public static let nearDesk = 58
    /// The default window shows four islands (16 people) and the right-hand column without scrolling: the lane,
    /// two islands, the row offset, the gaps and the column make 600 art pixels (8 to spare), and the wall, two
    /// rows and the top bar about 758 pt. 1216 × 760 stays inside a 1280 × 800 screen. The smallest window holds
    /// one island and its name tags.
    public static let defaultWindow = (width: 1216, height: 760)
    public static let minWindow = (width: 560, height: 470)

    /// Room width in pixels.
    public let width: Int
    /// Places in use: the highest island slot + 1.
    public let slots: Int
    public let columns: Int
    /// Where the right-hand column starts, or nil when the window has no room for it beside one island.
    public let pillar: Int?

    public init(width: Int, slots: Int) {
        self.width = width
        self.slots = slots
        let past = width - Self.margin - Self.lane - Self.stagger - Self.islandWidth  // past one island
        let besidePillar = past - Self.gap - Self.pillarWidth
        pillar = besidePillar >= 0 ? width - Self.margin - Self.pillarWidth : nil
        columns = max(1, (pillar == nil ? past : besidePillar) / (Self.islandWidth + Self.gap) + 1)
    }

    /// Room width for a window (or scroll view) this many points wide.
    public init(points: Double, slots: Int) {
        self.init(width: Int(points) / Self.pointsPerPixel, slots: slots)
    }

    public var rows: Int { max(1, (slots + columns - 1) / columns) }

    /// Pixels from the top of the wall to the bottom of the last row's name tags.
    public var contentHeight: Int { Self.firstRow + (rows - 1) * Self.rowPitch + Self.islandDepth }

    /// The top-left corner of an island's place. Places fill rows left to right, starting next to the door.
    public func origin(of slot: Int) -> (x: Int, y: Int) {
        let row = slot / columns
        return (
            Self.lane + row % 2 * Self.stagger + slot % columns * (Self.islandWidth + Self.gap),
            Self.firstRow + row * Self.rowPitch
        )
    }

    /// Seats 1 and 3 are across the desks, facing the room; 0 and 2 have their backs to it.
    public static func isAcross(_ seat: Int) -> Bool { seat % 2 == 1 }

    /// The left edge of a seat's desk, from the island's left.
    public static func deskX(_ seat: Int) -> Int { seat / 2 * deskWidth }

    /// The middle of the person in a seat, from the island's left.
    public static func personX(_ seat: Int) -> Int { deskX(seat) + (isAcross(seat) ? 35 : 36) }

    /// Where a person stands at a seat (their feet): in front of the chair, or behind the far desk.
    public func standPoint(slot: Int, seat: Int) -> (x: Int, y: Int) {
        let o = origin(of: slot)
        return Self.isAcross(seat)
            ? (o.x + Self.personX(seat), o.y + Self.farDesk - 2)
            : (o.x + Self.deskX(seat) + 30, o.y + Self.nearDesk + 62)
    }

    /// The line people walk along under an island's near name tags.
    func aisle(belowRow row: Int) -> Int { Self.firstRow + row * Self.rowPitch + Self.islandDepth - 2 }

    /// The door's feet point and the walking route from it to a seat: down the lane, along the aisle between
    /// rows (under the wall for the first row's far seats), then up or down to the seat. Nobody walks over the
    /// heads of people sitting there.
    public func route(slot: Int, seat: Int) -> [(x: Int, y: Int)] {
        let stand = standPoint(slot: slot, seat: seat)
        let laneX = Self.lane / 2 + 4
        let door = Self.wall + 2
        let row = slot / columns
        let aisle = Self.isAcross(seat) ? (row == 0 ? door : aisle(belowRow: row - 1)) : aisle(belowRow: row)
        return [(laneX, door), (laneX, aisle), (stand.x, aisle), stand]
    }
}
