import SwiftUI

/// The menu bar icon: a small building, or "! 2" while sessions wait for you.
struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let waiting = model.office.count(.waiting)
        HStack(spacing: 2) {
            if waiting > 0 {
                Image(systemName: "exclamationmark.bubble.fill")
                Text(verbatim: "\(waiting)")
            } else {
                Image(systemName: "building.2")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(waiting > 0 ? Text("Agent Overtime, \(waiting) waiting") : Text("Agent Overtime"))
    }
}

/// What opens from the menu bar: who is waiting, without opening the office.
struct MenuContent: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var fixedNow: Date?

    private static let maxRows = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sessions.padding(.vertical, 6)
            Divider().padding(.vertical, 4)
            if model.updates.isInTerminal {
                Text("Updating in Terminal…").foregroundStyle(.secondary).padding(.horizontal, 15).padding(
                    .vertical, 3)
            } else if let version = model.updates.newVersion {
                MenuRow(title: "New version available — Update") {
                    model.startUpdate(version)
                    if model.updates.isInTerminal { show("office") }
                }
            }
            MenuRow(title: "Open Office", shortcut: "⌘O") { show("office") }
            MenuRow(title: "Start Work", shortcut: "⇧⌘R") {
                model.startWork()
                if model.sheet != nil || model.askAnother { show("office") }
            }
            MenuRow(title: "Settings…", shortcut: "⌘,") { show("settings") }
            Divider().padding(.vertical, 4)
            MenuRow(title: "Quit Agent Overtime", shortcut: "⌘Q") { NSApp.terminate(nil) }
        }
        .padding(.vertical, 6)
        .frame(width: 300)
    }

    @ViewBuilder private var sessions: some View {
        let now = fixedNow ?? Date()
        let rows = model.office.desks.flatMap(\.sessions)
        if !model.everConnected {
            MenuRow(title: "Not connected · Connect…") { show("welcome") }
        } else if rows.isEmpty {
            Text("No sessions running").foregroundStyle(.secondary).padding(.horizontal, 15).padding(.vertical, 3)
        } else {
            ForEach(rows.prefix(Self.maxRows)) { session in
                let shown = session.shown  // waiting if a teammate waits, same rule as the counts
                HStack(spacing: 8) {
                    Circle().fill(
                        shown.state == .waiting
                            ? Style.waiting : Color.secondary.opacity(shown.state == .working ? 0.9 : 0.4)
                    )
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                    Text(verbatim: session.label).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    shown.state.label(since: shown.since, now: now)
                        .foregroundStyle(shown.state.color)
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 3)
                .accessibilityElement(children: .combine)
            }
            if rows.count > Self.maxRows {
                Text("and \(rows.count - Self.maxRows) more").foregroundStyle(.secondary).padding(.horizontal, 15)
                    .padding(.vertical, 3)
            }
        }
    }

    private func show(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}
