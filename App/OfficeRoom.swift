import AppKit
import SwiftUI

/// Who walks where: each time the office changes it lays out the islands and plans the walks: in through the
/// door and out, over to a newcomer's desk to talk, and to the meeting room and back.
final class Stage: ObservableObject {
    typealias Point = (x: Int, y: Int)

    /// Where someone is when they are not walking.
    enum Place: Equatable {
        case desk
        /// A seat of the meeting room's table.
        case room(Int)
    }

    /// A stretch of a trip: a walk along points, or a pause where the walker stands and talks.
    private struct Leg {
        var points: [Point]
        var pause: TimeInterval = 0
        /// Which way they look during a pause, and the speaking mark's corner.
        var facing = Walker.Facing.down
        var talk: Point?

        var duration: TimeInterval { points.count > 1 ? Stage.length(points) / Stage.speed : pause }
    }

    /// One person's way from a place to another (nil: the front door), from `start`.
    private struct Trip {
        let look: Look
        var start: Date
        var legs: [Leg]
        var from: Place?
        var to: Place?
        /// On the way in for the first time: their desk looks empty meanwhile. Anyone else's desk keeps its
        /// laptop on while they are away.
        var arriving = false
        /// Whom the walk is a visit to.
        var partner: String?

        var end: Date { start + legs.reduce(0) { $0 + $1.duration } }
    }

    /// Someone at a seat of an island.
    private struct Person {
        let look: Look
        let slot: Int
        let seat: Int
        let arrived: Date?
        let session: String
        let isSession: Bool
        let state: WorkState
        /// Its session is in a meeting.
        let meets: Bool
        /// The teammate that called this one, if a teammate did.
        var caller: String? = nil
        var place = Place.desk
        var waits: Bool { state == .waiting }
        /// Who a teammate goes to and comes from: the teammate that called it, else its session.
        var host: String { caller.map { "m:" + $0 } ?? "p:" + session }
    }

    /// Everyone on the move at one moment.
    struct Moment {
        /// Walking: drawn each frame in their own small boxes over the room.
        var walkers: [Walker] = []
        /// Standing still to talk, drawn into the room with their speaking marks.
        var standing: [Walker] = []
        var talks: [Point] = []
        /// Still on their way in: their desks look empty.
        var away: Set<String> = []
        /// Away from their desks for a while: chair in, laptop on.
        var out: Set<String> = []
        /// Sitting in the meeting room.
        var room: [RoomPerson] = []
        var doorOpen = false
        var meetingDoorOpen = false
    }

    /// The picture ticks fast until this moment (someone is walking), and slowly after.
    private(set) var busyUntil = Date.distantPast
    /// Who wears headphones: teammates working on their own, and anyone screenshots add.
    var headphones: Set<String> = []
    private var wearing: Set<String> = []
    private var allHeadphones: Set<String> { headphones.union(wearing) }

    private var office: OfficeState?
    private var layout = RoomLayout(width: 0, slots: 0)
    private var pods: [Pod] = []
    /// Islands whose session has ended, kept empty until the last of its people is out of the door, by slot.
    private var emptying: [Int: Date] = [:]
    private var present: [String: Person] = [:]
    private var trips: [String: Trip] = [:]
    /// Speaking marks shown at a seat instead of a walk (Reduce Motion): from, until, where, the session, the
    /// newcomer it is for.
    private var seatTalks: [(start: Date, end: Date, at: Point, host: String, partner: String?)] = []
    /// The last message between two people already played.
    private var lastTalk = 0
    /// Goes up whenever the pods or the room change, so a cached picture is never reused across a change.
    private(set) var generation = 0

    /// Pixels a second, the same on every route: about 5 s from the door to the farthest seat of the default
    /// window, about 1 s to the nearest. The owner found 150 px/s a little fast.
    static let speed = 120.0
    /// Pixels walked per frame of the six-frame walk, so the feet keep pace with the floor at any speed (10 frames
    /// a second at 120 px/s).
    private static let stride = 12.0
    /// How long two people stand and talk.
    static let talkTime: TimeInterval = 2
    /// A teammate done sooner than this after it came just leaves: short calls are common.
    static let quick: TimeInterval = 5
    /// Teammates that come this close together are sent off together: no visits, they may meet.
    static let together: TimeInterval = 2
    /// At most this many walk at once.
    static let maxWalkers = 6
    /// Where the session sits at the meeting table (the middle, facing the room), and its teammates in turn: the
    /// rest of that side first, then across, the middle across last.
    static let sessionSeat = 1
    static let teammateSeats = [0, 2, 3, 5, 4]

    /// Called while drawing. Publishes nothing synchronously, so it is safe inside a view's body.
    func sync(_ office: OfficeState, width: Int, now: Date, animate: Bool) -> (pods: [Pod], layout: RoomLayout) {
        guard office != self.office || width != layout.width else { return (pods, layout) }
        let before = layout
        generation += 1
        self.office = office
        pods = office.pods
        layout = RoomLayout(width: width, slots: (pods.last?.slot ?? -1) + 1)
        trips = trips.filter { $0.value.end > now }
        seatTalks.removeAll { $0.end <= now }

        let people = Self.people(pods, meeting: layout.meetingRoom == nil ? nil : office.meeting)
        wearing = Set(office.desks.flatMap(\.teammates).filter(\.headphones).map { "m:" + $0.id })
        if animate {
            for (id, person) in people where present[id] == nil { arrive(id, person) }
            checkVisits(people, now)
            for (id, person) in present where people[id] == nil { leave(id, person, people, before, now) }
        }
        // A session that ends walks out with its teammates; its island goes once the last of them is out. A new
        // island at that place takes over at once. Only the rows change, so the walks planned above still hold.
        let seated = Set(pods.map(\.slot))
        for (id, person) in present where people[id] == nil && !seated.contains(person.slot) {
            guard let end = trips[id]?.end else { continue }
            emptying[person.slot] = max(emptying[person.slot] ?? end, end)
        }
        emptying = emptying.filter { $0.value > now && !seated.contains($0.key) }
        if !emptying.isEmpty {
            pods += emptying.keys.map { Pod(slot: $0, seats: Array(repeating: nil, count: Island.size)) }
            pods.sort { $0.slot < $1.slot }
            layout = RoomLayout(width: width, slots: (pods.last?.slot ?? -1) + 1)
        }
        // To the meeting room and back. Only when the office changes: a new width (the meeting room comes and
        // goes with it) leaves everyone's walks as they are.
        for (id, person) in people where before.width == layout.width {
            guard let old = present[id], old.place != person.place else { continue }
            if animate { move(id, person, from: old.place, now) } else { trips[id] = nil }
        }
        if animate {
            for (id, person) in people where present[id] == nil && !person.isSession { visit(id, person, people, now) }
        } else {
            talkInPlace(people, now)
        }
        if let talk = office.talk, talk.serial != lastTalk {
            lastTalk = talk.serial
            // A message from before the window opened is old news.
            if before.width > 0 { converse(talk, people, now, animate: animate) }
        }
        present = people

        busyUntil = trips.values.map(\.end).max() ?? .distantPast
        return (pods, layout)
    }

    /// Everyone at a seat, and where they are: at their desks, or the meeting's at the meeting table.
    private static func people(_ pods: [Pod], meeting: OfficeState.Meeting?) -> [String: Person] {
        var people: [String: Person] = [:]
        for pod in pods {
            for (index, seat) in pod.seats.enumerated() {
                guard let seat, let id = OfficeScene.id(seat), let look = OfficeScene.look(seat) else { continue }
                switch seat {
                case .session(let session, _):
                    people[id] = Person(
                        look: look, slot: pod.slot, seat: index, arrived: session.arrived, session: session.id,
                        isSession: true, state: session.state, meets: session.meets)
                    if meeting?.session.id == session.id { people[id]?.place = .room(sessionSeat) }
                case .teammate(let mate, let session):
                    people[id] = Person(
                        look: look, slot: pod.slot, seat: index, arrived: mate.arrived, session: session.id,
                        isSession: false, state: mate.state, meets: session.meets(with: mate), caller: mate.calledBy)
                    if meeting?.session.id == session.id,
                        let turn = meeting?.members.firstIndex(where: { $0.id == mate.id })
                    {
                        people[id]?.place = .room(teammateSeats[turn])
                    }
                }
            }
        }
        return people
    }

    /// Plans a trip, unless six people already walk when it starts: anyone more is just there at once.
    private func start(_ id: String, _ trip: Trip) {
        let walking = trips.filter { $0.key != id && $0.value.start <= trip.start && trip.start < $0.value.end }
        trips[id] = walking.count < Self.maxWalkers ? trip : nil
    }

    /// A walk in starts when the person arrived, not when the window first draws it: a window drawn late still
    /// shows the walk, or the person seated once it would be over.
    private func arrive(_ id: String, _ person: Person) {
        guard let arrived = person.arrived, let to = spot(person.place, person, layout) else { return }
        start(
            id,
            Trip(
                look: person.look, start: arrived, legs: [Leg(points: layout.path(from: layout.doorSpot, to: to))],
                from: nil, to: person.place, arriving: true))
    }

    /// Where a place is, for someone sitting at a seat of an island; nil is the front door.
    private func spot(_ place: Place?, _ person: Person, _ room: RoomLayout) -> RoomLayout.Spot? {
        switch place {
        case nil: return room.doorSpot
        case .desk?: return room.deskSpot(slot: person.slot, seat: person.seat)
        case .room(let seat)?: return room.roomSpot(seat)
        }
    }

    /// ③ Over to the meeting table, or back to the desk. Someone on the way the other way turns back; someone on
    /// the way elsewhere gets there first.
    private func move(_ id: String, _ person: Person, from old: Place, _ now: Date) {
        guard let to = spot(person.place, person, layout) else { return }
        if var trip = trips[id], trip.start <= now {
            if trip.from == person.place, let back = Self.turnedBack(trip, at: now) {
                trips[id] = back
            } else if trip.to != person.place, let end = spot(trip.to, person, layout) {
                trip.legs.append(Leg(points: layout.path(from: end, to: to)))
                trip.to = person.place
                trips[id] = trip
            }
            return
        }
        trips[id] = nil
        guard let from = spot(old, person, layout) else { return }
        start(
            id,
            Trip(
                look: person.look, start: now, legs: [Leg(points: layout.path(from: from, to: to))], from: old,
                to: person.place))
    }

    /// ① Once a newcomer sits down, whoever called it (its session, or the teammate that called it) walks over to
    /// its desk, talks for a moment and walks back. Not while the caller waits for an answer or meets, and not when
    /// two or more came within `together`: they may meet instead (③).
    private func visit(_ id: String, _ mate: Person, _ people: [String: Person], _ now: Date) {
        let host = mate.host
        guard let arrived = mate.arrived else { return }
        let others = Self.cameWith(id, mate, people)
        if !others.isEmpty {
            if let partner = trips[host]?.partner, others.contains(partner), trips[host]!.start > now {
                trips[host] = nil
            }
            return
        }
        guard let session = people[host], session.place == .desk, !session.waits, !session.meets else { return }
        // shortcut: a newcomer who sits down while the session is already on its way gets no visit; queue visits if
        // teammates that start one after another while others still work turn out to be common.
        guard trips[host] == nil else { return }
        let home = layout.deskSpot(slot: session.slot, seat: session.seat)
        let there = layout.path(from: home, to: layout.besideSpot(slot: mate.slot, seat: mate.seat))
        start(
            host,
            Trip(
                look: session.look, start: max(trips[id]?.end ?? arrived, arrived + Self.together),
                legs: [Leg(points: there), talk(at: there.last!, with: mate), Leg(points: Array(there.reversed()))],
                from: .desk, to: .desk, partner: id))
    }

    /// The other teammates of the same caller that came within `together` of this one.
    private static func cameWith(_ id: String, _ mate: Person, _ people: [String: Person]) -> Set<String> {
        guard let arrived = mate.arrived else { return [] }
        return Set(
            people.filter { other in
                other.key != id && !other.value.isSession && other.value.host == mate.host
                    && other.value.arrived.map { abs($0.timeIntervalSince(arrived)) < Self.together } ?? false
            }.keys)
    }

    /// ② Who a leaving teammate reports to, its caller: at its desk (not in the meeting room), and only after the
    /// teammate worked a while.
    private func host(reportedToBy person: Person, _ people: [String: Person], _ now: Date) -> Person? {
        let id = person.host
        guard !person.isSession, person.place == .desk, let host = people[id], host.place == .desk,
            present[id]?.place == .desk, now.timeIntervalSince(person.arrived ?? .distantPast) >= Self.quick
        else { return nil }
        return host
    }

    /// With Reduce Motion nobody walks: ① and ② show as the speaking mark at the session's own seat for a moment,
    /// on the same terms as the walks.
    private func talkInPlace(_ people: [String: Person], _ now: Date) {
        seatTalks.removeAll { talk in
            let busy = people[talk.host].map { $0.waits || $0.meets } ?? true
            return talk.start > now && (busy || talk.partner.map { people[$0] == nil } ?? false)
        }
        for (id, mate) in people where present[id] == nil && !mate.isSession {
            let others = Self.cameWith(id, mate, people)
            if !others.isEmpty {
                seatTalks.removeAll { $0.start > now && others.contains($0.partner ?? "") }
                continue
            }
            let host = mate.host
            guard let arrived = mate.arrived, let caller = people[host], caller.place == .desk, !caller.waits,
                !caller.meets
            else { continue }
            let start = arrived + Self.together
            seatTalks.append((start, start + Self.talkTime, markAtSeat(caller), host, id))
        }
        for (id, mate) in present where people[id] == nil {
            guard let caller = host(reportedToBy: mate, people, now) else { continue }
            seatTalks.append((now, now + Self.talkTime, markAtSeat(caller), mate.host, nil))
        }
    }

    /// A message between two people here: the sender walks over to the other's desk, talks for a moment and
    /// walks back. Both at the meeting table, or with Reduce Motion: only the speaking mark, at the sender's seat.
    /// Someone already on the way doesn't set off again.
    private func converse(_ talk: OfficeState.Talk, _ people: [String: Person], _ now: Date, animate: Bool) {
        let from = talk.from.map { "m:" + $0 } ?? "p:" + talk.session
        let to = talk.to.map { "m:" + $0 } ?? "p:" + talk.session
        guard let sender = people[from], let receiver = people[to], trips[from] == nil else { return }
        guard animate, sender.place == .desk, receiver.place == .desk else {
            seatTalks.append((now, now + Self.talkTime, markAtSeat(sender), from, nil))
            return
        }
        let home = layout.deskSpot(slot: sender.slot, seat: sender.seat)
        let there = layout.path(from: home, to: layout.besideSpot(slot: receiver.slot, seat: receiver.seat))
        start(
            from,
            Trip(
                look: sender.look, start: now,
                legs: [
                    Leg(points: there), self.talk(at: there.last!, with: receiver),
                    Leg(points: Array(there.reversed())),
                ],
                from: .desk, to: .desk, partner: to))
    }

    /// The speaking mark at someone's own seat, on the side away from their state bubble; at the meeting table,
    /// at their seat there.
    private func markAtSeat(_ person: Person) -> Point {
        if case .room(let seat) = person.place, let room = layout.meetingRoom {
            let x = room.seats[seat].x
            let table = MeetingRoom.table
            return seat < 3 ? (x - 25, table.y - 26) : (seat == 3 ? x + 12 : x - 28, table.y + 30)
        }
        let origin = layout.origin(of: person.slot)
        let x = origin.x + RoomLayout.personX(person.seat)
        if RoomLayout.isAcross(person.seat) { return (x - 25, origin.y + RoomLayout.farDesk - 26) }
        return (person.seat == 0 ? x + 12 : x - 28, origin.y + RoomLayout.nearDesk + 22)
    }

    /// A visit not under way yet is dropped once its host waits for an answer or meets. One whose newcomer has
    /// left before it began is dropped; under way, the host turns back at once.
    private func checkVisits(_ people: [String: Person], _ now: Date) {
        for (host, trip) in trips {
            guard let partner = trip.partner else { continue }
            let busy = people[host].map { $0.waits || $0.meets } ?? true
            if trip.start > now, busy || people[partner] == nil {
                trips[host] = nil
            } else if people[partner] == nil, let back = Self.turnedBack(trip, at: now) {
                trips[host] = back
            }
        }
    }

    /// Out through the door. ② A teammate that worked a while first walks to its session's desk and reports,
    /// unless the session is in the meeting room. Someone still walking in turns back; someone on their way
    /// elsewhere gets there first.
    private func leave(_ id: String, _ person: Person, _ people: [String: Person], _ room: RoomLayout, _ now: Date) {
        if var trip = trips[id], trip.start <= now {
            if trip.from == nil, let back = Self.turnedBack(trip, at: now) {
                trips[id] = back
            } else if let end = spot(trip.to, person, room) {
                trip.legs.append(Leg(points: room.path(from: end, to: room.doorSpot)))
                trip.to = nil
                trips[id] = trip
            }
            return
        }
        guard let here = spot(person.place, person, room) else {
            trips[id] = nil
            return
        }
        var legs = [Leg(points: room.path(from: here, to: room.doorSpot))]
        if let host = host(reportedToBy: person, people, now) {
            let desk = room.deskSpot(slot: person.slot, seat: person.seat)
            let beside = room.besideSpot(slot: host.slot, seat: host.seat)
            let there = room.path(from: desk, to: beside)
            legs = [
                Leg(points: there), talk(at: there.last!, with: host, in: room),
                Leg(points: room.path(from: beside, to: room.doorSpot)),
            ]
        }
        start(id, Trip(look: person.look, start: now, legs: legs, from: person.place, to: nil))
    }

    /// The trip turned around at `now`, back the way it came; nil once it is past its pause (on the way back
    /// already).
    private static func turnedBack(_ trip: Trip, at now: Date) -> Trip? {
        var elapsed = max(0, now.timeIntervalSince(trip.start))
        var passed: [Point] = []
        for leg in trip.legs {
            guard leg.points.count > 1 else {
                if elapsed < leg.duration { break }
                return nil
            }
            let walked = min(elapsed, leg.duration) * speed
            var distance = 0.0
            passed.append(leg.points[0])
            for (from, to) in zip(leg.points, leg.points.dropFirst()) {
                distance += hypot(Double(to.x - from.x), Double(to.y - from.y))
                guard distance <= walked else { break }
                passed.append(to)
            }
            if elapsed < leg.duration {
                passed.append(along(leg.points, walked).point)
                break
            }
            elapsed -= leg.duration
        }
        return Trip(
            look: trip.look, start: now, legs: [Leg(points: passed.reversed())], from: trip.to, to: trip.from,
            arriving: trip.arriving)
    }

    /// Standing at `at` and talking with the person at `other`'s seat: facing them, the speaking mark beside the
    /// head on their side. At an island's end the mark stays over the clear floor there, above the head: their
    /// name tag and bubble reach right up to the island's edge.
    private func talk(at: Point, with other: Person, in room: RoomLayout? = nil) -> Leg {
        let room = room ?? layout
        let x = room.origin(of: other.slot).x + RoomLayout.personX(other.seat)
        if RoomLayout.isAcross(other.seat) {
            return Leg(
                points: [at], pause: Self.talkTime, facing: x >= at.x ? .right : .left,
                talk: (x >= at.x ? at.x : at.x - 16, at.y - 53))
        }
        return Leg(
            points: [at], pause: Self.talkTime, facing: .up, talk: (x >= at.x ? at.x + 5 : at.x - 21, at.y - 50))
    }

    static func length(_ route: [(x: Int, y: Int)]) -> Double {
        zip(route, route.dropFirst()).reduce(0) { $0 + hypot(Double($1.1.x - $1.0.x), Double($1.1.y - $1.0.y)) }
    }

    /// The point `distance` pixels along a route, and which way the walker faces there.
    private static func along(_ route: [Point], _ distance: Double) -> (point: Point, facing: Walker.Facing) {
        var left = distance
        var point = route[0]
        var facing = Walker.Facing.down
        for (from, to) in zip(route, route.dropFirst()) {
            let segment = hypot(Double(to.x - from.x), Double(to.y - from.y))
            guard segment > 0 else { continue }
            if to.x != from.x {
                facing = to.x > from.x ? .right : .left
            } else {
                facing = to.y > from.y ? .down : .up
            }
            let t = min(1, left / segment)
            point = (
                from.x + Int((Double(to.x - from.x) * t).rounded()),
                from.y + Int((Double(to.y - from.y) * t).rounded())
            )
            left -= segment
            if left <= 0 { break }
        }
        return (point, facing)
    }

    /// Where a trip has someone at `now`, and the speaking mark if they stand and talk; nil before it starts and
    /// once it is over.
    private static func walker(_ trip: Trip, at now: Date) -> (walker: Walker, talk: Point?)? {
        var elapsed = now.timeIntervalSince(trip.start)
        guard elapsed >= 0, now < trip.end else { return nil }
        for (index, leg) in trip.legs.enumerated() {
            if elapsed >= leg.duration, index < trip.legs.count - 1 {
                elapsed -= leg.duration
                continue
            }
            guard leg.points.count > 1 else {
                let at = leg.points[0]
                return (Walker(look: trip.look, x: at.x, y: at.y, facing: leg.facing, step: 0), leg.talk)
            }
            let (point, facing) = along(leg.points, elapsed * speed)
            let step = Int((elapsed * speed / stride).rounded(.down))
            return (Walker(look: trip.look, x: point.x, y: point.y, facing: facing, step: step), nil)
        }
        return nil
    }

    /// The next moment after `now` that something starts or stops on its own (a walk, a speaking mark), so a slow
    /// picture still draws it on time.
    func nextChange(after now: Date) -> Date? {
        (trips.values.flatMap { [$0.start, $0.end] } + seatTalks.flatMap { [$0.start, $0.end] }).filter { $0 > now }
            .min()
    }

    /// Whose desk a point of the picture (art pixels) shows: someone sitting there, or someone at the meeting
    /// table (their own desk's seat is given). Nobody while they walk.
    func seat(at point: (x: Int, y: Int), now: Date) -> (slot: Int, index: Int)? {
        let walking = Set(trips.filter { $0.value.start <= now && now < $0.value.end }.keys)
        if let room = layout.meetingRoom {
            let table = MeetingRoom.table
            for (id, person) in present where !walking.contains(id) {
                guard case .room(let seat) = person.place else { continue }
                let top = seat < 3 ? table.y - 28 : table.y + 10
                if abs(point.x - room.seats[seat].x) <= 14, (top..<top + 36).contains(point.y) {
                    return (person.slot, person.seat)
                }
            }
        }
        for pod in pods {
            let origin = layout.origin(of: pod.slot)
            guard (origin.x..<origin.x + RoomLayout.islandWidth).contains(point.x),
                (origin.y..<origin.y + RoomLayout.islandDepth).contains(point.y)
            else { continue }
            let index =
                (point.x < origin.x + RoomLayout.deskWidth ? 0 : 2) + (point.y < origin.y + RoomLayout.nearDesk ? 1 : 0)
            return pod.seats[index] == nil ? nil : (pod.slot, index)
        }
        return nil
    }

    /// Where everyone on the move is at `now`, and who sits in the meeting room.
    func moment(at now: Date) -> Moment {
        var moment = Moment()
        let door = layout.doorSpot
        let glassDoor = layout.meetingRoom.map { (x: $0.doorstep.x, y: MeetingRoom.front) }
        for (id, trip) in trips {
            guard let (walker, talk) = Self.walker(trip, at: now) else { continue }
            if trip.arriving { moment.away.insert(id) } else { moment.out.insert(id) }
            if let talk {
                moment.standing.append(walker)
                moment.talks.append(talk)
                continue
            }
            moment.walkers.append(walker)
            if abs(walker.x - door.x) + abs(walker.y - door.aisle) < 30 { moment.doorOpen = true }
            if let glassDoor, abs(walker.x - glassDoor.x) + abs(walker.y - glassDoor.y) < 20 {
                moment.meetingDoorOpen = true
            }
        }
        for talk in seatTalks where talk.start <= now && now < talk.end { moment.talks.append(talk.at) }
        for (id, person) in present {
            guard case .room(let seat) = person.place, !moment.away.contains(id), !moment.out.contains(id) else {
                continue
            }
            moment.out.insert(id)
            moment.room.append(
                RoomPerson(look: person.look, seat: seat, state: person.state, headphones: allHeadphones.contains(id)))
        }
        return moment
    }

    /// The office at `now` with the people standing still, and those walking (drawn in their own boxes).
    func scene(at now: Date, frame: Int, height: Int, reduceMotion: Bool) -> (scene: OfficeScene, walkers: [Walker]) {
        let moment = moment(at: now)
        // Rounded so the room and the boxes, drawn at different moments, share one light.
        let darkness = (Daylight.darkness(at: now) * 100).rounded() / 100
        var scene = OfficeScene(
            layout: layout, height: height, pods: pods.filter { emptying[$0.slot].map { now < $0 } ?? true },
            darkness: darkness, frame: frame, now: now,
            walkers: moment.standing, away: moment.away, doorOpen: moment.doorOpen && !reduceMotion,
            headphones: allHeadphones)
        scene.out = moment.out
        scene.talks = moment.talks
        scene.room = moment.room.sorted { $0.seat < $1.seat }
        scene.meetingLit = layout.meetingRoom != nil && office?.meeting != nil
        scene.meetingDoorOpen = moment.meetingDoorOpen && !reduceMotion
        return (scene, moment.walkers)
    }

    /// The room without walkers, and a piece of the finished picture around each walker.
    typealias Picture = (room: CGImage?, walkers: [(box: CGRect, image: CGImage?)])

    private var last: (key: String, picture: Picture)?
    private var room: (key: String, image: CGImage?, lights: Lights)?
    /// The 2.5-a-second frame held while someone walks: drawing the whole room again under the walkers cost more
    /// than the walks themselves, so typing, nodding and the hopping "!" wait for the few seconds of a walk.
    private var heldFrame: Int?

    /// The office at `now`. The room is drawn again only when it changes (the 2.5-a-second frame while nobody
    /// walks, the clock's minute, the light, the door, someone sitting down or standing to talk); each frame of a
    /// walk draws only the walkers' boxes. A box is the whole office drawn inside it, so a walker stays under the
    /// night light and behind lit lamps and bubbles exactly as in one picture. A tick can draw the view twice; the
    /// second time reuses the first.
    func picture(at now: Date, frame: Int, height: Int, reduceMotion: Bool) -> Picture {
        let key = "\(now.timeIntervalSinceReferenceDate) \(frame) \(height) \(layout.width) \(generation)"
        if let last, last.key == key { return last.picture }
        var (scene, walking) = scene(at: now, frame: frame, height: height, reduceMotion: reduceMotion)
        heldFrame = walking.isEmpty ? nil : heldFrame ?? frame
        scene.frame = heldFrame ?? frame
        let minute = Int(now.timeIntervalSinceReferenceDate / 60)
        let roomKey =
            "\(scene.frame) \(minute) \(scene.darkness) \(scene.doorOpen) \(scene.away.sorted()) \(scene.out.sorted()) "
            + "\(scene.walkers.map { "\($0.x),\($0.y)" }) \(scene.talks.map { "\($0.x),\($0.y)" }) \(height) "
            + "\(layout.width) \(generation) \(scene.pods.count) "
            + "\(allHeadphones.sorted()) \(scene.room.map { "\($0.seat)\($0.state)" }) \(scene.meetingDoorOpen) "
            + "\(scene.meetingLit)"
        if room?.key != roomKey {
            let drawn = OfficeRenderer().renderWithLights(scene)
            room = (roomKey, drawn.image, drawn.lights)
        }
        scene.walkers += walking
        scene.lights = room?.lights
        let bounds = CGRect(x: 0, y: 0, width: layout.width, height: height)
        let walkers = walking.map { walker -> (box: CGRect, image: CGImage?) in
            let box = walker.box.intersection(bounds)
            return (box, box.isEmpty ? nil : OfficeRenderer().render(scene, crop: box))
        }
        let picture = (room?.image, walkers)
        last = (key, picture)
        return picture
    }
}

/// The office as one picture, laid out for the window at normal size and shown at the zoom like a map (`Zoom`),
/// with system-font name tags on the floor in front of each desk. Pods fill rows from the door; more pods add rows
/// and the room scrolls, with a line at the edge for islands out of sight. Zoomed in, the room also scrolls
/// sideways; zoomed out, it sits at the top left.
struct OfficeRoom: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var systemReducesMotion
    @StateObject private var stage: Stage
    @StateObject private var zoom: OfficeZoom
    @ObservedObject var panel: SidePanel
    var focus: FocusState<OfficeFocus?>.Binding
    /// Screenshots pin the clock; the frame then stays at 0.
    let fixedNow: Date?
    /// Only the CPU test sets this: its window may open behind a full-screen app, where nothing would tick.
    let ticksWhileHidden: Bool
    /// Only the CPU test sets this, to measure Reduce Motion without changing the Mac's setting.
    let reducesMotion: Bool
    /// Points at the right covered by the side panel floating over the room: the "more teams" line stays left of it.
    let covered: CGFloat
    private var reduceMotion: Bool { systemReducesMotion || reducesMotion }
    /// How far the room is scrolled down, in points.
    @State private var scrollTop: CGFloat = 0
    private static let space = "office"

    init(
        panel: SidePanel, focus: FocusState<OfficeFocus?>.Binding, fixedNow: Date? = nil, stage: Stage? = nil,
        zoom: OfficeZoom? = nil, ticksWhileHidden: Bool = false, reducesMotion: Bool = false, covered: CGFloat = 0
    ) {
        self.panel = panel
        self.focus = focus
        self.fixedNow = fixedNow
        self.ticksWhileHidden = ticksWhileHidden
        self.reducesMotion = reducesMotion
        self.covered = covered
        _stage = StateObject(wrappedValue: stage ?? Stage())
        _zoom = StateObject(wrappedValue: zoom ?? OfficeZoom())
    }

    var body: some View {
        GeometryReader { geometry in
            let normal = RoomLayout.pointsPerPixel
            let scale = CGFloat(normal) * (zoom.magnification ?? model.zoom)  // points per art pixel
            let tagScale = CGFloat(normal) * (zoom.settled ?? zoom.magnification ?? model.zoom)
            let animate = fixedNow == nil && !reduceMotion
            let synced = stage.sync(
                model.office, width: Int(geometry.size.width) / normal, now: fixedNow ?? Date(), animate: animate)
            let height = max(synced.layout.contentHeight, Int(geometry.size.height) / normal)
            let size = CGSize(width: CGFloat(synced.layout.width) * scale, height: CGFloat(height) * scale)
            let slots = synced.pods.map(\.slot)
            let sight = synced.layout.outOfSight(
                slots, top: Int(scrollTop / scale), height: Int(geometry.size.height / scale))
            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        OfficePicture(
                            stage: stage, width: synced.layout.width, height: height,
                            generation: stage.generation, scale: scale, zoom: zoom,
                            reduceMotion: reduceMotion, fixedNow: fixedNow, ticksWhileHidden: ticksWhileHidden
                        )
                        .frame(width: size.width, height: size.height)
                        .accessibilityHidden(true)
                        // Pressing a character opens its panel, at a desk or at the meeting table.
                        .onTapGesture { location in
                            let point = (x: Int(location.x / scale), y: Int(location.y / scale))
                            guard let at = stage.seat(at: point, now: fixedNow ?? Date()),
                                let seat = synced.pods.first(where: { $0.slot == at.slot })?.seats[at.index]
                            else { return }
                            panel.open(PanelSelection(seat, at: .seat(slot: at.slot, index: at.index)))
                        }
                        // While a zoom goes on, the name tags stay laid out at the step it started from and are
                        // stretched; they are laid out again once it settles.
                        NameTags(
                            pods: synced.pods, layout: synced.layout, meeting: model.office.meeting, scale: tagScale,
                            fixedNow: fixedNow, panel: panel, focus: focus
                        )
                        .equatable()
                        .scaleEffect(scale / tagScale, anchor: .topLeading)
                        marks(slots, synced.layout, scale: scale)
                    }
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                    .background {
                        GeometryReader { content in
                            Color.clear.preference(
                                key: ScrollTop.self, value: -content.frame(in: .named(Self.space)).minY)
                        }
                    }
                    // Zoomed out, the room keeps to the top left of the view.
                    .frame(
                        minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
                }
                .coordinateSpace(name: Self.space)
                .onPreferenceChange(ScrollTop.self) { scrollTop = $0 }
                .overlay(alignment: .topTrailing) {
                    more(sight.above, below: false, synced.pods, proxy).padding(.trailing, covered)
                }
                .overlay(alignment: .bottomTrailing) {
                    more(sight.below, below: true, synced.pods, proxy).padding(.trailing, covered)
                }
            }
        }
        .onAppear {
            zoom.reduceMotion = reduceMotion
            zoom.start(at: model.zoom) { [weak model] step in model?.zoom = step }
        }
        // A step from the menu or the buttons glides there around the middle of the view.
        .onChange(of: model.zoom) { zoom.go(to: $0) }
        .onChange(of: reduceMotion) { zoom.reduceMotion = $0 }
    }

    /// Where the room can scroll to: each island from its far name tags to its near ones.
    private func marks(_ slots: [Int], _ layout: RoomLayout, scale: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(slots, id: \.self) { slot in
                let origin = layout.origin(of: slot)
                Color.clear
                    .frame(
                        width: CGFloat(RoomLayout.islandWidth) * scale, height: CGFloat(RoomLayout.islandDepth) * scale
                    )
                    .padding(.leading, CGFloat(origin.x) * scale)
                    .padding(.top, CGFloat(origin.y) * scale)
                    .id("island \(slot)")
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    /// "2 more teams below · Waiting 1 ↓" in a right-hand corner, over the lounge when the window has one (else the
    /// floor past the islands): the islands out of sight that way, and how many of them wait, in the waiting colour as
    /// in the summary. Pressing it scrolls the nearest into sight.
    @ViewBuilder private func more(_ slots: [Int], below: Bool, _ pods: [Pod], _ proxy: ScrollViewProxy) -> some View {
        if let nearest = slots.first {
            let waiting = pods.filter { slots.contains($0.slot) && Self.waits($0) }.count
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut) {
                    proxy.scrollTo("island \(nearest)", anchor: below ? .bottom : .top)
                }
            } label: {
                (below ? Text("\(slots.count) more teams below") : Text("\(slots.count) more teams above"))
                    + (waiting > 0
                        ? Text(verbatim: " · ") + Text("Waiting \(waiting)").foregroundColor(Style.waiting)
                        : Text(verbatim: ""))
                    + Text(verbatim: below ? " ↓" : " ↑")
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(Style.tagSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Style.tagPlate))
            .padding(10)
        }
    }

    /// An island whose session waits for an answer, itself or for a teammate.
    private static func waits(_ pod: Pod) -> Bool {
        pod.seats.contains {
            if case .session(let session, _) = $0 { return session.shown.state == .waiting }
            return false
        }
    }
}

/// The name tags over the room. They change with the office, the step they are laid out at, and the minute
/// ("Waiting · 3 min", ticking slowly on their own); a zoom between steps only stretches them, so nothing here is
/// laid out again while it goes on.
private struct NameTags: View, Equatable {
    let pods: [Pod]
    let layout: RoomLayout
    let meeting: OfficeState.Meeting?
    /// Points per art pixel.
    let scale: CGFloat
    let fixedNow: Date?
    let panel: SidePanel
    let focus: FocusState<OfficeFocus?>.Binding

    static func == (a: NameTags, b: NameTags) -> Bool {
        a.pods == b.pods && a.layout == b.layout && a.meeting == b.meeting && a.scale == b.scale
            && a.fixedNow == b.fixedNow && a.panel === b.panel
    }

    var body: some View {
        if let fixedNow {
            layer(now: fixedNow)
        } else {
            TimelineView(.periodic(from: Date(timeIntervalSinceReferenceDate: 0), by: 30)) { context in
                layer(now: context.date)
            }
        }
    }

    private func layer(now: Date) -> some View {
        let pixel = scale
        let desk = CGFloat(RoomLayout.deskWidth) * pixel
        return ZStack(alignment: .topLeading) {
            if let meeting, let room = layout.meetingRoom {
                let door = CGFloat(room.left + MeetingRoom.doorX + MeetingRoom.doorWidth / 2) * pixel
                let top = CGFloat(MeetingRoom.front - MeetingRoom.glassHeight - 1) * pixel
                MeetingTag(name: meeting.session.label, more: meeting.more, scale: scale)
                    .frame(width: desk, height: 20 * pixel, alignment: .bottom)
                    .offset(x: door - desk / 2, y: top - 20 * pixel)
            }
            ForEach(pods) { pod in
                let origin = layout.origin(of: pod.slot)
                ForEach(0..<Island.size, id: \.self) { index in
                    if let seat = pod.seats[index] {
                        let place = OfficeFocus.seat(slot: pod.slot, index: index)
                        SeatTag(
                            seat: seat, across: RoomLayout.isAcross(index), now: now, scale: scale, left: index < 2,
                            besideFree: pod.seats[index ^ 2] == nil
                        )
                        .focused(focus, equals: place)
                        .onTapGesture { panel.open(PanelSelection(seat, at: place)) }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { panel.open(PanelSelection(seat, at: place)) }
                        .offset(
                            x: CGFloat(origin.x + RoomLayout.deskX(index)) * pixel,
                            y: CGFloat(origin.y + (RoomLayout.isAcross(index) ? 0 : RoomLayout.nearDesk)) * pixel)
                    }
                }
            }
        }
    }
}

/// The office's zoom as shown, between the steps the app keeps (`Zoom`). A pinch or ⌘-scroll over the room follows
/// the hand, the spot under the pointer staying under it; a short pause after it the zoom glides to the nearest sharp
/// step (at once with Reduce Motion), and the app keeps that step. A step from the menu or the buttons glides there
/// around the middle of the view. The room's own scroll view is moved once SwiftUI has laid the room out at the new
/// size.
final class OfficeZoom: ObservableObject {
    /// What the room is shown at now; nil until it first appears.
    @Published private(set) var magnification: Double?
    /// The step the name tags are laid out at: the last one a zoom settled on.
    @Published private(set) var settled: Double?
    var reduceMotion = false
    private var settle: ((Double) -> Void)?
    private weak var scrollView: NSScrollView?
    private var monitor: Any?
    /// Where to scroll, from the room's top left, once it is laid out at `magnification`.
    private var pending: CGPoint?
    private var pause: Timer?
    private var glide: Timer?
    private var pointer: CGPoint?
    /// How long the glide to a step takes.
    static let glideTime: TimeInterval = 0.18

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        pause?.invalidate()
        glide?.invalidate()
    }

    /// The room appears at the app's step; `settle` keeps the step a gesture ends on.
    func start(at step: Double, settle: @escaping (Double) -> Void) {
        if magnification == nil { magnification = step }
        if settled == nil { settled = magnification }
        self.settle = settle
    }

    /// The scroll view the room sits in, found from the picture inside it; from then on pinches and ⌘-scrolls over
    /// it zoom.
    func attach(_ view: NSView) {
        guard let found = view.enclosingScrollView, found !== scrollView else { return }
        scrollView = found
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify, .scrollWheel]) { [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
        }
    }

    /// A step from the menu or the buttons.
    func go(to step: Double) {
        guard let shown = magnification, abs(shown - step) > 0.0001 else { return }
        glide(to: step, at: middle()) { [weak self] in self?.settled = step }
    }

    /// Shows the room at `value` with `point` (in the view, from its top left) over the same spot of the room.
    func zoom(to value: Double, at point: CGPoint) {
        guard let shown = magnification else { return }
        let value = Zoom.clamped(value)
        guard value != shown else { return }
        pending = Zoom.origin(pending ?? offset() ?? .zero, keeping: point, from: shown, to: value)
        magnification = value
    }

    /// After the room is laid out at the new size: scrolls to where the zoom keeps its spot, inside the room.
    func laidOut() {
        guard let target = pending, let scrollView, let document = scrollView.documentView else { return }
        pending = nil
        let clip = scrollView.contentView
        let size = document.frame.size
        let x = min(max(0, target.x), max(0, size.width - clip.bounds.width))
        let y = min(max(0, target.y), max(0, size.height - clip.bounds.height))
        clip.scroll(to: CGPoint(x: x, y: clip.isFlipped ? y : size.height - y - clip.bounds.height))
        scrollView.reflectScrolledClipView(clip)
    }

    /// The scroll position from the room's top left.
    func offset() -> CGPoint? {
        guard let scrollView, let document = scrollView.documentView else { return nil }
        let bounds = scrollView.contentView.bounds
        return CGPoint(
            x: bounds.minX,
            y: scrollView.contentView.isFlipped ? bounds.minY : document.frame.height - bounds.maxY)
    }

    private func middle() -> CGPoint {
        guard let bounds = scrollView?.contentView.bounds else { return .zero }
        return CGPoint(x: bounds.width / 2, y: bounds.height / 2)
    }

    /// A pinch, or a scroll with ⌘ held, over the room (not over the side panel floating on it).
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let scrollView, let window = scrollView.window, event.window === window, let shown = magnification,
            let hit = window.contentView?.hitTest(event.locationInWindow), hit.isDescendant(of: scrollView)
        else { return event }
        let factor: Double
        switch event.type {
        case .magnify:
            factor = 1 + event.magnification
        case .scrollWheel:
            guard event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command else {
                return event
            }
            // A mouse wheel moves by lines, a trackpad by points.
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
            factor = exp(delta / 100)
        default:
            return event
        }
        glide?.invalidate()
        let clip = scrollView.contentView
        let at = clip.convert(event.locationInWindow, from: nil)
        let point = CGPoint(
            x: at.x - clip.bounds.minX, y: clip.isFlipped ? at.y - clip.bounds.minY : clip.bounds.maxY - at.y)
        pointer = point
        zoom(to: shown * factor, at: point)
        pause?.invalidate()
        let timer = Timer(timeInterval: 0.15, repeats: false) { [weak self] _ in self?.settleOnAStep() }
        RunLoop.main.add(timer, forMode: .common)
        pause = timer
        return nil
    }

    private func settleOnAStep() {
        guard let shown = magnification else { return }
        let step = Zoom.nearest(shown)
        glide(to: step, at: pointer ?? middle()) { [weak self] in
            self?.settled = step
            self?.settle?(step)
        }
    }

    /// Eases to `step` in a moment, around `point`; with Reduce Motion, at once.
    private func glide(to step: Double, at point: CGPoint, then done: (() -> Void)?) {
        glide?.invalidate()
        guard let start = magnification, !reduceMotion else {
            zoom(to: step, at: point)
            done?()
            return
        }
        let began = Date()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            let t = min(1, Date().timeIntervalSince(began) / Self.glideTime)
            self.zoom(to: t >= 1 ? step : start + (step - start) * (1 - (1 - t) * (1 - t)), at: point)
            guard t >= 1 else { return }
            timer.invalidate()
            self.glide = nil
            done?()
        }
        RunLoop.main.add(timer, forMode: .common)
        glide = timer
    }
}

/// How far the office is scrolled, in points.
private struct ScrollTop: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// One seat's name tag, and the seat as one VoiceOver element: "my-project, Waiting, 3 min" or "Explore 2,
/// teammate of my-project, Working". Across the desks the tag sits above the head; with the back to the room,
/// under the chair. Tab moves seat by seat, island by island from the door.
struct SeatTag: View {
    let seat: Seat
    let across: Bool
    let now: Date
    /// Points per art pixel: 2 at normal size.
    var scale = CGFloat(RoomLayout.pointsPerPixel)
    /// The desk's side of the island (seats 0 and 1 on the left), and whether the seat beside it is free.
    var left = true
    var besideFree = false
    @ObservedObject private var keyboard = KeyboardNavigation.shared

    private var pixel: CGFloat { scale }
    private var deskPoints: CGFloat { CGFloat(RoomLayout.deskWidth) * pixel }
    /// Zoomed out under 75 %, where the 9-point floor makes text big for the room: two lines, and room to grow.
    static func isCompact(_ scale: CGFloat) -> Bool { scale < 1.5 }

    var body: some View {
        Group {
            if across {
                // Bottom-aligned, so a third line grows up and away from the head; three lines of tag (two when
                // compact) is the room the layout keeps above a far head.
                fitted.frame(width: deskPoints, height: 23 * pixel, alignment: .bottom)
                    .frame(height: CGFloat(RoomLayout.farDesk) * pixel, alignment: .top)
            } else {
                fitted.frame(width: deskPoints)
                    .padding(.top, 62 * pixel)
                    .frame(height: CGFloat(RoomLayout.islandDepth - RoomLayout.nearDesk) * pixel, alignment: .top)
            }
        }
        .frame(width: deskPoints)
        .contentShape(Rectangle())
        .help(summary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary)
        .focusable(keyboard.active)
    }

    /// How far a compact tag may grow past its own desk rather than cut a name short (negative: to the left): over
    /// the free seat beside it, else 14 art pixels into the floor between islands, away from the neighbour's tag.
    static func growth(left: Bool, besideFree: Bool, scale: CGFloat) -> CGFloat {
        let reach = (besideFree ? CGFloat(RoomLayout.deskWidth) : -14) * scale
        return left ? reach : -reach
    }

    /// The tag on its desk: centred while it fits, and when compact growing past the desk instead of cutting.
    @ViewBuilder private var fitted: some View {
        let room = deskPoints - 4
        if Self.isCompact(scale) {
            let grow = Self.growth(left: left, besideFree: besideFree, scale: scale)
            ViewThatFits(in: .horizontal) {
                tag(maxWidth: .infinity).fixedSize(horizontal: true, vertical: false)
                tag(maxWidth: room + abs(grow))
                    .frame(width: room + abs(grow), alignment: grow > 0 ? .leading : .trailing)
                    .offset(x: grow / 2)
            }
            .frame(width: room)
        } else {
            tag(maxWidth: room)
        }
    }

    /// The name, then what they do. Compact keeps two lines, the name and the first of the rest, and cuts a long
    /// name in the middle so a teammate's number stays.
    @ViewBuilder private func tag(maxWidth: CGFloat) -> some View {
        let font = Font.tag(scale)
        let compact = Self.isCompact(scale)
        switch seat {
        case .session(let session, let unseated):
            // In a meeting the meeting takes the place of "Working" or "Resting"; a wait still comes first.
            let state = !session.meets || session.state == .waiting
            let mateWaits = session.teammateWaiting && !(compact && state)
            Tag(scale: scale, maxWidth: maxWidth) {
                HStack(spacing: 4) {
                    Text(verbatim: session.label).font(.tag(scale, .semibold)).truncationMode(.middle)
                        .foregroundStyle(Style.tagText)
                    if unseated > 0 {
                        Text("+\(unseated)").font(font).foregroundStyle(Style.tagSecondary).layoutPriority(1)
                    }
                }
                if state {
                    session.state.label(since: session.since, now: now, compact: compact).font(font).foregroundStyle(
                        session.state.tagColor)
                }
                if mateWaits {
                    Text("Teammate waiting").font(font).foregroundStyle(Style.waiting)
                }
                if session.meets, !(compact && (state || mateWaits)) {
                    Text("In a meeting · \(session.direct.count) teammates").font(font).foregroundStyle(Style.tagText)
                }
            }
        case .teammate(let mate, let session):
            // At the meeting its empty seat says so, like the session's own tag; a wait still comes first.
            let meets = session.meets(with: mate)
            let state = !meets || mate.state == .waiting
            Tag(scale: scale, maxWidth: maxWidth) {
                mate.displayName.font(.tag(scale, .medium)).truncationMode(compact ? .middle : .tail)
                if state {
                    mate.state.label(since: mate.since, now: now, compact: compact).font(font).foregroundStyle(
                        mate.state.tagColor)
                }
                if meets, !(compact && state) { Text("In a meeting").font(font).foregroundStyle(Style.tagText) }
            }
        }
    }

    /// The same words as the tag, in reading order.
    private var summary: Text {
        let comma = Text(verbatim: ", ")
        switch seat {
        case .session(let session, let unseated):
            var text = Text(verbatim: session.label)
            if !session.meets || session.state == .waiting { text = text + comma + session.state.word }
            let minutes = Int(now.timeIntervalSince(session.since) / 60)
            if session.state == .waiting, minutes >= 1 { text = text + comma + Text("\(minutes) min") }
            if session.meets {
                // "my-project, In a meeting, 3 teammates, Explore waiting": who waits, by name.
                text = text + comma + Text("In a meeting") + comma + Text("\(session.direct.count) teammates")
                for mate in session.teammates where mate.state == .waiting {
                    text = text + comma + Text("\(mate.label) waiting")
                }
            } else if session.teammateWaiting {
                text = text + comma + Text("Teammate waiting")
            }
            if unseated > 0 { text = text + comma + Text("\(unseated) more teammates") }
            return text
        case .teammate(let mate, let session):
            let meets = session.meets(with: mate)
            var text = mate.displayName + comma + Text("teammate of \(session.label)")
            if !meets || mate.state == .waiting { text = text + comma + mate.state.word }
            let minutes = Int(now.timeIntervalSince(mate.since) / 60)
            if mate.state == .waiting, minutes >= 1 { text = text + comma + Text("\(minutes) min") }
            if meets { text = text + comma + Text("In a meeting") }
            return text
        }
    }
}

/// Seats take keyboard focus only once Tab is pressed, and give it up on a click, so their focus ring shows for
/// keyboard use only. Always focusable, the first seat took focus (and its ring) as the window opened, and macOS 13
/// has no way to hide SwiftUI's ring. VoiceOver reads the seats either way.
final class KeyboardNavigation: ObservableObject {
    static let shared = KeyboardNavigation()
    @Published var active = false
    /// What Space (outside text fields) and Esc do in the office window: open the focused seat's panel, press the
    /// focused button in it, close it. Set by the office view, since macOS 13 has no onKeyPress. True when used.
    var space: (() -> Bool)?
    var escape: (() -> Bool)?
    /// ⌘= zooms in as ⌘+ does: the menu shows ⌘+, which takes Shift on most keyboards.
    var zoomIn: (() -> Void)?
    private var monitor: Any?

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) {
            [weak self] event in
            guard let self else { return event }
            guard event.type == .keyDown else {
                if self.active { self.active = false }
                return event
            }
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if flags == .command, event.charactersIgnoringModifiers == "=", let zoomIn = self.zoomIn {
                zoomIn()
                return nil
            }
            if flags.isEmpty {
                let typing = event.window?.firstResponder is NSText
                if event.keyCode == 49, !typing, self.space?() == true { return nil }  // 49: Space
                if event.keyCode == 53, self.escape?() == true { return nil }  // 53: Esc
            }
            guard event.keyCode == 48, !self.active else { return event }  // 48: Tab
            self.active = true
            // shortcut: the pods turn focusable only after SwiftUI redraws, so this Tab comes back a moment later;
            // hook into SwiftUI's own focus if a later macOS minimum gives a way.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { NSApp.postEvent(event, atStart: true) }
            return nil
        }
    }
}

/// Over the meeting room's glass door: whose meeting it is, and "+n" for teammates with no seat left at the
/// table. VoiceOver hears it from the session's own seat.
private struct MeetingTag: View {
    let name: String
    let more: Int
    let scale: CGFloat

    var body: some View {
        Tag(scale: scale) {
            HStack(spacing: 4) {
                Text(verbatim: name).font(.tag(scale, .semibold)).truncationMode(.middle)
                    .foregroundStyle(Style.tagText)
                if more > 0 {
                    Text("+\(more)").font(.tag(scale)).foregroundStyle(Style.tagSecondary).layoutPriority(1)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// A small plate behind tag text, so it reads on the wood floor by day and by night (4.5:1 or more).
private struct Tag<Content: View>: View {
    let scale: CGFloat
    var maxWidth: CGFloat?
    @ViewBuilder let content: () -> Content

    var body: some View {
        // 5, 2 and 5 points at normal size, less when zoomed out and more when zoomed in.
        let step = (scale + 1) / 3
        VStack(spacing: 0) { content() }
            .lineLimit(1)
            .padding(.horizontal, 5 * step)
            .padding(.vertical, SeatTag.isCompact(scale) ? 0 : 2 * step)
            .background(RoundedRectangle(cornerRadius: 5 * step).fill(Style.tagPlate))
            .frame(maxWidth: maxWidth ?? CGFloat(RoomLayout.deskWidth) * scale - 4)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension Font {
    /// Name tag text: the system's small text at normal size, growing and shrinking with the zoom, never under 9 pt.
    static func tag(_ scale: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        scale == CGFloat(RoomLayout.pointsPerPixel)
            ? .subheadline.weight(weight) : .system(size: max(9, 5.5 * scale), weight: weight)
    }
}

/// The office picture at a whole-number scale, sharp: the GPU scales it with nearest-neighbour sampling.
/// It keeps its own clock, so SwiftUI only touches it when the office changes. Between changes it redraws
/// itself: 30 times a second while someone walks (5 art pixels a frame; only the walkers' boxes, laid over the
/// room as small layers), 2.5 times a second otherwise, every 30 s with Reduce Motion, and not at all while its
/// window is hidden or minimized (the app stays open all day).
struct OfficePicture: NSViewRepresentable {
    /// 12 looked choppy and 30 reads as smooth for pixel art at half the wakeups of 60; go back to 60 if it doesn't.
    static let walkingFrameRate = 30.0

    let stage: Stage
    /// The room's size in art pixels: a change draws the picture again at once, with or without a clock.
    let width: Int
    let height: Int
    /// The stage's count of changes: a new one draws the picture again at once.
    let generation: Int
    /// Points per art pixel, as zoomed.
    let scale: CGFloat
    let zoom: OfficeZoom
    let reduceMotion: Bool
    let fixedNow: Date?
    let ticksWhileHidden: Bool

    func makeNSView(context: Context) -> PictureView { PictureView() }

    func updateNSView(_ view: PictureView, context: Context) {
        let before = view.settings
        view.settings = self
        // A zoom alone only stretches the same picture: no need to draw it again.
        if let before, before.stage === stage, before.width == width, before.height == height,
            before.generation == generation, before.reduceMotion == reduceMotion, before.fixedNow == fixedNow
        {
            view.placeWalkers()
        } else {
            view.refresh()
        }
        zoom.attach(view)
        // The room's new size is in place once this update is done.
        DispatchQueue.main.async { [zoom] in zoom.laidOut() }
    }

    final class PictureView: NSView {
        var settings: OfficePicture?
        private var picture: Stage.Picture = (nil, [])
        private var shownRoom: CGImage?
        private var walkerLayers: [CALayer] = []
        private var timer: Timer?
        private var observer: NSObjectProtocol?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.magnificationFilter = .nearest
            layer?.minificationFilter = .nearest
            layer?.contentsGravity = .resize
        }

        required init?(coder: NSCoder) { nil }

        deinit {
            timer?.invalidate()
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        override var wantsUpdateLayer: Bool { true }
        override var isFlipped: Bool { true }

        override func updateLayer() {
            layer?.contents = picture.room
            shownRoom = picture.room
        }

        /// Walker boxes are our own sublayers, moved without asking AppKit to display the window again.
        func placeWalkers() {
            guard let layer else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            while walkerLayers.count < picture.walkers.count {
                let walker = CALayer()
                walker.magnificationFilter = .nearest
                walker.minificationFilter = .nearest
                walker.contentsGravity = .resize
                layer.addSublayer(walker)
                walkerLayers.append(walker)
            }
            while walkerLayers.count > picture.walkers.count { walkerLayers.removeLast().removeFromSuperlayer() }
            for (walker, piece) in zip(walkerLayers, picture.walkers) {
                walker.contents = piece.image
                walker.frame = convertToLayer(points(piece.box))
            }
            CATransaction.commit()
        }

        private func points(_ box: CGRect) -> CGRect {
            let scale = settings?.scale ?? CGFloat(RoomLayout.pointsPerPixel)
            return CGRect(
                x: box.minX * scale, y: box.minY * scale, width: box.width * scale, height: box.height * scale)
        }

        /// Used when the view is drawn into a bitmap (screenshots) instead of shown through its layer.
        override func draw(_ dirtyRect: NSRect) {
            guard let room = picture.room, let context = NSGraphicsContext.current?.cgContext else { return }
            context.interpolationQuality = .none
            context.saveGState()
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
            context.draw(room, in: bounds)
            for piece in picture.walkers {
                guard let image = piece.image else { continue }
                let box = points(piece.box)
                context.draw(image, in: box.offsetBy(dx: 0, dy: bounds.height - box.maxY - box.minY))
            }
            context.restoreGState()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            if let window {
                observer = NotificationCenter.default.addObserver(
                    forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
                ) { [weak self] _ in self?.refresh() }
            }
            refresh()
        }

        /// Draws now, then books the next frame if the window can be seen.
        func refresh() {
            timer?.invalidate()
            timer = nil
            guard let settings else { return }
            let now = settings.fixedNow ?? Date()
            let animated = settings.fixedNow == nil && !settings.reduceMotion
            let frame = animated ? Int(now.timeIntervalSinceReferenceDate / 0.4) : 0
            picture = settings.stage.picture(
                at: now, frame: frame, height: settings.height, reduceMotion: settings.reduceMotion)
            // The room changes a few times a second at most; a walk only moves the boxes.
            if shownRoom !== picture.room { needsDisplay = true }
            placeWalkers()

            let visible = window?.occlusionState.contains(.visible) ?? false
            guard settings.fixedNow == nil, window != nil, visible || settings.ticksWhileHidden else { return }
            var interval =
                now < settings.stage.busyUntil ? 1 / OfficePicture.walkingFrameRate : (settings.reduceMotion ? 30 : 0.4)
            if let next = settings.stage.nextChange(after: now) {
                interval = min(interval, max(0.05, next.timeIntervalSince(now)))
            }
            let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in self?.refresh() }
            timer.tolerance = interval / 10
            // Common modes: keep moving while the room is scrolled.
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }
}
