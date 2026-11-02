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

    /// Pixels from the top of the wall to the bottom of the last row's name tags, or of the lounge when the
    /// right-hand column reaches further.
    public var contentHeight: Int {
        let islands = Self.firstRow + (rows - 1) * Self.rowPitch + Self.islandDepth
        return pillar == nil ? islands : max(islands, MeetingRoom.columnDepth)
    }

    /// The glass meeting room at the top of the right-hand column, or nil when the window has no column.
    public var meetingRoom: MeetingRoom? { pillar.map(MeetingRoom.init(left:)) }

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

    /// Where the lane runs, under the door.
    static let laneX = lane / 2 + 4

    /// Someone talking with a person across the desks stands at the island's end, feet this far below the
    /// island's top: heads about level, and the body and speaking mark clear of every name tag.
    public static let endStand = 74

    /// The aisle a seat is reached from: the one between its row and the row above for the seats across the
    /// desks (in the first row the one below it: the foot of the wall runs under the first row's name tags),
    /// below the island for the seats with their backs to the room.
    func aisle(slot: Int, seat: Int) -> Int {
        let row = slot / columns
        return aisle(belowRow: Self.isAcross(seat) ? max(0, row - 1) : row)
    }

    /// The middle of the clear floor at an island's end, beside a seat across the desks: left of seat 1, right of
    /// seat 3. Nobody's name tag reaches over it.
    func endX(slot: Int, seat: Int) -> Int {
        let o = origin(of: slot)
        return seat < 2 ? o.x - Self.gap / 2 : o.x + Self.islandWidth + Self.gap / 2
    }

    /// The door's feet point and the walking route from it to a seat: down the lane, along the aisle between
    /// rows, then up or down to the seat; the seats across the desks by the island's end. Nobody walks over the
    /// heads of people sitting there, or along the foot of the wall under the first row's name tags.
    public func route(slot: Int, seat: Int) -> [(x: Int, y: Int)] {
        path(from: doorSpot, to: deskSpot(slot: slot, seat: seat))
    }

    /// A place people walk to: the aisle it is reached from, where on that aisle they turn off, and the points
    /// from there on.
    public struct Spot {
        public let aisle: Int
        public let x: Int
        public let tail: [(x: Int, y: Int)]
    }

    /// Just inside the front door.
    public var doorSpot: Spot { Spot(aisle: Self.wall + 2, x: Self.laneX, tail: []) }

    /// A seat. Across the desks: up or down the island's end, then behind the far desk to the seat.
    public func deskSpot(slot: Int, seat: Int) -> Spot {
        let stand = standPoint(slot: slot, seat: seat)
        guard Self.isAcross(seat) else { return Spot(aisle: aisle(slot: slot, seat: seat), x: stand.x, tail: [stand]) }
        let end = endX(slot: slot, seat: seat)
        return Spot(aisle: aisle(slot: slot, seat: seat), x: end, tail: [(end, stand.y), stand])
    }

    /// Where someone stands to talk with the person sitting at a seat. Across the desks: at the island's end on
    /// that person's side. With the back to the room: on the aisle a step to the inner side, since that person's
    /// bubble sits at the outer shoulder, at the height of the visitor's speaking mark.
    public func besideSpot(slot: Int, seat: Int) -> Spot {
        let aisle = aisle(slot: slot, seat: seat)
        if Self.isAcross(seat) {
            let end = endX(slot: slot, seat: seat)
            return Spot(aisle: aisle, x: end, tail: [(end, origin(of: slot).y + Self.endStand)])
        }
        let outer = seat < 2 ? -20 : 20
        return Spot(aisle: aisle, x: standPoint(slot: slot, seat: seat).x - outer, tail: [])
    }

    /// A seat of the meeting room: up from the aisle under the first row, through the glass door, left of the
    /// table, and behind its chairs to the seats facing the room. nil without the right-hand column.
    public func roomSpot(_ seat: Int) -> Spot? {
        guard let room = meetingRoom else { return nil }
        let place = room.seats[seat]
        let step = room.doorstep
        let inside = seat < 3 ? [(step.x, MeetingRoom.behind), (place.x, MeetingRoom.behind)] : [(step.x, place.y)]
        return Spot(aisle: aisle(belowRow: 0), x: step.x, tail: [step] + inside + [place])
    }

    /// The walk from one spot to another: back to the first spot's aisle, along it, down the lane or the
    /// passage beside the right-hand column (whichever is shorter) when the aisles differ, along the second
    /// aisle, and on to the spot. A stretch that would go on and come back the same line is cut short (the
    /// first island's end is the lane itself).
    public func path(from a: Spot, to b: Spot) -> [(x: Int, y: Int)] {
        var points = a.tail.reversed() + [(a.x, a.aisle)]
        if a.aisle != b.aisle {
            // The passage keeps a step clear of the islands and of the pot beside the meeting room's glass.
            let ways = [Self.laneX] + (pillar.map { [$0 - 20] } ?? [])
            let way = ways.min { abs(a.x - $0) + abs(b.x - $0) < abs(a.x - $1) + abs(b.x - $1) }!
            points += [(way, a.aisle), (way, b.aisle)]
        }
        points += [(b.x, b.aisle)] + b.tail
        var kept: [(x: Int, y: Int)] = []
        for point in points {
            if kept.count >= 2 {
                let (p, q) = (kept[kept.count - 2], kept[kept.count - 1])
                if (p.x == q.x && q.x == point.x) || (p.y == q.y && q.y == point.y) { kept.removeLast() }
            }
            if kept.last.map({ $0 != point }) ?? true { kept.append(point) }
        }
        return kept
    }
}

/// The right-hand column: a glass meeting room against the back wall, a lounge under it. Art pixels, from the
/// column's left edge; the room reaches the window's right edge.
public struct MeetingRoom {
    /// The side glass, at the column's left edge.
    public let left: Int
    /// The foot of the front glass, and how tall the glass walls stand above their foot.
    public static let front = RoomLayout.wall + 90
    public static let glassHeight = 40
    /// The glass door in the front glass: its left edge (from the column) and width.
    public static let doorX = 20
    public static let doorWidth = 24
    /// The table for six: its top surface's top-left corner (from the column and the top of the room) and size.
    /// Laid out like an island: the faces behind it end at its top, the heads in front of it start below them, and
    /// the chairs in front reach down to the foot of the glass.
    public static let table = (x: 56, y: RoomLayout.wall + 22, width: 96, depth: 24)
    /// How far down the lounge under the meeting room reaches.
    public static let columnDepth = 340
    /// The line inside the room behind the chairs facing the room, along the foot of the wall.
    public static let behind = RoomLayout.wall + 2

    public init(left: Int) { self.left = left }

    /// Where the six sit, as their feet, left to right: 0–2 behind the table facing the room, 3–5 in front of it
    /// with their backs to it. Named here for the walks to a meeting.
    public var seats: [(x: Int, y: Int)] {
        let t = Self.table
        let middles = (0..<3).map { left + t.x + 16 + $0 * 32 }
        return middles.map { ($0, t.y - 2) } + middles.map { ($0, t.y + 62) }
    }

    /// Just outside the glass door: where a walk to a meeting turns in.
    public var doorstep: (x: Int, y: Int) { (left + Self.doorX + Self.doorWidth / 2, Self.front + 10) }

    /// Pots in a row along the front glass, one beside the door on each side and the door itself kept clear:
    /// the middle of each pot's foot.
    public var planters: [(x: Int, y: Int)] {
        let foot = Self.front + 8
        let right = left + Self.doorX + Self.doorWidth + 18
        return [(left + 4, foot)] + (0..<5).map { (right + $0 * 30, foot) }
    }

    /// The floor a pot stands on, around the middle of its foot.
    public static func footprint(_ pot: (x: Int, y: Int)) -> (x: Int, y: Int, width: Int, height: Int) {
        (pot.x - 14, pot.y - 10, 28, 10)
    }
}
