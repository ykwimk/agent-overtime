import SwiftUI

/// The office window: a bar with the summary and 출근, then the room.
struct OfficeView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    /// Screenshots pin the clock and the animation frame.
    var fixedNow: Date?
    /// Screenshots can hand in a stage with someone already walking.
    var stage: Stage?
    /// Only the CPU test sets these.
    var ticksWhileHidden = false
    var reducesMotion = false

    static let defaultSize = CGSize(width: RoomLayout.defaultWindow.width, height: RoomLayout.defaultWindow.height)
    static let minSize = CGSize(width: RoomLayout.minWindow.width, height: RoomLayout.minWindow.height)

    var body: some View {
        VStack(spacing: 0) {
            OfficeBar()
            Divider()
            OfficeRoom(
                fixedNow: fixedNow, stage: stage, ticksWhileHidden: ticksWhileHidden, reducesMotion: reducesMotion
            )
            .overlay { emptyMessage }
        }
        .frame(minWidth: Self.minSize.width, minHeight: Self.minSize.height)
        .sheet(item: $model.sheet) { sheet in
            StartSheet(sheet: sheet)
        }
        .onAppear {
            if model.shouldShowWelcome, fixedNow == nil { openWindow(id: "welcome") }
        }
    }

    @ViewBuilder private var emptyMessage: some View {
        if !model.everConnected {
            EmptyOffice(
                title: "Connection needed",
                detail: "Install the plugin so Claude Code tells this app when it works."
            ) {
                Button("Connect…") { openWindow(id: "welcome") }
            }
        } else if model.office.desks.isEmpty {
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
                if model.everConnected && model.office.liveSessionCount == 0 && !model.office.desks.isEmpty {
                    Text("Sessions opened before this app appear when they next move.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
