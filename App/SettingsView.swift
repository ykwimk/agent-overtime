import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editing = false
    @State private var copied = false
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
                Text("To disconnect, turn off or remove agent-overtime with /plugin in Claude Code.")
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
                LabeledContent {
                    Text(verbatim: "\(model.office.desks.count)")
                } label: {
                    Text("Recent folders")
                }
                Button("Clear Recent Folders") { model.forgetIdleFolders() }
                    .disabled(!model.office.desks.contains(where: \.isOff))
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
                Text("Names you gave sessions and teammates with ✏️ in the side panel. Kept only on this Mac.")
                    .fixedSize(horizontal: false, vertical: true)
                    .font(.callout).foregroundStyle(.secondary)
            } header: {
                Text("Nicknames")
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
}
