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
        /// Names given in the side panel. Only here: never on the socket, in a log or in a notification.
        var nicknames: Nicknames?

        init(start: StartCommand? = nil, desks: [String] = [], nicknames: Nicknames? = nil) {
            self.start = start
            self.desks = desks
            self.nicknames = nicknames
        }

        /// A nicknames entry the app can't read loses only the nicknames, not the start command and folders.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            start = try container.decodeIfPresent(StartCommand.self, forKey: .start)
            desks = try container.decodeIfPresent([String].self, forKey: .desks) ?? []
            nicknames = try? container.decodeIfPresent(Nicknames.self, forKey: .nicknames)
        }
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
    /// Show Details. The helper reads this same value and sends no details while it is off; the app drops any that
    /// come anyway.
    @Published var showsDetails: Bool {
        didSet {
            defaults.set(showsDetails, forKey: ShowDetails.key)
            if !showsDetails { office.forgetDetails() }
        }
    }

    let location: AppLocation
    let socketPath: String
    private let configURL: URL
    private let defaults: UserDefaults
    private var server: EventServer?
    private var ticker: Timer?
    private var meetingTimer: Timer?
    private var hasLooked = false
    private var finder = SessionFinder()
    /// Find sessions without the plugin (Settings > Connection). Off, it stops looking and those only found leave;
    /// on again, those found sit down as already there.
    @Published var findsSessions: Bool {
        didSet {
            defaults.set(findsSessions, forKey: Keys.findsSessions)
            if findsSessions {
                hasLooked = false
                lookForSessions()
            } else {
                office.forgetFound()
            }
        }
    }

    /// The office's zoom step (View > Zoom In, Zoom Out, Actual Size; a pinch settles on one), kept for next time.
    @Published var zoom: Double {
        didSet { defaults.set(Zoom.percent(zoom), forKey: Keys.zoom) }
    }

    func zoomIn() { zoom = Zoom.step(from: zoom, by: 1) ?? zoom }
    func zoomOut() { zoom = Zoom.step(from: zoom, by: -1) ?? zoom }

    /// New versions. Check for Updates (Settings > Updates) is on by default; off, nothing is ever asked.
    @Published private(set) var updates: UpdateState
    private let askLatest: @Sendable (ReleaseVersion) async -> UpdateCheck.Outcome
    private var updateTask: Task<Void, Never>?
    private var installTask: Task<Void, Never>?
    private let route: UpdateRoute
    /// The version this run updated to, until the office bar's line is closed.
    @Published var justUpdated: ReleaseVersion?

    var updatesWithHomebrew: Bool {
        if case .homebrew = route { return true }
        return false
    }

    /// False where the app can't update itself: the buttons offer the download page from the start.
    var canUpdateHere: Bool {
        if case .page = route { return false }
        return true
    }

    var checksForUpdates: Bool {
        get { updates.isOn }
        set {
            defaults.set(newValue, forKey: Keys.checksForUpdates)
            if !newValue { updateTask?.cancel() }
            updates.turn(on: newValue)
            askForUpdate()
        }
    }

    private enum Keys {
        static let approved = "approvedStartFingerprint"
        static let everConnected = "everConnected"
        static let welcomeDismissed = "welcomeDismissed"
        static let findsSessions = "findsSessions"
        static let zoom = "zoom"
        static let checksForUpdates = "checksForUpdates"
        static let lastUpdateCheck = "lastUpdateCheck"
        static let lastRunVersion = "lastRunVersion"
    }

    static let hooksURL = URL(
        string: "https://github.com/\(Release.repository)/blob/\(Release.tag)/plugin/hooks/hooks.json")!
    static let creditsURL = URL(
        string: "https://github.com/\(Release.repository)/blob/\(Release.tag)/App/Art/CREDITS.txt")!
    static let repositoryURL = URL(string: "https://github.com/\(Release.repository)")!

    init(
        supportFolder: String, socketPath: String, defaults: UserDefaults, bundlePath: String = Bundle.main.bundlePath,
        askLatest: @escaping @Sendable (ReleaseVersion) async -> UpdateCheck.Outcome = {
            await UpdateCheck.ask(current: $0)
        },
        route: UpdateRoute = .page
    ) {
        self.socketPath = socketPath
        self.defaults = defaults
        self.askLatest = askLatest
        self.route = route
        configURL = URL(fileURLWithPath: supportFolder).appendingPathComponent("config.json")
        location = AppLocation.check(bundlePath: bundlePath, home: Paths.home)
        everConnected = defaults.bool(forKey: Keys.everConnected)
        welcomeDismissed = defaults.bool(forKey: Keys.welcomeDismissed)
        // On by default, written out so the helper, which takes only an explicit true, sees it.
        if defaults.object(forKey: ShowDetails.key) == nil { defaults.set(true, forKey: ShowDetails.key) }
        showsDetails = defaults.bool(forKey: ShowDetails.key)
        findsSessions = defaults.object(forKey: Keys.findsSessions) as? Bool ?? true
        zoom = Zoom.stored(defaults.object(forKey: Keys.zoom))
        updates = UpdateState(
            isOn: defaults.object(forKey: Keys.checksForUpdates) as? Bool ?? true,
            lastChecked: defaults.object(forKey: Keys.lastUpdateCheck) as? Date)

        if let running = ReleaseVersion(tag: Release.tag) {
            let last = defaults.string(forKey: Keys.lastRunVersion).flatMap { ReleaseVersion(tag: $0) }
            // No number yet but connected before: updated by hand from a version that didn't keep one.
            let connectedBefore = defaults.bool(forKey: Keys.everConnected)
            if let last, last < running { justUpdated = running }
            if last == nil, connectedBefore { justUpdated = running }
            defaults.set(running.tag, forKey: Keys.lastRunVersion)
        }

        try? EventServer.prepareFolder(supportFolder)
        let stored =
            (try? Data(contentsOf: configURL)).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? Stored()
        office = OfficeState(folders: stored.desks, nicknames: stored.nicknames ?? Nicknames())
        start = stored.start
    }

    /// The real app: Application Support. Under XCTest: a throwaway folder, so tests never touch the user's data.
    static func forThisProcess() -> AppModel {
        let model: AppModel
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            let folder = (Paths.userTempFolder as NSString).appendingPathComponent("ao-test-\(getpid())")
            let defaults = UserDefaults(suiteName: "AgentOvertimeTests-\(getpid())")!
            // Tests send their own made-up sessions; this Mac's real ones stay out.
            defaults.set(false, forKey: Keys.findsSessions)
            model = AppModel(
                supportFolder: folder, socketPath: folder + "/events.sock", defaults: defaults,
                askLatest: { _ in .failed })
        } else {
            let bundlePath = Bundle.main.bundlePath
            let support = Paths.supportFolder()
            let socket = Paths.socket()
            let location = AppLocation.check(bundlePath: bundlePath, home: Paths.home)
            let route: UpdateRoute
            if HomebrewUpdate.manages(location: location) {
                route = .homebrew(.live(bundlePath: bundlePath, scriptFolder: URL(fileURLWithPath: support)))
            } else if let place = AppPlace(bundlePath: bundlePath, location: location) {
                route = .selfUpdate(.live(SelfUpdate(place: place), socketPath: socket))
            } else {
                route = .page
            }
            model = AppModel(supportFolder: support, socketPath: socket, defaults: .standard, route: route)
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
            // Listening proves this app runs, so what an update left beside it can go.
            if case .selfUpdate(let selfUpdate) = route { selfUpdate.removeCopy() }
        } catch {
            serverFailed = true
        }
        ticker = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // Right away, so sessions already running show within the first seconds; then on the 5 s tick only.
        lookForSessions()
        askForUpdate()
    }

    /// One look at this Mac's Claude Code processes, on the 5 s tick (never more often, window shown or not).
    func lookForSessions() {
        guard findsSessions, ticker != nil else { return }
        receive(found: finder.look())
    }

    /// One question to GitHub when one is due, from the app opening, the 5 s tick or the Settings switch. Only while
    /// listening: models made by tests never reach the network.
    func askForUpdate(at now: Date = Date()) {
        // Assign only when one goes out: every assignment redraws everything that watches the model.
        var asking = updates
        guard ticker != nil, let current = ReleaseVersion(tag: Release.tag), asking.begin(at: now) else { return }
        updates = asking
        updateTask = Task { [askLatest] in
            let outcome = await askLatest(current)
            if !Task.isCancelled { receive(update: outcome) }
        }
    }

    func receive(update outcome: UpdateCheck.Outcome, at now: Date = Date()) {
        updates.finish(outcome, at: now)
        defaults.set(updates.lastChecked, forKey: Keys.lastUpdateCheck)
    }

    /// What's New, and Update where the app can't update itself: the release's page in the browser.
    func openRelease(_ version: ReleaseVersion) {
        NSWorkspace.shared.open(UpdateCheck.releaseURL(version))
    }

    func openRepository() {
        NSWorkspace.shared.open(Self.repositoryURL)
    }

    /// The Update button. Only a person's press starts this, and only once at a time.
    func startUpdate(_ version: ReleaseVersion) {
        guard let current = ReleaseVersion(tag: Release.tag) else {
            openRelease(version)
            return
        }
        switch route {
        case .page:
            openRelease(version)
        case .homebrew(let homebrew):
            startInTerminal(homebrew, current: current)
        case .selfUpdate(let selfUpdate):
            guard updates.beginDownload() else { return }
            Self.announce(String(localized: "Downloading the new version…"))
            installTask = Task {
                let failure = await install(version, current: current, with: selfUpdate)
                updates.endDownload(failure)
                if let failure { Self.announce(failure.spoken) }
            }
        }
    }

    /// Asks GitHub again first: a line that stayed up is no permission to install a release since withdrawn. Then the
    /// order that keeps a working app at the path: swap, let go of the socket, open the new app, and only when it has
    /// taken the socket delete the old one and quit. If it never does, the old app comes back.
    private func install(
        _ version: ReleaseVersion, current: ReleaseVersion, with selfUpdate: SelfUpdateRoute
    ) async -> UpdateFailure? {
        let answer = await askLatest(current)
        guard answer != .failed else { return .network }
        guard case .newer(let latest) = answer, latest >= version else {
            receive(update: answer)
            return nil
        }
        receive(update: answer)
        if let failure = await selfUpdate.prepare(latest, current) { return failure }

        save()
        guard selfUpdate.swap() else {
            selfUpdate.removeCopy()
            return .install
        }
        server?.stop()
        var opened: NSRunningApplication?
        var couldNotOpen = false
        var gaveUp = false
        selfUpdate.open { [weak self] app in
            opened = app
            couldNotOpen = app == nil
            // macOS answered after the wait ended. The app it opened may have taken the socket from this one.
            if gaveUp, let app {
                selfUpdate.stopNewApp(app)
                self?.server?.stop()
                try? self?.server?.start()
            }
        }
        let deadline = Date() + selfUpdate.patience
        while Date() < deadline, !couldNotOpen {
            if selfUpdate.isListening() {
                selfUpdate.removeCopy()
                selfUpdate.quit()
                return nil
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        gaveUp = true
        if let opened { selfUpdate.stopNewApp(opened) }
        // If this fails the new app stays at the path and the old one beside it: the next launch sorts that out.
        if selfUpdate.swap() { selfUpdate.removeCopy() }
        try? server?.start()
        return .install
    }

    private func startInTerminal(_ homebrew: HomebrewRoute, current: ReleaseVersion) {
        guard !updates.isInTerminal else { return }
        // Already on disk: brew finished after the wait for it ended.
        if let installed = homebrew.installedVersion(), installed > current {
            reopen(homebrew)
            return
        }
        guard updates.beginTerminal(at: Date()) else { return }
        Self.announce(String(localized: "Updating in Terminal…"))
        homebrew.openTerminal { [weak self] error in
            if error != nil { self?.updates.endTerminal() }
        }
    }

    /// On the 5 s tick while Terminal runs: brew leaves this process running with the new app on disk.
    func followUpdate(at now: Date = Date()) {
        guard updates.isInTerminal, case .homebrew(let homebrew) = route,
            let current = ReleaseVersion(tag: Release.tag)
        else { return }
        var followed = updates
        let isReady = followed.follow(installed: homebrew.installedVersion(), current: current, at: now)
        if followed != updates { updates = followed }
        if isReady { reopen(homebrew) }
    }

    /// The socket goes first: stopping unlinks the path, which after the new app opened would be the new app's. The
    /// new app may be blocked by macOS; this one quits anyway (the Terminal window says what to do), because with it
    /// running at that path, allowing the new app could only bring this one forward.
    private func reopen(_ homebrew: HomebrewRoute) {
        save()
        server?.stop()
        if !homebrew.reopen() {
            try? server?.start()
            updates.endTerminal()
        }
    }

    var shouldShowWelcome: Bool { !everConnected && !welcomeDismissed }

    /// People found on this Mac, but never any news: the plugin isn't connected yet, so the office bar says what
    /// connecting adds.
    var asksToConnect: Bool { !everConnected && office.liveSessionCount > 0 }

    func receive(_ event: HookEvent, at now: Date = Date()) {
        if office.apply(showsDetails ? event : event.withoutDetails, now: now) { save() }
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

    /// A look at the Claude Code processes running on this Mac. The first one after the app opened finds people
    /// already at work, who sit down without walking in. Nothing found this way is saved.
    func receive(found: [OfficeState.Found], at now: Date = Date()) {
        var looked = office
        looked.detect(found, now: now, opening: !hasLooked)
        hasLooked = true
        if looked != office {
            office = looked
            bookMeeting()
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
        lookForSessions()
        askForUpdate()
        followUpdate()
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

    /// Gives whoever the panel shows a nickname: all sessions of that folder, or all teammates of that name. Empty
    /// takes it away. The new name shown, or nil when refused.
    func rename(_ kind: PanelSelection.Kind, to text: String) -> String? {
        var renamed = office
        switch kind {
        case .session(let id):
            guard let folder = office.folder(ofSession: id), renamed.rename(folder: folder, to: text) else {
                return nil
            }
            office = renamed
            save()
            return office.session(id)?.label
        case .teammate(let id):
            guard let mate = office.teammate(id)?.teammate, renamed.rename(agent: mate.name, to: text) else {
                return nil
            }
            office = renamed
            save()
            return office.teammate(id)?.teammate.label
        }
    }

    func forgetIdleFolders() {
        office.forgetIdleFolders()
        save()
    }

    func forgetNicknames() {
        office.forgetNicknames()
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
    static func announce(_ text: String) {
        guard let app = NSApp else { return }
        NSAccessibility.post(
            element: app, notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    // MARK: storage (folder 0700, file 0600; only desks, the start command and nicknames)

    private func save() {
        let stored = Stored(start: start, desks: office.folders, nicknames: office.nicknames)
        guard let data = try? JSONEncoder.pretty.encode(stored) else { return }
        do {
            try data.write(to: configURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        } catch {
            // Saving is best effort: the office still works from memory.
        }
    }
}

extension UpdateFailure {
    /// What VoiceOver reads when the office bar shows this failure (same keys as UpdateFailureLine).
    var spoken: String {
        switch self {
        case .network:
            return String(localized: "Couldn't update. This app is unchanged. Please check your internet connection.")
        case .install:
            return String(
                localized: "Couldn't update. This app is unchanged. The new version couldn't be put in place.")
        case .unverified:
            return String(
                localized: "This version couldn't be verified, so it wasn't installed. Check the repository for news.")
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
