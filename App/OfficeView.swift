import SwiftUI

/// Where keyboard focus can be in the office window: the seats (once Tab is pressed), then the side panel.
enum OfficeFocus: Hashable {
    case seat(slot: Int, index: Int)
    case close
    case edit
    case nickname
    case mate(String)
}

/// Whose details the side panel shows.
struct PanelSelection: Equatable {
    enum Kind: Equatable {
        case session(String)
        case teammate(String)
    }

    var kind: Kind
    /// The name as it was when chosen: shown faded once they have gone home.
    var name: String
    /// The seat it was opened from: keyboard focus goes back there when the panel closes.
    var seat: OfficeFocus?

    init(_ seat: Seat, at place: OfficeFocus?) {
        switch seat {
        case .session(let session, _):
            kind = .session(session.id)
            name = session.label
        case .teammate(let mate, _):
            kind = .teammate(mate.id)
            name = mate.label
        }
        self.seat = place
    }

    /// A teammate chosen from its session's panel, with the desk it sits at.
    init(teammate mate: Teammate, in office: OfficeState) {
        kind = .teammate(mate.id)
        name = mate.label
        seat = nil
        for pod in office.pods {
            for (index, occupant) in pod.seats.enumerated() {
                if case .teammate(let seated, _)? = occupant, seated.id == mate.id {
                    seat = .seat(slot: pod.slot, index: index)
                }
            }
        }
    }
}

/// The side panel's state, apart from the view so tests can drive it: whose details it shows, the nickname being
/// typed, and where keyboard focus is and goes back to.
final class SidePanel: ObservableObject {
    @Published var selection: PanelSelection?
    /// The nickname as typed so far, while it is being typed.
    @Published var draft: String?
    /// Focus for the view to move to (FocusState lives in the view), and where it is now.
    @Published var focusRequest: OfficeFocus?
    var focus: OfficeFocus?

    init(_ selection: PanelSelection? = nil, draft: String? = nil) {
        self.selection = selection
        self.draft = draft
    }

    /// Opens the panel on someone. From the keyboard, focus moves into it.
    func open(_ chosen: PanelSelection) {
        selection = chosen
        draft = nil
        if KeyboardNavigation.shared.active { focusRequest = .edit }
    }

    /// Closes the panel; focus goes back to the seat it came from.
    func close() {
        focusRequest = selection?.seat
        selection = nil
        draft = nil
    }

    /// Esc: stops typing a nickname, else closes the panel. False when it is not open.
    func escape() -> Bool {
        guard selection != nil else { return false }
        if draft != nil {
            stopEditing()
        } else {
            close()
        }
        return true
    }

    /// Starts typing a nickname, from the one given now (empty for none).
    func edit(in office: OfficeState) {
        guard let selection else { return }
        draft = Self.nickname(of: selection.kind, in: office) ?? ""
        focusRequest = .nickname
    }

    func stopEditing() {
        draft = nil
        focusRequest = .edit
    }

    /// What the panel shows for whoever it is open on.
    enum Facts {
        /// A session; `named` when its folder has a nickname (the automatic name shows small under it).
        case session(Session, named: Bool, news: Date?)
        case teammate(Teammate, of: Session, news: Date?)
        /// They have gone: the name they had, faded.
        case wentHome(String)
    }

    static func facts(_ selection: PanelSelection, in office: OfficeState) -> Facts {
        switch selection.kind {
        case .session(let id):
            guard let session = office.session(id) else { return .wentHome(selection.name) }
            return .session(
                session, named: nickname(of: selection.kind, in: office) != nil, news: office.lastNews(session: id))
        case .teammate(let id):
            guard let (mate, session) = office.teammate(id) else { return .wentHome(selection.name) }
            return .teammate(mate, of: session, news: office.lastNews(teammate: id))
        }
    }

    /// What VoiceOver says as the panel opens: the name and the state ("my-project, Waiting, 3 min, In a
    /// meeting"). Nothing for someone who went home: the panel says so.
    static func spoken(_ kind: PanelSelection.Kind, in office: OfficeState, now: Date) -> String? {
        func state(_ state: WorkState, since: Date, meets: Bool) -> [String] {
            var words: [String] = []
            if !meets || state == .waiting {
                words.append(state.spoken)
                let minutes = Int(now.timeIntervalSince(since) / 60)
                if minutes >= 1 { words.append(String(localized: "\(minutes) min")) }
            }
            if meets { words.append(String(localized: "In a meeting")) }
            return words
        }
        let now = doing(kind, in: office).map { [$0.spoken] } ?? []
        switch kind {
        case .session(let id):
            guard let session = office.session(id) else { return nil }
            return ([session.label] + state(session.state, since: session.since, meets: session.meets) + now)
                .joined(separator: ", ")
        case .teammate(let id):
            guard let (mate, session) = office.teammate(id) else { return nil }
            return
                ([mate.label, String(localized: "teammate of \(session.label)")]
                + state(mate.state, since: mate.since, meets: session.meets(with: mate)) + now).joined(separator: ", ")
        }
    }

    /// A session's teammates in the panel's order: each teammate's own teammates under it, a step further in.
    static func tree(_ session: Session) -> [(mate: Teammate, depth: Int)] {
        let ids = Set(session.teammates.map(\.id))
        var rows: [(mate: Teammate, depth: Int)] = []
        func add(under caller: String?, depth: Int) {
            for mate in session.teammates
            where mate.calledBy == caller || (caller == nil && !ids.contains(mate.calledBy ?? "")) {
                guard !rows.contains(where: { $0.mate.id == mate.id }) else { continue }
                rows.append((mate, depth))
                add(under: mate.id, depth: depth + 1)
            }
        }
        add(under: nil, depth: 0)
        return rows
    }

    /// What someone shown is doing now: only while they work, and only as a kind of tool.
    static func doing(_ kind: PanelSelection.Kind, in office: OfficeState) -> HookEvent.ToolKind? {
        switch kind {
        case .session(let id):
            return office.session(id)?.state == .working ? office.toolKind(session: id) : nil
        case .teammate(let id):
            return office.teammate(id)?.teammate.state == .working ? office.toolKind(teammate: id) : nil
        }
    }

    /// The nickname someone shows now: their folder's, or their name's.
    static func nickname(of kind: PanelSelection.Kind, in office: OfficeState) -> String? {
        switch kind {
        case .session(let id): return office.folder(ofSession: id).flatMap { office.nicknames.folders[$0] }
        case .teammate(let id): return office.teammate(id).flatMap { office.nicknames.agents[$0.teammate.name ?? ""] }
        }
    }

    /// Space on what has keyboard focus: a seat opens its panel, a button in the panel does what it says.
    func press(in office: OfficeState) -> Bool {
        switch focus {
        case .seat(let slot, let index)?:
            guard let seat = office.pods.first(where: { $0.slot == slot })?.seats[index] else { return false }
            open(PanelSelection(seat, at: .seat(slot: slot, index: index)))
        case .close?:
            close()
        case .mate(let id)?:
            guard let mate = office.teammate(id)?.teammate else { return false }
            open(PanelSelection(teammate: mate, in: office))
        case .edit?:
            edit(in: office)
        case .nickname?, nil:
            return false
        }
        return true
    }
}

/// The office window: a bar with the summary and 출근, then the room, and the side panel for whoever was chosen.
struct OfficeView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @StateObject private var panel: SidePanel
    @FocusState private var focus: OfficeFocus?
    /// Screenshots pin the clock and the animation frame.
    var fixedNow: Date?
    /// Screenshots can hand in a stage with someone already walking.
    var stage: Stage?
    /// Only the CPU test sets these.
    var ticksWhileHidden = false
    var reducesMotion = false

    static let defaultSize = CGSize(width: RoomLayout.defaultWindow.width, height: RoomLayout.defaultWindow.height)
    static let minSize = CGSize(width: RoomLayout.minWindow.width, height: RoomLayout.minWindow.height)

    /// Screenshots and tests can hand in a panel already open.
    init(
        fixedNow: Date? = nil, stage: Stage? = nil, panel: SidePanel? = nil, ticksWhileHidden: Bool = false,
        reducesMotion: Bool = false
    ) {
        self.fixedNow = fixedNow
        self.stage = stage
        self.ticksWhileHidden = ticksWhileHidden
        self.reducesMotion = reducesMotion
        _panel = StateObject(wrappedValue: panel ?? SidePanel())
    }

    var body: some View {
        VStack(spacing: 0) {
            OfficeBar()
            Divider()
            GeometryReader { geometry in
                let beside = SidePanelView.fitsBeside(width: geometry.size.width)
                HStack(spacing: 0) {
                    OfficeRoom(
                        panel: panel, focus: $focus, fixedNow: fixedNow, stage: stage,
                        ticksWhileHidden: ticksWhileHidden, reducesMotion: reducesMotion
                    )
                    .overlay {
                        // Centred on the floor left of the meeting room and lounge, when the window has them.
                        GeometryReader { geometry in
                            let pillar = RoomLayout(points: geometry.size.width, slots: 0).pillar
                            emptyMessage.padding(
                                .trailing,
                                pillar.map { geometry.size.width - CGFloat($0 * RoomLayout.pointsPerPixel) } ?? 0)
                        }
                    }
                    if beside, panel.selection != nil {
                        Divider()
                        sidePanel
                    }
                }
                .overlay(alignment: .trailing) {
                    if !beside, panel.selection != nil {
                        sidePanel
                            .background(
                                Color(nsColor: .windowBackgroundColor).shadow(
                                    color: .black.opacity(0.15), radius: 8, x: -2)
                            )
                            .overlay(alignment: .leading) {
                                Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
                            }
                    }
                }
            }
        }
        .frame(minWidth: Self.minSize.width, minHeight: Self.minSize.height)
        .sheet(item: $model.sheet) { sheet in
            StartSheet(sheet: sheet)
        }
        .onAppear {
            if model.shouldShowWelcome, fixedNow == nil { openWindow(id: "welcome") }
            let model = model
            let panel = panel
            KeyboardNavigation.shared.space = { [weak model, weak panel] in
                guard let model, let panel, model.sheet == nil else { return false }
                return panel.press(in: model.office)
            }
            KeyboardNavigation.shared.escape = { [weak model, weak panel] in
                guard let model, let panel, model.sheet == nil else { return false }
                return panel.escape()
            }
        }
        .onChange(of: focus) { panel.focus = $0 }
        .onChange(of: panel.selection?.kind) { kind in
            // The panel opens without moving VoiceOver's cursor, so it says who it shows.
            if let kind, let text = SidePanel.spoken(kind, in: model.office, now: fixedNow ?? Date()) {
                AppModel.announce(text)
            }
        }
        .onChange(of: panel.focusRequest) { request in
            guard let request else { return }
            focus = request
            panel.focusRequest = nil
        }
    }

    private var sidePanel: some View {
        SidePanelView(panel: panel, focus: $focus, fixedNow: fixedNow)
            .frame(width: SidePanelView.width)
            .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private var emptyMessage: some View {
        if !model.everConnected {
            EmptyOffice(
                title: "Connection needed",
                detail: "Install the plugin so Claude Code tells this app when it works."
            ) {
                Button("Connect…") { openWindow(id: "welcome") }
            }
        } else if model.office.liveSessionCount == 0 {
            EmptyOffice(
                title: "Nobody's at work yet",
                detail:
                    "Start claude in a terminal, or press Start Work. Sessions opened before this app appear when they next move."
            ) {
                EmptyView()
            }
        }
    }
}

/// Summary on the left ("Working 2 · Waiting 1 · Resting 1"), 출근 on the right.
struct OfficeBar: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                summary.font(.title3.weight(.medium))
                status.font(.callout)
            }
            Spacer(minLength: 8)
            Button {
                model.startWork()
            } label: {
                if case .starting = model.startPhase { Text("Starting…") } else { Text("Start Work") }
            }
            .controlSize(.large)
            .help(Text("Runs your start command in a new Terminal window (⇧⌘R)"))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var summary: Text {
        let office = model.office
        guard office.liveSessionCount > 0 else { return Text("No sessions running").foregroundColor(.secondary) }
        let waiting = office.count(.waiting)
        return Text("Working \(office.count(.working))")
            + Text(verbatim: " · ")
            + Text("Waiting \(waiting)").foregroundColor(waiting > 0 ? Style.waiting : .primary)
            + Text(verbatim: " · ")
            + Text("Resting \(office.count(.resting))")
    }

    /// One message under the summary. It wraps and puts its links on the next line, so nothing is cut at 420 pt.
    @ViewBuilder private var status: some View {
        if model.askAnother {
            message(Text("You're already at work. Start one more?"), color: .primary) {
                Button("Start one more") {
                    model.askAnother = false
                    model.startWork(force: true)
                }
                .keyboardShortcut(.defaultAction)
                Button("Cancel") { model.askAnother = false }.keyboardShortcut(.cancelAction)
            }
        } else {
            switch model.startPhase {
            case .failed(.folderMissing):
                message(Text("Couldn't start: the folder is missing"), color: Style.waiting) { settingsLink }
            case .failed(.other(let line)):
                message(Text("Couldn't start: \(line)"), color: Style.waiting) { settingsLink }
            case .nobodyCame:
                message(Text("The command ran, but nobody came to the office"), color: .secondary) {
                    Button("Check connection") { openWindow(id: "welcome") }.buttonStyle(.link)
                }
            case .idle, .starting:
                EmptyView()
            }
        }
    }

    private var settingsLink: some View {
        Button("Open Settings") { openWindow(id: "settings") }.buttonStyle(.link)
    }

    private func message<Actions: View>(_ text: Text, color: Color, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            text.foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) { actions() }
        }
    }
}

/// The empty-office message, on a plate in the middle of the empty room.
struct EmptyOffice<Actions: View>: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(spacing: 10) {
            Text(title).font(Style.title)
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 340)
            actions()
        }
        .padding(24)
        .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// "12 s ago" by the second for its first minute, then by the half minute: every update of the panel costs about
/// as much as the room's own ticking.
struct NewsSchedule: TimelineSchedule {
    /// Until when it counts seconds.
    let seconds: Date

    func entries(from start: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var next = start
        return AnyIterator {
            defer { next += next < seconds ? 1 : 30 }
            return next
        }
    }
}

/// The side panel: a closer look at one person, to read only (a nickname is the one thing it changes).
struct SidePanelView: View {
    /// Wide enough for a 32-character nickname and a teammate row ("code-reviewer · Waiting · 12 min"); over the
    /// default window it covers about the right-hand column, not the islands.
    static let width: CGFloat = 280

    /// Beside the room only while the islands stay where they are (the same columns and meeting room with the
    /// panel's width taken off); otherwise the panel floats over the room's right side.
    static func fitsBeside(width: CGFloat) -> Bool {
        let whole = RoomLayout(points: width, slots: 0)
        let narrower = RoomLayout(points: width - Self.width - 1, slots: 0)
        return whole.columns == narrower.columns && (whole.pillar == nil) == (narrower.pillar == nil)
    }

    @EnvironmentObject private var model: AppModel
    @ObservedObject var panel: SidePanel
    @ObservedObject private var keyboard = KeyboardNavigation.shared
    var focus: FocusState<OfficeFocus?>.Binding
    let fixedNow: Date?

    var body: some View {
        if let selection = panel.selection { content(selection) }
    }

    /// What changes with the clock alone, drawn again on its own every `seconds` ("12 s ago" by the second, minutes
    /// every 30 s): the rest of the panel and the room around it stay as they are.
    @ViewBuilder private func ticking<Content: View>(
        every seconds: TimeInterval, @ViewBuilder _ content: @escaping (Date) -> Content
    ) -> some View {
        if let fixedNow {
            content(fixedNow)
        } else {
            TimelineView(.periodic(from: Date(timeIntervalSinceReferenceDate: 0), by: seconds)) { content($0.date) }
        }
    }

    private func content(_ selection: PanelSelection) -> some View {
        let office = model.office
        return VStack(alignment: .leading, spacing: 14) {
            switch SidePanel.facts(selection, in: office) {
            case .session(let session, let named, let news):
                header(Text(verbatim: session.label), auto: named ? Text(verbatim: session.name) : nil)
                details(
                    role: Text("Session"), state: session.state, since: session.since, meets: session.meets,
                    teammateWaiting: session.teammateWaiting, doing: SidePanel.doing(selection.kind, in: office),
                    news: news)
                teammates(session, in: office)
            case .teammate(let mate, let session, let news):
                header(mate.displayName, auto: mate.nickname != nil ? mate.autoName : nil)
                details(
                    role: Text("Teammate of \(session.label)"), state: mate.state, since: mate.since,
                    meets: session.meets(with: mate), teammateWaiting: false,
                    doing: SidePanel.doing(selection.kind, in: office),
                    news: news)
            case .wentHome(let name):
                wentHome(name)
            }
        }
        .padding(16)
    }

    /// Someone who has gone: the name faded, and the panel stays open.
    @ViewBuilder private func wentHome(_ name: String) -> some View {
        header(Text(verbatim: name), faded: true)
        Text("Went home").foregroundStyle(.secondary)
    }

    /// The name with a pencil button to give a nickname (the automatic name small under it, when there is one), or the field
    /// to type it in; × to close.
    private func header(_ name: Text, auto: Text? = nil, faded: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if panel.draft != nil, !faded {
                    nicknameField(prompt: auto ?? name)
                } else {
                    name.font(Style.title).lineLimit(2).foregroundStyle(faded ? .secondary : .primary)
                    if !faded {
                        Button {
                            panel.edit(in: model.office)
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .focusable(keyboard.active)
                        .focused(focus, equals: .edit)
                        .help(Text("Edit nickname"))
                        .accessibilityLabel(Text("Edit nickname"))
                    }
                }
                Spacer(minLength: 4)
                Button {
                    panel.close()
                } label: {
                    Image(systemName: "xmark").font(.body.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .focusable(keyboard.active)
                .focused(focus, equals: .close)
                .help(Text("Close"))
                .accessibilityLabel(Text("Close"))
            }
            if panel.draft != nil, !faded {
                Text("Return saves, Esc cancels. Empty goes back to the automatic name.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if let auto {
                auto.font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// Typing a nickname: at most 32 characters; Return saves (empty: the automatic name), Esc cancels.
    private func nicknameField(prompt: Text) -> some View {
        TextField(
            text: Binding(
                get: { panel.draft ?? "" },
                set: { panel.draft = String($0.prefix(Nicknames.maxLength)) }),
            prompt: prompt
        ) {
            Text("Nickname")
        }
        .textFieldStyle(.roundedBorder)
        .focused(focus, equals: .nickname)
        .onSubmit {
            guard let selection = panel.selection, let draft = panel.draft,
                let label = model.rename(selection.kind, to: draft)
            else { return }
            panel.selection?.name = label
            panel.stopEditing()
        }
    }

    /// "Session" or "Teammate of my-project", the state and for how long (a wait first, then the meeting), and
    /// when the app last heard from them.
    @ViewBuilder private func details(
        role: Text, state: WorkState, since: Date, meets: Bool, teammateWaiting: Bool,
        doing: HookEvent.ToolKind?, news: Date?
    ) -> some View {
        role.foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 4) {
            if !meets || state == .waiting {
                ticking(every: 30) { now in
                    let minutes = Int(now.timeIntervalSince(since) / 60)
                    (state.word + (minutes >= 1 ? Text(verbatim: " · ") + Text("\(minutes) min") : Text(verbatim: "")))
                        .foregroundStyle(state.color)
                }
            }
            if let doing { doing.phrase }
            if teammateWaiting { Text("Teammate waiting").foregroundStyle(Style.waiting) }
            if meets { Text("In a meeting") }
        }
        HStack {
            Text("Last news").foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let fixedNow {
                Self.ago(news, now: fixedNow)
            } else {
                TimelineView(NewsSchedule(seconds: (news ?? .distantPast) + 60)) { Self.ago(news, now: $0.date) }
            }
        }
    }

    /// The session's teammates, one row each; a row opens that teammate's panel.
    private func teammates(_ session: Session, in office: OfficeState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Teammates").font(.headline)
            if session.teammates.isEmpty { Text("No teammates").foregroundStyle(.secondary) }
            ForEach(SidePanel.tree(session), id: \.mate.id) { mate, depth in
                Button {
                    panel.open(PanelSelection(teammate: mate, in: office))
                } label: {
                    HStack {
                        Text(verbatim: mate.label).lineLimit(1).truncationMode(.middle)
                            .padding(.leading, CGFloat(min(depth, 4)) * 14)
                        if mate.headphones {
                            Image(systemName: "headphones").font(.caption).foregroundStyle(.secondary)
                                .help(Text("Working on its own"))
                                .accessibilityLabel(Text("Working on its own"))
                        }
                        Spacer(minLength: 8)
                        ticking(every: 30) { now in
                            mate.state.label(since: mate.since, now: now).foregroundStyle(mate.state.color)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(keyboard.active)
                .focused(focus, equals: .mate(mate.id))
            }
        }
    }

    /// By the app's own clock: "12 s ago", "3 min ago", "2 h ago"; "—" before any news since the app started.
    static func ago(_ date: Date?, now: Date) -> Text {
        guard let date else { return Text(verbatim: "—") }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return Text("\(seconds) s ago") }
        if seconds < 3600 { return Text("\(seconds / 60) min ago") }
        return Text("\(seconds / 3600) h ago")
    }
}
