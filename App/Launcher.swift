import AppKit

/// Opens a script in a new Terminal window, the same as `open -a Terminal file.command`.
/// Launch Services opening a document is not Apple Events, so no Automation permission is involved.
enum Launcher {
    static func run(_ command: StartCommand, scriptFolder: URL, completion: @escaping @MainActor (Error?) -> Void) {
        do {
            open(script: try command.script(home: Paths.home), named: "start", in: scriptFolder, completion: completion)
        } catch {
            Task { @MainActor in completion(error) }
        }
    }

    static func open(
        script: String, named name: String, in folder: URL, completion: @escaping @MainActor (Error?) -> Void
    ) {
        do {
            let url = folder.appendingPathComponent("\(name)-\(UUID().uuidString).command")
            guard
                FileManager.default.createFile(
                    atPath: url.path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o700])
            else {
                throw CocoaError(.fileWriteUnknown)
            }
            guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                try? FileManager.default.removeItem(at: url)
                throw CocoaError(.fileNoSuchFile)
            }
            NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
            { _, error in
                // The script deletes itself when it runs; if Terminal never ran it, we delete it.
                if error != nil { try? FileManager.default.removeItem(at: url) }
                Task { @MainActor in completion(error) }
            }
        } catch {
            Task { @MainActor in completion(error) }
        }
    }
}

/// How Update works for this copy of the app. `page`: it can't replace itself here, so the buttons open the release's
/// page (opened from Downloads, outside Applications, or in a folder this user can't write).
enum UpdateRoute {
    case homebrew(HomebrewRoute)
    case selfUpdate(SelfUpdateRoute)
    case page
}

/// The app's own way of Update, apart from the model so tests never replace, open or quit a real app.
struct SelfUpdateRoute {
    var prepare: @Sendable (ReleaseVersion, ReleaseVersion) async -> UpdateFailure?
    var swap: () -> Bool
    var removeCopy: () -> Void
    /// Opens the app now at this path as a new instance; nil when it couldn't.
    var open: (@escaping @MainActor (NSRunningApplication?) -> Void) -> Void
    /// Whether the app that was just opened has taken the socket. This one let go of it first, so an answer can only
    /// come from the new app: past launch and macOS's checks, running this app's start-up code.
    var isListening: () -> Bool
    var quit: () -> Void
    /// How long the new app has to take the socket before the old one comes back.
    var patience: TimeInterval = 30

    static func live(_ update: SelfUpdate, socketPath: String) -> SelfUpdateRoute {
        let place = update.place
        return SelfUpdateRoute(
            prepare: { await update.prepare($0, current: $1) },
            swap: place.swap,
            removeCopy: place.removeCopy,
            open: { completion in
                // This process still runs at this path: without a new instance macOS would only bring it forward.
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.createsNewApplicationInstance = true
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: place.bundle), configuration: configuration)
                { app, _ in
                    Task { @MainActor in completion(app) }
                }
            },
            isListening: { EventClient.isListening(at: socketPath) },
            quit: { NSApp.terminate(nil) })
    }
}

/// Homebrew's part of Update, apart from the model so tests never open Terminal, read the real app or quit.
struct HomebrewRoute {
    var openTerminal: (@escaping @MainActor (Error?) -> Void) -> Void
    var installedVersion: () -> ReleaseVersion?
    /// Opens the app on disk and quits this one. False when it couldn't.
    var reopen: () -> Bool

    static func live(bundlePath: String, scriptFolder: URL) -> HomebrewRoute {
        HomebrewRoute(
            openTerminal: { completion in
                let korean = Bundle.main.preferredLocalizations.first == "ko"
                Launcher.open(
                    script: HomebrewUpdate.script(korean: korean), named: "update", in: scriptFolder,
                    completion: completion)
            },
            installedVersion: { HomebrewUpdate.installedVersion(bundlePath: bundlePath) },
            reopen: {
                // `-n`: this process still runs, and without it macOS would only bring this one forward. Not waited
                // for: a new app macOS blocks keeps `open` busy until its dialog goes.
                let open = Process()
                open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                open.arguments = ["-n", bundlePath]
                guard (try? open.run()) != nil else { return false }
                NSApp.terminate(nil)
                return true
            })
    }
}
