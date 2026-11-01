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
    }

    private struct Seated {
        let look: Look
        let pod: Int
        let desk: Int
        let arrived: Date?
    }

    /// The picture ticks fast until this moment (someone is walking), and slowly after.
    private(set) var busyUntil = Date.distantPast

    private var plan = SeatPlan()
    private var office: OfficeState?
    private var layout = RoomLayout(width: 0, podCount: 0)
    private var pods: [Pod] = []
    private var present: [String: Seated] = [:]
    private var walks: [String: Walk] = [:]
    /// Goes up whenever the pods or the room change, so a cached picture is never reused across a change.
    private var generation = 0

    /// Pixels a second, the same on every route: about 4.7 s from the door to the far desk of the default window
    /// (702 px), about 1.1 s to the nearest.
    static let speed = 150.0
    /// Pixels walked per frame of the six-frame walk, so the feet keep pace with the floor (12.5 frames a second).
    private static let stride = 12.0

    /// Called while drawing. Publishes nothing synchronously, so it is safe inside a view's body.
    func sync(_ office: OfficeState, width: Int, now: Date, animate: Bool) -> (pods: [Pod], layout: RoomLayout) {
        guard office != self.office || width != layout.width else { return (pods, layout) }
        let before = layout
        generation += 1
        self.office = office
        pods = plan.pods(for: office)
        layout = RoomLayout(width: width, podCount: pods.count)

        var seated: [String: Seated] = [:]
        for (index, pod) in pods.enumerated() {
            if pod.session != nil {
                seated[OfficeScene.mainID(pod)] = Seated(
                    look: OfficeScene.mainLook(pod), pod: index, desk: 0, arrived: pod.session?.arrived)
            }
            for (slot, mate) in pod.mates.enumerated() {
                guard let mate else { continue }
                seated[OfficeScene.mateID(mate)] = Seated(
                    look: OfficeScene.mateLook(mate, desk: slot + 1), pod: index, desk: slot + 1,
                    arrived: mate.arrived)
            }
        }
        if animate {
            // A walk in starts when the person arrived, not when the window first draws it: a window drawn late
            // still shows the walk, or the person seated once it would be over.
            for (id, person) in seated where present[id] == nil {
                guard let arrived = person.arrived else { continue }
                walks[id] = walk(person.look, layout.route(pod: person.pod, desk: person.desk), arrived, false)
            }
            for (id, person) in present where seated[id] == nil {
                walks[id] = walk(person.look, before.route(pod: person.pod, desk: person.desk), now, true)
            }
        }
        walks = walks.filter { now.timeIntervalSince($0.value.start) < $0.value.duration }
        present = seated

        busyUntil = walks.values.map { $0.start + $0.duration }.max() ?? .distantPast
        return (pods, layout)
    }

    private func walk(_ look: Look, _ route: [(x: Int, y: Int)], _ start: Date, _ leaving: Bool) -> Walk {
        Walk(look: look, route: route, start: start, duration: Self.length(route) / Self.speed, leaving: leaving)
    }

    static func length(_ route: [(x: Int, y: Int)]) -> Double {
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
            let step = Int((max(0, elapsed) / walk.duration * total / Self.stride).rounded(.down))
            walkers.append(Walker(look: walk.look, x: point.x, y: point.y, facing: facing, step: step))
        }
        return (walkers, away, doorOpen)
    }

    /// The room without walkers, and a piece of the finished picture around each walker.
    typealias Picture = (room: CGImage?, walkers: [(box: CGRect, image: CGImage?)])

    private var last: (key: String, picture: Picture)?
    private var room: (key: String, image: CGImage?)?

    /// The office at `now`. The room is drawn again only when it changes (the 2.5-a-second frame, the clock's
    /// minute, the light, the door, someone sitting down); each frame of a walk draws only the walkers' boxes.
    /// A box is the whole office drawn inside it, so a walker stays under the night light and behind lit lamps
    /// and bubbles exactly as in one picture. A tick can draw the view twice; the second time reuses the first.
    func picture(at now: Date, frame: Int, height: Int, reduceMotion: Bool) -> Picture {
        let key = "\(now.timeIntervalSinceReferenceDate) \(frame) \(height) \(layout.width) \(generation)"
        if let last, last.key == key { return last.picture }
        let moment = moment(at: now)
        // Rounded so the room and the boxes, drawn at different moments, share one light.
        let darkness = (Daylight.darkness(at: now) * 100).rounded() / 100
        var scene = OfficeScene(
            layout: layout, height: height, pods: pods, darkness: darkness, frame: frame, now: now,
            away: moment.away, doorOpen: moment.doorOpen && !reduceMotion)
        let minute = Int(now.timeIntervalSinceReferenceDate / 60)
        let roomKey =
            "\(frame) \(minute) \(darkness) \(scene.doorOpen) \(moment.away.sorted()) \(height) \(layout.width) "
            + "\(generation)"
        if room?.key != roomKey { room = (roomKey, OfficeRenderer().render(scene)) }
        scene.walkers = moment.walkers
        let bounds = CGRect(x: 0, y: 0, width: layout.width, height: height)
        let walkers = moment.walkers.map { walker -> (box: CGRect, image: CGImage?) in
            let box = walker.box.intersection(bounds)
            return (box, box.isEmpty ? nil : OfficeRenderer().render(scene, crop: box))
        }
        let picture = (room?.image, walkers)
        last = (key, picture)
        return picture
    }
}

/// The office as one picture at 2 points per art pixel, with system-font name tags on the floor in front of
/// each desk. Pods fill rows from the door; more pods add rows and the room scrolls.
struct OfficeRoom: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var systemReducesMotion
    @StateObject private var stage: Stage
    /// Screenshots pin the clock; the frame then stays at 0.
    let fixedNow: Date?
    /// Only the CPU test sets this: its window may open behind a full-screen app, where nothing would tick.
    let ticksWhileHidden: Bool
    /// Only the CPU test sets this, to measure Reduce Motion without changing the Mac's setting.
    let reducesMotion: Bool
    private var reduceMotion: Bool { systemReducesMotion || reducesMotion }

    init(fixedNow: Date? = nil, stage: Stage? = nil, ticksWhileHidden: Bool = false, reducesMotion: Bool = false) {
        self.fixedNow = fixedNow
        self.ticksWhileHidden = ticksWhileHidden
        self.reducesMotion = reducesMotion
        _stage = StateObject(wrappedValue: stage ?? Stage())
    }

    var body: some View {
        GeometryReader { geometry in
            let scale = RoomLayout.pointsPerPixel
            let animate = fixedNow == nil && !reduceMotion
            let synced = stage.sync(
                model.office, width: Int(geometry.size.width) / scale, now: fixedNow ?? Date(), animate: animate)
            let height = max(synced.layout.contentHeight, Int(geometry.size.height) / scale)
            ScrollView(.vertical) {
                ZStack(alignment: .topLeading) {
                    OfficePicture(
                        stage: stage, height: height, reduceMotion: reduceMotion, fixedNow: fixedNow,
                        ticksWhileHidden: ticksWhileHidden
                    )
                    .frame(width: CGFloat(synced.layout.width * scale), height: CGFloat(height * scale))
                    .accessibilityHidden(true)
                    tags(synced.pods, synced.layout)
                }
                .frame(
                    width: CGFloat(synced.layout.width * scale), height: CGFloat(height * scale),
                    alignment: .topLeading)
            }
        }
    }

    /// Name tags only change by the minute ("Waiting · 3 min"), so they tick slowly on their own.
    @ViewBuilder private func tags(_ pods: [Pod], _ layout: RoomLayout) -> some View {
        if let fixedNow {
            tagLayer(pods, layout, now: fixedNow)
        } else {
            TimelineView(.periodic(from: Date(timeIntervalSinceReferenceDate: 0), by: 30)) { context in
                tagLayer(pods, layout, now: context.date)
            }
        }
    }

    private func tagLayer(_ pods: [Pod], _ layout: RoomLayout, now: Date) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(pods.enumerated()), id: \.element.id) { index, pod in
                let origin = layout.origin(of: index)
                PodTags(pod: pod, now: now)
                    .offset(
                        x: CGFloat(origin.x * RoomLayout.pointsPerPixel),
                        y: CGFloat(origin.y * RoomLayout.pointsPerPixel))
            }
        }
    }
}

/// Name tags for one pod, and the pod as one VoiceOver element: "my-project, Waiting, 3 min, teammate Explore
/// Working". Tab moves pod by pod in seat order.
struct PodTags: View {
    let pod: Pod
    let now: Date
    @ObservedObject private var keyboard = KeyboardNavigation.shared

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
        .focusable(keyboard.active)
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

/// Pods take keyboard focus only once Tab is pressed, and give it up on a click, so their focus ring shows for
/// keyboard use only. Always focusable, the first pod took focus (and its ring) as the window opened, and macOS 13
/// has no way to hide SwiftUI's ring. VoiceOver reads the pods either way.
final class KeyboardNavigation: ObservableObject {
    static let shared = KeyboardNavigation()
    @Published var active = false
    private var monitor: Any?

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) {
            [weak self] event in
            guard let self else { return event }
            guard event.type == .keyDown else {
                if self.active { self.active = false }
                return event
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

/// The office picture at a whole-number scale, sharp: the GPU scales it with nearest-neighbour sampling.
/// It keeps its own clock, so SwiftUI only touches it when the office changes. Between changes it redraws
/// itself: 30 times a second while someone walks (5 art pixels a frame; only the walkers' boxes, laid over the
/// room as small layers), 2.5 times a second otherwise, every 30 s with Reduce Motion, and not at all while its
/// window is hidden or minimized (the app stays open all day).
struct OfficePicture: NSViewRepresentable {
    /// 12 looked choppy and 30 reads as smooth for pixel art at half the wakeups of 60; go back to 60 if it doesn't.
    static let walkingFrameRate = 30.0

    let stage: Stage
    let height: Int
    let reduceMotion: Bool
    let fixedNow: Date?
    let ticksWhileHidden: Bool

    func makeNSView(context: Context) -> PictureView { PictureView() }

    func updateNSView(_ view: PictureView, context: Context) {
        view.settings = self
        view.refresh()
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
        private func placeWalkers() {
            guard let layer else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            while walkerLayers.count < picture.walkers.count {
                let walker = CALayer()
                walker.magnificationFilter = .nearest
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
            let scale = CGFloat(RoomLayout.pointsPerPixel)
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
            let interval =
                now < settings.stage.busyUntil ? 1 / OfficePicture.walkingFrameRate : (settings.reduceMotion ? 30 : 0.4)
            let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in self?.refresh() }
            timer.tolerance = interval / 10
            // Common modes: keep moving while the room is scrolled.
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }
}
