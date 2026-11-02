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

        /// What VoiceOver reads when the office bar shows this phase (same keys as OfficeBar).
        var announcement: String? {
            switch self {
            case .failed(.folderMissing): return String(localized: "Couldn't start: the folder is missing")
            case .failed(.other(let line)): return String(localized: "Couldn't start: \(line)")
            case .nobodyCame: return String(localized: "The command ran, but nobody came to the office")
            case .idle, .starting: return nil
            }
        }
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
    @Published var startPhase: StartPhase = .idle {
        didSet { if startPhase != oldValue, let text = startPhase.announcement { Self.announce(text) } }
    }
    @Published var sheet: Sheet?
    @Published var askAnother = false {
        didSet {
            if askAnother, !oldValue { Self.announce(String(localized: "You're already at work. Start one more?")) }
        }
    }
    @Published var welcomeDismissed: Bool {
        didSet { defaults.set(welcomeDismissed, forKey: Keys.welcomeDismissed) }
    }

    let location: AppLocation
    let socketPath: String
    private let configURL: URL
    private let defaults: UserDefaults
    private var server: EventServer?
    private var ticker: Timer?
    private var meetingTimer: Timer?

    private enum Keys {
        static let approved = "approvedStartFingerprint"
        static let everConnected = "everConnected"
        static let welcomeDismissed = "welcomeDismissed"
    }

    static let hooksURL = URL(
        string: "https://github.com/\(Release.repository)/blob/\(Release.tag)/plugin/hooks/hooks.json")!
    static let creditsURL = URL(
        string: "https://github.com/\(Release.repository)/blob/\(Release.tag)/App/Art/CREDITS.txt")!
    static let repositoryURL = URL(string: "https://github.com/\(Release.repository)")!

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
        bookMeeting()
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
        // Assign only on a change: every assignment redraws everything that watches the office.
        var checked = office
        checked.endSessions { pid in kill(pid, 0) != 0 && errno == ESRCH }
        if checked != office {
            office = checked
            bookMeeting()
        }
        if case .starting(let since) = startPhase, Date().timeIntervalSince(since) > 30 {
            startPhase = .nobodyCame
        }
    }

    /// Starts the meetings that are due at `now` (the screenshot tests pass their own clock).
    func advanceMeetings(to now: Date = Date()) {
        var advanced = office
        advanced.advance(to: now)
        if advanced != office { office = advanced }
        bookMeeting()
    }

    /// Wakes up when the next meeting is due. Only while listening: tests move their own clock.
    private func bookMeeting() {
        meetingTimer?.invalidate()
        meetingTimer = nil
        guard ticker != nil, let next = office.nextMeeting else { return }
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.advanceMeetings() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        meetingTimer = timer
    }

    func forgetIdleFolders() {
        office.forgetIdleFolders()
        save()
    }

    // MARK: start work

    /// The 출근 button. Runs the saved command only if the user approved exactly this folder and these arguments.
    func startWork(force: Bool = false) {
        // Until the new session arrives (or 30 s pass) a second press would open a second Terminal window.
        if case .starting = startPhase { return }
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

    /// The bar's question and errors appear without moving focus, so VoiceOver would not read them on its own.
    private static func announce(_ text: String) {
        guard let app = NSApp else { return }
        NSAccessibility.post(
            element: app, notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
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
