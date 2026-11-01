import AppKit
import SwiftUI

/// Who walks where: each time the office changes it seats the pods and times walks in through the door and out.
final class Stage: ObservableObject {
    private struct Walk {
        let look: Look
        /// Door to desk; walked backwards when leaving.
        let route: [(x: Int, y: Int)]
        let start: Date
        let duration: TimeInterval
        let leaving: Bool
        let mark: Mark?
    }

    private struct Seated {
        let look: Look
        let pod: Int
        let desk: Int
        let mark: Mark
    }

    /// The office ticks fast until this moment (someone is walking), and slowly after.
    @Published private(set) var busyUntil = Date.distantPast

    private var plan = SeatPlan()
    private var office: OfficeState?
    private var layout = RoomLayout(width: 0, podCount: 0)
    private var pods: [Pod] = []
    private var present: [String: Seated] = [:]
    private var walks: [String: Walk] = [:]

    /// Pixels a second; long routes walk faster so nobody takes more than `longest` seconds.
    private static let speed = 90.0
    private static let longest = 2.5

    /// Called while drawing. Publishes nothing synchronously, so it is safe inside a view's body.
    func sync(_ office: OfficeState, width: Int, now: Date, animate: Bool) -> (pods: [Pod], layout: RoomLayout) {
        guard office != self.office || width != layout.width else { return (pods, layout) }
        let first = self.office == nil
        let before = layout
        self.office = office
        pods = plan.pods(for: office)
        layout = RoomLayout(width: width, podCount: pods.count)

        var seated: [String: Seated] = [:]
        for (index, pod) in pods.enumerated() {
            if let session = pod.session {
                seated[OfficeScene.mainID(pod)] = Seated(
                    look: OfficeScene.mainLook(pod), pod: index, desk: 0, mark: Mark(session.state))
            }
            for (slot, mate) in pod.mates.enumerated() {
                guard let mate else { continue }
                seated[OfficeScene.mateID(mate)] = Seated(
                    look: OfficeScene.mateLook(mate, desk: slot + 1), pod: index, desk: slot + 1, mark: Mark(mate.state)
                )
            }
        }
        walks = walks.filter { now.timeIntervalSince($0.value.start) < $0.value.duration }
        if animate, !first {
            for (id, person) in seated where present[id] == nil {
                walks[id] = walk(person.look, layout.route(pod: person.pod, desk: person.desk), now, false, person.mark)
            }
            for (id, person) in present where seated[id] == nil {
                walks[id] = walk(person.look, before.route(pod: person.pod, desk: person.desk), now, true, nil)
            }
        }
        present = seated

        let until = walks.values.map { $0.start + $0.duration }.max() ?? .distantPast
        if until > busyUntil { DispatchQueue.main.async { self.busyUntil = until } }
        return (pods, layout)
    }

    private func walk(_ look: Look, _ route: [(x: Int, y: Int)], _ now: Date, _ leaving: Bool, _ mark: Mark?) -> Walk {
        let length = Self.length(route)
        return Walk(
            look: look, route: route, start: now, duration: min(Self.longest, max(1, length / Self.speed)),
            leaving: leaving, mark: mark)
    }

    private static func length(_ route: [(x: Int, y: Int)]) -> Double {
        zip(route, route.dropFirst()).reduce(0) { $0 + hypot(Double($1.1.x - $1.0.x), Double($1.1.y - $1.0.y)) }
    }

    /// Where everyone on the move is at `now`. People walking in are "away": their desk still looks empty.
    func moment(at now: Date) -> (walkers: [Walker], away: Set<String>, doorOpen: Bool) {
        var walkers: [Walker] = []
        var away: Set<String> = []
        var doorOpen = false
        for (id, walk) in walks {
            let elapsed = now.timeIntervalSince(walk.start)
            guard elapsed < walk.duration else { continue }
            if !walk.leaving { away.insert(id) }
            let route = walk.leaving ? Array(walk.route.reversed()) : walk.route
            let total = Self.length(route)
            var left = max(0, elapsed) / walk.duration * total
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
            let door = walk.route[0]
            if abs(point.x - door.x) + abs(point.y - door.y) < 30 { doorOpen = true }
            let step = Int((max(0, elapsed) / walk.duration * total / 5).rounded(.down))
            walkers.append(Walker(look: walk.look, x: point.x, y: point.y, facing: facing, step: step, mark: walk.mark))
        }
        return (walkers, away, doorOpen)
    }
}

/// The office as one picture at 2 points per art pixel, with system-font name tags on the floor in front of
/// each desk. Pods fill rows from the door; more pods add rows and the room scrolls.
struct OfficeRoom: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var stage: Stage
    @State private var visible = true
    /// Screenshots pin the clock; the frame then stays at 0.
    let fixedNow: Date?

    init(fixedNow: Date? = nil, stage: Stage? = nil) {
        self.fixedNow = fixedNow
        _stage = StateObject(wrappedValue: stage ?? Stage())
    }

    var body: some View {
        GeometryReader { geometry in
            if let fixedNow {
                room(now: fixedNow, frame: 0, size: geometry.size)
            } else if !visible {
                // Hidden or minimized: one still picture, no ticking (the app stays open all day).
                room(now: Date(), frame: 0, size: geometry.size)
            } else {
                TimelineView(OfficeSchedule(busyUntil: stage.busyUntil, slow: reduceMotion ? 30 : 0.4)) { context in
                    room(
                        now: context.date,
                        frame: reduceMotion ? 0 : Int(context.date.timeIntervalSinceReferenceDate / 0.4),
                        size: geometry.size)
                }
            }
        }
        .background(WindowVisibility(visible: $visible))
    }

    private func room(now: Date, frame: Int, size: CGSize) -> some View {
        let scale = RoomLayout.pointsPerPixel
        let animate = fixedNow == nil && !reduceMotion
        let synced = stage.sync(model.office, width: Int(size.width) / scale, now: fixedNow ?? Date(), animate: animate)
        let layout = synced.layout
        let moment = stage.moment(at: now)
        let scene = OfficeScene(
            layout: layout, height: max(layout.contentHeight, Int(size.height) / scale), pods: synced.pods,
            darkness: Daylight.darkness(at: now), frame: frame, now: now, walkers: moment.walkers, away: moment.away,
            doorOpen: moment.doorOpen && !reduceMotion)
        return ScrollView(.vertical) {
            ZStack(alignment: .topLeading) {
                if let image = OfficeRenderer().render(scene) {
                    Image(decorative: image, scale: 1 / CGFloat(scale)).interpolation(.none).accessibilityHidden(true)
                }
                ForEach(Array(synced.pods.enumerated()), id: \.element.id) { index, pod in
                    let origin = layout.origin(of: index)
                    PodTags(pod: pod, now: now)
                        .offset(x: CGFloat(origin.x * scale), y: CGFloat(origin.y * scale))
                }
            }
            .frame(
                width: CGFloat(layout.width * scale), height: CGFloat(scene.height * scale), alignment: .topLeading)
        }
    }
}

/// Ticks about 12 times a second while someone walks, then every `slow` seconds.
struct OfficeSchedule: TimelineSchedule {
    let busyUntil: Date
    let slow: TimeInterval

    func entries(from start: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var next = start
        return AnyIterator {
            let current = next
            next = current + (current < busyUntil ? 1.0 / 12 : slow)
            return current
        }
    }
}

/// Name tags for one pod, and the pod as one VoiceOver element: "my-project, Waiting, 3 min, teammate Explore
/// Working". Tab moves pod by pod in seat order.
struct PodTags: View {
    let pod: Pod
    let now: Date

    static let deskPoints = CGFloat(RoomLayout.deskWidth * RoomLayout.pointsPerPixel)

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            mainTag.frame(width: Self.deskPoints)
            ForEach(0..<Pod.sideDesks, id: \.self) { index in
                Group {
                    if let mate = pod.mates[index] {
                        Tag {
                            mate.displayName.font(.subheadline.weight(.medium))
                            mate.state.label(since: mate.since, now: now).font(.subheadline).foregroundStyle(
                                mate.state.tagColor)
                        }
                    }
                }
                .frame(width: Self.deskPoints)
            }
        }
        .padding(.top, CGFloat(64 * RoomLayout.pointsPerPixel))
        .frame(
            width: CGFloat(RoomLayout.podWidth * RoomLayout.pointsPerPixel),
            height: CGFloat(RoomLayout.podDepth * RoomLayout.pointsPerPixel), alignment: .topLeading
        )
        .contentShape(Rectangle())
        .help(summary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary)
        .focusable()
    }

    @ViewBuilder private var mainTag: some View {
        Tag {
            HStack(spacing: 4) {
                Text(verbatim: pod.name).font(.subheadline.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(pod.isOff ? Style.tagSecondary : Style.tagText)
                if pod.extra > 0 {
                    Text("+\(pod.extra)").font(.subheadline).foregroundStyle(Style.tagSecondary).layoutPriority(1)
                }
            }
            if let session = pod.session {
                session.state.label(since: session.since, now: now).font(.subheadline).foregroundStyle(
                    session.state.tagColor)
                if pod.teammateWaiting {
                    Text("Teammate waiting").font(.subheadline).foregroundStyle(Style.waiting)
                }
            } else {
                Text("Off duty").font(.subheadline).foregroundStyle(Style.tagSecondary)
            }
        }
    }

    /// The same words as the tags, in reading order.
    private var summary: Text {
        var text = Text(verbatim: pod.name)
        guard let session = pod.session else { return text + Text(verbatim: ", ") + Text("Off duty") }
        text = text + Text(verbatim: ", ") + session.state.word
        let minutes = Int(now.timeIntervalSince(session.since) / 60)
        if session.state == .waiting, minutes >= 1 { text = text + Text(verbatim: ", ") + Text("\(minutes) min") }
        if pod.teammateWaiting { text = text + Text(verbatim: ", ") + Text("Teammate waiting") }
        for mate in pod.mates.compactMap({ $0 }) {
            text =
                text + Text(verbatim: ", ") + Text("teammate") + Text(verbatim: " ") + mate.displayName
                + Text(verbatim: " ") + mate.state.word
        }
        if pod.extra > 0 { text = text + Text(verbatim: ", ") + Text("\(pod.extra) more teammates") }
        return text
    }
}

/// A small plate behind tag text, so it reads on the wood floor by day and by night (4.5:1 or more).
private struct Tag<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) { content() }
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(Style.tagPlate))
            .frame(maxWidth: PodTags.deskPoints - 4)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Reports whether the window is on screen; hidden or minimized windows stop the animation.
struct WindowVisibility: NSViewRepresentable {
    @Binding var visible: Bool

    func makeNSView(context: Context) -> NSView {
        Watcher { visible in
            if self.visible != visible { self.visible = visible }
        }
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Watcher: NSView {
        private let onChange: (Bool) -> Void
        private var observer: NSObjectProtocol?

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self, weak window] _ in
                guard let window else { return }
                self?.onChange(window.occlusionState.contains(.visible))
            }
        }
    }
}
