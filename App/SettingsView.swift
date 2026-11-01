import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editing = false

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    if model.receivedThisRun {
                        Label("Receiving", systemImage: "checkmark.circle").foregroundStyle(.primary)
                    } else {
                        Text("No news yet").foregroundStyle(model.everConnected ? Color.secondary : Style.waiting)
                    }
                } label: {
                    Text("Status")
                }
                Button("Copy Connect Commands") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(AppModel.connectCommands, forType: .string)
                }
                Text("To disconnect, turn off or remove agent-overtime with /plugin in Claude Code.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: {
                Text("Connection")
            }

            Section {
                if let start = model.start {
                    LabeledContent { Text(verbatim: StartCommand.revealed(start.folder)).textSelection(.enabled) } label: { Text("Folder") }
                    LabeledContent {
                        Text(verbatim: start.run.map(StartCommand.revealed).joined(separator: " ")).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    } label: { Text("Command") }
                    HStack {
                        Button("Change…") { editing = true }
                        Button("Remove", role: .destructive) { model.clearStart() }
                    }
                } else {
                    Text("No start command yet.").foregroundStyle(.secondary)
                    Button("Set Up…") { editing = true }
                }
            } header: {
                Text("Start Work")
            }

            Section {
                LabeledContent { Text(verbatim: "\(model.office.desks.count)") } label: { Text("Remembered desks") }
                Button("Forget Empty Desks") { model.forgetEmptyDesks() }
                    .disabled(!model.office.desks.contains(where: \.isOff))
                Text("Desks are the folders sessions ran in, kept only on this Mac.").font(.callout).foregroundStyle(.secondary)
            } header: {
                Text("Desks")
            }

            Section {
                LabeledContent { Text(verbatim: version) } label: { Text("Version") }
                LabeledContent { Link(destination: AppModel.repositoryURL) { Text(verbatim: AppModel.repository) } } label: { Text("Source") }
                Text("MIT License. Pixel art drawn in code for this app (MIT).").font(.callout).foregroundStyle(.secondary)
                Text("Works with Claude Code. Not affiliated with Anthropic.").font(.callout).foregroundStyle(.secondary)
            } header: {
                Text("About")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(isPresented: $editing) {
            StartSheet(sheet: .register)
        }
    }
}
