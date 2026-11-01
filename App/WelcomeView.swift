import SwiftUI

/// The first window: what the app does, and the two lines that connect Claude Code to it.
struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    /// Screenshots pass a location; the app uses where it really is.
    var location: AppLocation?
    @State private var copiedAt: Date?
    @State private var noNewsYet: Bool

    /// Screenshots can start in the "no news yet" state; the app always starts without it.
    init(location: AppLocation? = nil, noNewsYet: Bool = false) {
        self.location = location
        _noNewsYet = State(initialValue: noNewsYet)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: "Agent Overtime").font(Style.title)
                Text("Shows your Claude Code sessions at work in a pixel office. Nothing leaves this Mac.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .top, spacing: 20) {
                example(.working, seed: "my-app")
                example(.waiting, seed: "api-server")
                example(.resting, seed: "notes")
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Connect").font(.headline)
                Text("A small plugin lets Claude Code tell this app when it works. Paste these two lines into Claude Code. They apply to every Claude Code session on this Mac, and you can turn the plugin off or remove it in Claude Code at any time.")
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: AppModel.connectCommands)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Style.floor))
                    .accessibilityLabel(Text("Connect commands"))
                    .accessibilityValue(Text(verbatim: AppModel.connectCommands))
                locationNote
                progress
            }

            HStack {
                Link(destination: AppModel.hooksURL) { Text("See what it adds") }
                Spacer()
                Button("Later") {
                    model.welcomeDismissed = true
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Copy Connect Commands") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(AppModel.connectCommands, forType: .string)
                    copiedAt = Date()
                    noNewsYet = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 540)
        .task(id: copiedAt) {
            // No news 30 s after copying: show what to check.
            guard copiedAt != nil else { return }
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            if !Task.isCancelled, !model.receivedThisRun { noNewsYet = true }
        }
    }

    private func example(_ state: WorkState, seed: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Workstation(pose: Pose(state), seed: seed, scale: 2.5)
            Text(verbatim: seed).font(.caption.weight(.medium))
            state.word.font(.caption).foregroundStyle(state.color)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var locationNote: some View {
        switch location ?? model.location {
        case .ok:
            EmptyView()
        case .translocated, .notInApplications:
            Label {
                Text("Move AgentOvertime.app into the Applications folder, keep its name, and open it again. The plugin looks for it there.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .foregroundStyle(Style.waiting)
        }
    }

    @ViewBuilder private var progress: some View {
        if model.receivedThisRun {
            HStack {
                Label("Connected. Your sessions are in the office.", systemImage: "checkmark.circle")
                Button("Open Office") {
                    openWindow(id: "office")
                    dismiss()
                }
                .buttonStyle(.link)
            }
        } else if noNewsYet {
            VStack(alignment: .leading, spacing: 4) {
                Text("No news yet").font(.headline).foregroundStyle(Style.waiting)
                Text("• Is agent-overtime turned on in Claude Code's /plugin list?")
                Text("• Is this app in the Applications folder?")
                Text("• Send Claude Code one message after installing.")
            }
            .font(.callout)
        } else if copiedAt != nil {
            Text("Copied. Paste into Claude Code, then send it a message.").font(.callout).foregroundStyle(.secondary)
        }
    }
}
