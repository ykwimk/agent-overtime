import SwiftUI

/// Registers the start command, and is also the confirmation: the folder and every argument are shown
/// in full, one per line, with hidden characters made visible, before anything runs.
struct StartSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let sheet: AppModel.Sheet
    /// Screenshots pass a starting point; otherwise the saved command or `claude` in the first recent folder.
    var initial: StartCommand?

    @State private var folder = ""
    @State private var commandLine = "claude"

    private var command: StartCommand {
        // A changed command is confirmed as stored, never re-typed through the parser.
        if case .confirm(let saved) = sheet { return saved.resolved(home: Paths.home) }
        return StartCommand(folder: folder, run: StartCommand.parse(commandLine)).resolved(home: Paths.home)
    }

    private var canStart: Bool { !folder.isEmpty && !(command.run.first ?? "").isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch sheet {
            case .register:
                Text("Set Up Start Work").font(Style.title)
                folderPicker
                VStack(alignment: .leading, spacing: 6) {
                    Text("Command").font(.headline)
                    TextField(text: $commandLine) { Text("Command") }
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                    Text("Put quotes around a value that has spaces. Terminal symbols such as && · | · $ don't work here; they are passed on as plain text. To start several things, put them in one script.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .confirm:
                Text("Start with this command?").font(Style.title)
                Text("The saved start command changed outside the app. Check it before it runs.")
                    .foregroundStyle(Style.waiting)
                    .fixedSize(horizontal: false, vertical: true)
            }

            preview

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start Work with This Command") { model.approveAndStart(command) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear(perform: load)
    }

    private var folderPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Folder").font(.headline)
            let recent = Array(model.office.folders.suffix(6).reversed())
            if !recent.isEmpty {
                Picker(selection: $folder) {
                    ForEach(recent, id: \.self) { path in
                        Text(verbatim: path).tag(path)
                    }
                    if !folder.isEmpty, !recent.contains(folder) { Text(verbatim: folder).tag(folder) }
                } label: {
                    Text("Folder")
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            } else if !folder.isEmpty {
                Text(verbatim: folder).font(.system(.body, design: .monospaced))
            }
            Button("Other Folder…", action: chooseFolder)
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("This runs exactly this command, in this folder:").font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow {
                    Text("Folder").foregroundStyle(.secondary)
                    if folder.isEmpty { Text(verbatim: "—") } else { revealed(command.folder) }
                }
                ForEach(Array(command.run.enumerated()), id: \.offset) { index, argument in
                    GridRow {
                        Text(index == 0 ? "Program" : "Argument \(index)").foregroundStyle(.secondary)
                        revealed(argument)
                    }
                }
            }
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Style.floor))
            Text("It opens a new Terminal window. The app never adds options to your command.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// A value with hidden characters is shown in the warning colour, with each one spelled out.
    private func revealed(_ value: String) -> some View {
        let shown = StartCommand.revealed(value)
        return Text(verbatim: shown).foregroundStyle(shown == value ? Color.primary : Style.waiting)
    }

    private func load() {
        if case .confirm(let saved) = sheet {
            apply(saved)
        } else if let initial {
            apply(initial)
        } else if let saved = model.start {
            apply(saved)
        } else {
            folder = model.office.folders.last ?? ""
        }
    }

    private func apply(_ saved: StartCommand) {
        folder = saved.folder
        commandLine = saved.run.map { $0.contains(" ") || $0.isEmpty ? "\"\($0)\"" : $0 }.joined(separator: " ")
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }
}
