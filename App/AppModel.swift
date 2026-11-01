import AppKit
import SwiftUI

/// Holds the office, listens on the socket, and runs the one start command.
@MainActor
final class AppModel: ObservableObject {
    enum StartPhase: Equatable {
        case idle
        case starting(Date)
        case failed(StartFailure)
        case nobodyCame
    }

    enum StartFailure: Equatable {
        case folderMissing
        case other(String)
    }

    /// Which start sheet to show: register (edit) or confirm a command changed outside the app.
    enum Sheet: Identifiable, Equatable {
        case register
        case confirm(StartCommand)
        var id: String {
            switch self {
            case .register: return "register"
            case .confirm(let command): return command.fingerprint
            }
        }
    }

    private struct Stored: Codable {
        var start: StartCommand?
        var desks: [String] = []
    }

    /// The model the running app uses (the screenshot tests read it).
    private(set) static var live: AppModel?

    @Published private(set) var office: OfficeState
    @Published private(set) var start: StartCommand?
    @Published private(set) var receivedThisRun = false
    @Published private(set) var everConnected: Bool
    @Published private(set) var serverFailed = false
    @Published var startPhase: StartPhase = .idle
    @Published var sheet: Sheet?
    @Published var askAnother = false
    @Published var welcomeDismissed: Bool {
        didSet { defaults.set(welcomeDismissed, forKey: Keys.welcomeDismissed) }
    }

    let location: AppLocation
    let socketPath: String
    private let configURL: URL
    private let defaults: UserDefaults
    private var server: EventServer?
    private var ticker: Timer?

    private enum Keys {
        static let approved = "approvedStartFingerprint"
        static let everConnected = "everConnected"
        static let welcomeDismissed = "welcomeDismissed"
    }

    static let repository = "ykwimk/agent-overtime"
    static var connectCommands: String {
        "/plugin marketplace add \(repository)\n/plugin install agent-overtime@agent-overtime"
    }
    static let hooksURL = URL(string: "https://github.com/\(repository)/blob/main/plugin/hooks/hooks.json")!
    static let repositoryURL = URL(string: "https://github.com/\(repository)")!

    init(supportFolder: String, socketPath: String, defaults: UserDefaults, bundlePath: String = Bundle.main.bundlePath)
    {
        self.socketPath = socketPath
        self.defaults = defaults
        configURL = URL(fileURLWithPath: supportFolder).appendingPathComponent("config.json")
        location = AppLocation.check(bundlePath: bundlePath, home: Paths.home)
        everConnected = defaults.bool(forKey: Keys.everConnected)
        welcomeDismissed = defaults.bool(forKey: Keys.welcomeDismissed)

        try? EventServer.prepareFolder(supportFolder)
        let stored =
            (try? Data(contentsOf: configURL)).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? Stored()
        office = OfficeState(folders: stored.desks)
        start = stored.start
    }

    /// The real app: Application Support. Under XCTest: a throwaway folder, so tests never touch the user's data.
    static func forThisProcess() -> AppModel {
        let model: AppModel
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            let folder = (Paths.userTempFolder as NSString).appendingPathComponent("ao-test-\(getpid())")
            let defaults = UserDefaults(suiteName: "AgentOvertimeTests-\(getpid())")!
            model = AppModel(supportFolder: folder, socketPath: folder + "/events.sock", defaults: defaults)
        } else {
            model = AppModel(supportFolder: Paths.supportFolder(), socketPath: Paths.socket(), defaults: .standard)
        }
        model.listen()
        live = model
        return model
    }

    func listen() {
        let server = EventServer(path: socketPath) { [weak self] event in
            // The main queue keeps events in the order they arrived.
            DispatchQueue.main.async { self?.receive(event) }
        }
        do {
            try server.start()
            self.server = server
        } catch {
            serverFailed = true
        }
        ticker = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    var shouldShowWelcome: Bool { !everConnected && !welcomeDismissed }

    func receive(_ event: HookEvent, at now: Date = Date()) {
        if office.apply(event, now: now) { save() }
        receivedThisRun = true
        if !everConnected {
            everConnected = true
            defaults.set(true, forKey: Keys.everConnected)
        }
        if event.kind == .sessionStart, case .starting = startPhase, let start,
            OfficeState.isInside(event.cwd, start.resolved(home: Paths.home).folder)
        {
            startPhase = .idle
        }
    }

    private func tick() {
        office.endSessions { pid in kill(pid, 0) != 0 && errno == ESRCH }
        if case .starting(let since) = startPhase, Date().timeIntervalSince(since) > 30 {
            startPhase = .nobodyCame
        }
    }

    func forgetEmptyDesks() {
        office.forgetEmptyDesks()
        save()
    }

    // MARK: start work

    /// The 출근 button. Runs the saved command only if the user approved exactly this folder and these arguments.
    func startWork(force: Bool = false) {
        guard let start else {
            sheet = .register
            return
        }
        let resolved = start.resolved(home: Paths.home)
        guard defaults.string(forKey: Keys.approved) == resolved.fingerprint else {
            sheet = .confirm(start)
            return
        }
        if !force, office.hasLiveSession(in: resolved.folder) {
            askAnother = true
            return
        }
        launch(resolved)
    }

    /// Called from the sheet after the user has seen the command in full.
    func approveAndStart(_ command: StartCommand) {
        start = command
        save()
        defaults.set(command.resolved(home: Paths.home).fingerprint, forKey: Keys.approved)
        sheet = nil
        launch(command.resolved(home: Paths.home))
    }

    func clearStart() {
        start = nil
        defaults.removeObject(forKey: Keys.approved)
        startPhase = .idle
        save()
    }

    private func launch(_ command: StartCommand) {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: command.folder, isDirectory: &isFolder), isFolder.boolValue else {
            startPhase = .failed(.folderMissing)
            return
        }
        startPhase = .starting(Date())
        let folder = configURL.deletingLastPathComponent()
        Launcher.run(command, scriptFolder: folder) { [weak self] error in
            guard let error else { return }
            let firstLine = error.localizedDescription.split(separator: "\n").first.map(String.init) ?? ""
            self?.startPhase = .failed(.other(firstLine))
        }
    }

    // MARK: storage (folder 0700, file 0600; only desks and the start command)

    private func save() {
        let stored = Stored(start: start, desks: office.folders)
        guard let data = try? JSONEncoder.pretty.encode(stored) else { return }
        do {
            try data.write(to: configURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        } catch {
            // Saving is best effort: the office still works from memory.
        }
    }
}

extension JSONEncoder {
    fileprivate static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
