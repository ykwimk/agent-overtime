import SwiftUI

/// Where keyboard focus can be in the office window: the seats (once Tab is pressed), then the side panel.
enum OfficeFocus: Hashable {
    case seat(slot: Int, index: Int)
    case close
    case edit
    case mate(String)
}

/// Whose details the side panel shows.
struct PanelSelection: Equatable {
    enum Kind: Equatable {
        case session(String)
        case teammate(String)
        /// A seat someone went home from.
        case off
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
            name = session.name
        case .teammate(let mate, _):
            kind = .teammate(mate.id)
            name = mate.label
        case .off(let name, _):
            kind = .off
            self.name = name
        }
        self.seat = place
    }
}

/// The side panel's state, apart from the view so tests can drive it: whose details it shows, and where keyboard
/// focus is and goes back to.
final class SidePanel: ObservableObject {
    @Published var selection: PanelSelection?
    /// Focus for the view to move to (FocusState lives in the view), and where it is now.
    @Published var focusRequest: OfficeFocus?
    var focus: OfficeFocus?

    init(_ selection: PanelSelection? = nil) {
        self.selection = selection
    }

    /// Opens the panel on someone. From the keyboard, focus moves into it.
    func open(_ chosen: PanelSelection) {
        selection = chosen
        if KeyboardNavigation.shared.active { focusRequest = .close }
    }

    /// Closes the panel; focus goes back to the seat it came from.
    func close() {
        focusRequest = selection?.seat
        selection = nil
    }

    /// Esc: closes the panel. False when it is not open.
    func escape() -> Bool {
        guard selection != nil else { return false }
        close()
        return true
    }

    /// Space on what has keyboard focus: a seat opens its panel, a button in the panel does what it says.
    func press(in office: OfficeState) -> Bool {
        switch focus {
        case .seat(let slot, let index)?:
            guard let seat = office.pods.first(where: { $0.slot == slot })?.seats[index] else { return false }
            open(PanelSelection(seat, at: .seat(slot: slot, index: index)))
        case .close?:
            close()
        case .edit?, .mate?, nil:
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
                            .background(Color(nsColor: .windowBackgroundColor))
                            .overlay(alignment: .leading) { Divider() }
                            .shadow(color: .black.opacity(0.15), radius: 8, x: -2)
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
        if let selection = panel.selection {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: selection.name).font(Style.title).lineLimit(2)
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
            }
            .padding(16)
        }
    }
}
