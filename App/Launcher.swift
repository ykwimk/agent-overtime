import AppKit

/// Opens the start command in a new Terminal window, the same as `open -a Terminal file.command`.
/// Launch Services opening a document is not Apple Events, so no Automation permission is involved.
enum Launcher {
    static func run(_ command: StartCommand, scriptFolder: URL, completion: @escaping @MainActor (Error?) -> Void) {
        do {
            let script = try command.script(home: Paths.home)
            let url = scriptFolder.appendingPathComponent("start-\(UUID().uuidString).command")
            guard FileManager.default.createFile(atPath: url.path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o700]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                try? FileManager.default.removeItem(at: url)
                throw CocoaError(.fileNoSuchFile)
            }
            NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                // The script deletes itself when it runs; if Terminal never ran it, we delete it.
                if error != nil { try? FileManager.default.removeItem(at: url) }
                Task { @MainActor in completion(error) }
            }
        } catch {
            Task { @MainActor in completion(error) }
        }
    }
}
