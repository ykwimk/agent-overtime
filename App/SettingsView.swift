import SwiftUI

/// What to do with the three lines just copied, and the two that bring the plugin back if they stop partway.
struct ConnectUpdateNote: View {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Copied. Paste into Claude Code, then restart the sessions you have open.")
                .fixedSize(horizontal: false, vertical: true)
            Text("If it stops partway, the plugin is gone until these two lines run:")
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
            Text(verbatim: Release.connectCommands)
                .font(.system(.callout, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Button("Copy These Two Lines") { Self.copy(Release.connectCommands) }
        }
        .font(.callout)
        .lineLimit(nil)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editing = false
    @State private var copied = false
    @State private var copiedUpdate = false
    @State private var confirmRemove = false

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    /// Everyone named on an ARTIST(S) line of the credits; a test keeps the two in step.
    static let artists = ["Eliza Wyatt", "Lanea \"Sharm\" Zimmerman", "BlueCarrot16", "Richard \"Jetrel\" Kettering"]
    static let artLicenseURL = URL(string: "https://static.opengameart.org/OGA-BY-3.0.txt")!
    static let peopleURL = URL(string: "https://jik-a-4.itch.io/metrocity-free-topdown-character-pack")!

    /// Opens a text file from the app's Art folder in the default text app (nothing is written or sent).
    static func openBundled(_ name: String) {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Art").appendingPathComponent(name) else {
            return
        }
        NSWorkspace.shared.open(url)
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
                    NSPasteboard.general.setString(Release.connectCommands, forType: .string)
                    copied = true
                }
                if copied {
                    Text("Copied. Paste into Claude Code, then send it a message.").font(.callout).foregroundStyle(
                        .secondary)
                }
                Button("Copy Connection Update Commands") {
                    ConnectUpdateNote.copy(Release.connectUpdateCommands)
                    copiedUpdate = true
                }
                if copiedUpdate { ConnectUpdateNote() }
                Text("To disconnect, turn off or remove agent-overtime with /plugin in Claude Code.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Find Sessions Without the Plugin", isOn: $model.findsSessions)
                Text(
                    "Shows the Claude Code sessions started on this Mac even before the plugin sends news. Claude run by a script may show too."
                )
                .fixedSize(horizontal: false, vertical: true)
                .font(.callout).foregroundStyle(.secondary)
            } header: {
                Text("Connection")
            }

            Section {
                if let start = model.start {
                    LabeledContent {
                        Text(verbatim: StartCommand.revealed(start.folder)).textSelection(.enabled)
                    } label: {
                        Text("Folder")
                    }
                    LabeledContent {
                        Text(verbatim: start.run.map(StartCommand.revealed).joined(separator: " ")).font(
                            .system(.body, design: .monospaced)
                        ).textSelection(.enabled)
                    } label: {
                        Text("Command")
                    }
                    HStack {
                        Button("Change…") { editing = true }
                        Button("Remove", role: .destructive) { confirmRemove = true }
                    }
                } else {
                    Text("No start command yet.").foregroundStyle(.secondary)
                    Button("Set Up…") { editing = true }
                }
            } header: {
                Text("Start Work")
            }

            Section {
                Toggle("Show Details", isOn: $model.showsDetails)
                Text(
                    "Shows the files being read and edited, tasks and the model in the side panel. They stay on this Mac and are never saved. Anyone who sees your screen, for example while you share it, can read them."
                )
                .fixedSize(horizontal: false, vertical: true)
                .font(.callout).foregroundStyle(.secondary)
            } header: {
                Text("Side Panel")
            }

            Section {
                LabeledContent {
                    Text(verbatim: "\(model.office.folders.count)")
                } label: {
                    Text("Recent folders")
                }
                Button("Clear Recent Folders") { model.forgetIdleFolders() }
                    .disabled(model.office.idleFolders.isEmpty)
                Text(
                    "Folders sessions ran in, to pick from when you set up Start Work. Kept only on this Mac; folders with a session running stay."
                )
                .fixedSize(horizontal: false, vertical: true)
                .font(.callout).foregroundStyle(.secondary)
            } header: {
                Text("Recent Folders")
            }

            Section {
                let count = model.office.nicknames.folders.count + model.office.nicknames.agents.count
                LabeledContent {
                    Text(verbatim: "\(count)")
                } label: {
                    Text("Saved nicknames")
                }
                Button("Clear All Nicknames") { model.forgetNicknames() }
                    .disabled(count == 0)
                Text(
                    "Names you gave sessions and teammates with the pencil button next to the name in the side panel. Kept only on this Mac."
                )
                .fixedSize(horizontal: false, vertical: true)
                .font(.callout).foregroundStyle(.secondary)
            } header: {
                Text("Nicknames")
            }

            Section {
                Toggle("Check for Updates", isOn: $model.checksForUpdates)
                    .disabled(model.updates.isDownloading)
                Text(
                    "Asks GitHub for the latest version number when the app opens and once a day. The app makes no other requests on its own. As with any web request, GitHub sees your IP address and this app's version."
                )
                .fixedSize(horizontal: false, vertical: true)
                .font(.callout).foregroundStyle(.secondary)
                if model.updates.isOn { updateStatus }
            } header: {
                Text("Updates")
            }

            Section {
                LabeledContent {
                    Text(verbatim: version)
                } label: {
                    Text("Version")
                }
                LabeledContent {
                    Link(destination: AppModel.repositoryURL) { Text(verbatim: Release.repository) }
                } label: {
                    Text("Source")
                }
                Text("Code: MIT License.").font(.callout).foregroundStyle(.secondary)
                Text("Works with Claude Code. Not affiliated with Anthropic.").font(.callout).foregroundStyle(
                    .secondary)
            } header: {
                Text("About")
            }

            Section {
                LabeledContent {
                    Text(verbatim: "LPC Revised")
                } label: {
                    Text("Room")
                }
                LabeledContent {
                    // No-break spaces inside each name, so lines only break after a comma.
                    Text(
                        verbatim: Self.artists.map { $0.replacingOccurrences(of: " ", with: "\u{00A0}") }.joined(
                            separator: ", ")
                    )
                    .multilineTextAlignment(.trailing)
                } label: {
                    Text("Artists")
                }
                LabeledContent {
                    Link(destination: Self.artLicenseURL) { Text(verbatim: "OGA-BY 3.0") }
                } label: {
                    Text("License")
                }
                LabeledContent {
                    Link(destination: Self.peopleURL) { Text(verbatim: "MetroCity by JIK-A-4, CC0 1.0") }
                } label: {
                    Text("People")
                }
                Text(
                    "The art is not MIT: the room is OGA-BY 3.0 and the people are CC0 1.0, cropped and combined for this app. Each file's artists are in the credits."
                )
                .fixedSize(horizontal: false, vertical: true)
                .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Open Credits") { Self.openBundled("CREDITS.txt") }
                    Link(destination: AppModel.creditsURL) { Text("Credits on GitHub") }
                }
            } header: {
                Text("Art")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(isPresented: $editing) {
            StartSheet(sheet: .register)
        }
        .alert(Text("Remove the start command?"), isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { model.clearStart() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can set it up again with Start Work at any time.")
        }
    }

    @ViewBuilder private var updateStatus: some View {
        switch model.updates.result {
        case nil:
            Text("Checking…").foregroundStyle(.secondary)
        case .upToDate:
            Text("You're up to date").foregroundStyle(.secondary)
        case .failed:
            if let date = model.updates.lastChecked {
                Text("Last checked \(Text(date, format: .relative(presentation: .named)))").foregroundStyle(.secondary)
            } else {
                Text("Couldn't check yet").foregroundStyle(.secondary)
            }
        case .available(let version):
            Text("\(version.number) is available")
            if model.updates.isInTerminal {
                Text("Updating in Terminal…").foregroundStyle(.secondary)
            } else if model.updates.isDownloading {
                Text("Downloading the new version…").foregroundStyle(.secondary)
            } else if let failure = model.updates.shownFailure {
                UpdateFailureLine(failure: failure)
            } else if model.canUpdateHere {
                HStack {
                    Button("Update") { model.startUpdate(version) }
                    Button("What's New") { model.openRelease(version) }
                }
                if model.updatesWithHomebrew {
                    Text("After updating, allow the new version in System Settings, as on first install.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Button("Open Download Page") { model.openRelease(version) }
                Text("The app can't replace itself here. Download the new version and put it in Applications.")
                    .fixedSize(horizontal: false, vertical: true)
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
