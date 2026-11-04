import Foundation

/// A release number from a tag: `v` and three plain numbers of one to four ASCII digits, no leading zeros. Anything
/// else is refused, and links and screen text are built from these numbers, never from the text received.
public struct ReleaseVersion: Comparable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init?(tag: String) {
        let bytes = Array(tag.utf8)
        guard bytes.first == UInt8(ascii: "v") else { return nil }
        let parts = bytes.dropFirst().split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
        let numbers = parts.compactMap(Self.number)
        guard parts.count == 3, numbers.count == 3 else { return nil }
        (major, minor, patch) = (numbers[0], numbers[1], numbers[2])
    }

    private static func number(_ digits: ArraySlice<UInt8>) -> Int? {
        let zero = UInt8(ascii: "0")
        guard (1...4).contains(digits.count), digits.allSatisfy({ (zero...UInt8(ascii: "9")).contains($0) }),
            digits.first != zero || digits.count == 1
        else { return nil }
        return digits.reduce(0) { $0 * 10 + Int($1 - zero) }
    }

    public var number: String { "\(major).\(minor).\(patch)" }
    public var tag: String { "v\(number)" }

    public static func < (a: ReleaseVersion, b: ReleaseVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }
}

/// The app's network use, all here: one GET asking GitHub for the latest release, of which only the tag is read, and,
/// after a press of Update, the release's two files.
public enum UpdateCheck {
    public enum Outcome: Equatable, Sendable {
        case newer(ReleaseVersion)
        case upToDate
        /// Offline, rate limited, too long or an answer this app can't read. Never shown as an error.
        case failed
    }

    private struct Latest: Decodable {
        let tag: String

        enum CodingKeys: String, CodingKey {
            case tag = "tag_name"
        }
    }

    static let latest = URL(string: "https://api.github.com/repos/\(Release.repository)/releases/latest")!
    static let maxResponse = 1 << 20
    static let maxDMG: Int64 = 64 << 20
    static let maxSignature: Int64 = 1 << 10

    /// The release's page. A link built from checked numbers, so nothing received ends up in a URL.
    public static func releaseURL(_ version: ReleaseVersion) -> URL {
        URL(string: "https://github.com/\(Release.repository)/releases/tag/\(version.tag)")!
    }

    /// The release's `.dmg`, or its `.sig`. Built from checked numbers too.
    static func assetURL(_ version: ReleaseVersion, signature: Bool) -> URL {
        let file = "AgentOvertime-\(version.number).dmg" + (signature ? ".sig" : "")
        return URL(string: "https://github.com/\(Release.repository)/releases/download/\(version.tag)/\(file)")!
    }

    static func request(_ url: URL = latest, current: ReleaseVersion) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.setValue("\(Paths.appName)/\(current.number)", forHTTPHeaderField: "User-Agent")
        request.setValue(url == latest ? "application/vnd.github+json" : "*/*", forHTTPHeaderField: "Accept")
        // Fixed: URLSession would otherwise send the user's languages.
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        return request
    }

    /// Nothing kept between requests: no cache, cookies or credentials, and no waiting for a connection.
    static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return configuration
    }

    /// What SelfUpdate is given, so that the session stays in this file.
    typealias Settings = @Sendable () -> URLSessionConfiguration

    /// The same, with the five minutes a whole file may take.
    static var downloadConfiguration: URLSessionConfiguration {
        let configuration = configuration
        configuration.timeoutIntervalForResource = 300
        return configuration
    }

    static func outcome(status: Int, body: Data, current: ReleaseVersion) -> Outcome {
        guard status == 200, let latest = try? JSONDecoder().decode(Latest.self, from: body),
            let version = ReleaseVersion(tag: latest.tag)
        else { return .failed }
        return version > current ? .newer(version) : .upToDate
    }

    public static func ask(current: ReleaseVersion) async -> Outcome {
        await ask(current: current, configuration: configuration)
    }

    static func ask(current: ReleaseVersion, configuration: URLSessionConfiguration) async -> Outcome {
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request(current: current))
            guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else { return .failed }
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count > maxResponse { return .failed }
            }
            return outcome(status: status, body: body, current: current)
        } catch {
            return .failed
        }
    }

    enum DownloadFailure: Error, Equatable {
        case connection
        case status(Int)
        case tooLong
        case file
    }

    /// GitHub sends a release's files on to its own storage: https, those hosts and three hops only.
    static func allowsRedirect(to url: URL?, after hops: Int) -> Bool {
        guard hops <= 3, let url, url.scheme == "https", url.port == nil, url.user == nil,
            let host = url.host?.lowercased()
        else { return false }
        return host == "github.com" || host.hasSuffix(".githubusercontent.com")
    }

    /// Fetches one file to `file`, moved there as soon as it lands.
    static func download(
        _ url: URL, to file: URL, limit: Int64, current: ReleaseVersion, configuration: URLSessionConfiguration
    ) async throws {
        let download = Download(to: file, limit: limit)
        let session = URLSession(configuration: configuration, delegate: download, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            download.continuation = continuation
            session.downloadTask(with: request(url, current: current)).resume()
        }
    }
}

/// One file on its way. Its size is counted from the progress callback, and once more when it lands.
final class Download: NSObject, URLSessionDownloadDelegate {
    var continuation: CheckedContinuation<Void, Error>?
    private let file: URL
    private let limit: Int64
    private var failure: UpdateCheck.DownloadFailure?
    private var landed = false
    private var hops = 0

    init(to file: URL, limit: Int64) {
        self.file = file
        self.limit = limit
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        if max(totalBytesWritten, totalBytesExpectedToWrite) > limit {
            failure = .tooLong
            downloadTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            failure = .status(status)
            return
        }
        do {
            let size = try FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber
            guard let size, size.int64Value <= limit else {
                failure = .tooLong
                return
            }
            try FileManager.default.moveItem(at: location, to: file)
            landed = true
        } catch {
            failure = .file
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if landed, failure == nil {
            continuation?.resume()
        } else {
            continuation?.resume(throwing: failure ?? .connection)
        }
        continuation = nil
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        hops += 1
        completionHandler(UpdateCheck.allowsRedirect(to: request.url, after: hops) ? request : nil)
    }
}

/// The API answers from where it was asked: a redirect ends the check.
final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? { nil }
}

/// When to ask and what the last answer was, apart from the app so tests can drive the clock. Asked on the app's 5 s
/// tick, it only compares times: it asks once when the app opens, then 24 hours after the last try, so a Mac that
/// slept through it asks when it wakes. A failed try waits like any other: no retries.
public struct UpdateState: Equatable {
    public enum Result: Equatable {
        case upToDate
        case available(ReleaseVersion)
        case failed
    }

    static let interval: TimeInterval = 24 * 60 * 60
    /// How long Update stays in the Terminal state with nothing new on disk: it failed, or Terminal was closed.
    static let terminalWait: TimeInterval = 5 * 60

    public private(set) var isOn: Bool
    /// This run's last answer: nil until there is one.
    public private(set) var result: Result?
    /// When GitHub last answered, kept between runs.
    public private(set) var lastChecked: Date?
    private var lastTry: Date?
    private var isAsking = false
    private var terminalSince: Date?
    private var newerOnDisk = false
    private var failure: UpdateFailure?
    public private(set) var isDownloading = false

    public init(isOn: Bool, lastChecked: Date?, now: Date = Date()) {
        self.isOn = isOn
        self.lastChecked = lastChecked.flatMap { $0 > now ? nil : $0 }
    }

    /// The newer version to tell the user about.
    public var newVersion: ReleaseVersion? {
        guard isOn, case .available(let version) = result else { return nil }
        return version
    }

    /// Off also drops a try still on its way, so turning back on asks again.
    public mutating func turn(on: Bool) {
        isOn = on
        guard !on else { return }
        endTerminal()
        if isAsking {
            isAsking = false
            lastTry = nil
        }
    }

    public var isInTerminal: Bool { terminalSince != nil }
    public var shownFailure: UpdateFailure? { isOn ? failure : nil }

    /// A press of Update on the app's own way. False for a second press, and for a number refused this run.
    public mutating func beginDownload() -> Bool {
        guard newVersion != nil, !isDownloading, !isInTerminal, failure != .unverified else { return false }
        isDownloading = true
        failure = nil
        return true
    }

    public mutating func endDownload(_ failure: UpdateFailure?) {
        isDownloading = false
        self.failure = failure
    }

    /// A press of Update. False for a second press while one is running.
    public mutating func beginTerminal(at now: Date) -> Bool {
        guard newVersion != nil, terminalSince == nil else { return false }
        terminalSince = now
        newerOnDisk = false
        return true
    }

    public mutating func endTerminal() {
        terminalSince = nil
        newerOnDisk = false
    }

    /// On the tick while Terminal runs. True when the app should reopen: a newer app on disk on two ticks in a row,
    /// so brew has finished putting it there.
    public mutating func follow(installed: ReleaseVersion?, current: ReleaseVersion, at now: Date) -> Bool {
        guard let since = terminalSince else { return false }
        if let installed, installed > current {
            let settled = newerOnDisk
            newerOnDisk = true
            return settled
        }
        newerOnDisk = false
        let gone = now.timeIntervalSince(since)
        if gone >= Self.terminalWait || gone < 0 { terminalSince = nil }
        return false
    }

    /// True when a request should go out now, which counts as the try. Time that ran backwards counts as due.
    public mutating func begin(at now: Date) -> Bool {
        guard isOn, !isAsking else { return false }
        if let lastTry {
            let gone = now.timeIntervalSince(lastTry)
            guard gone >= Self.interval || gone < 0 else { return false }
        }
        isAsking = true
        lastTry = now
        return true
    }

    /// A failed try doesn't take back a new version already found: it is still out there.
    public mutating func finish(_ outcome: UpdateCheck.Outcome, at now: Date) {
        isAsking = false
        switch outcome {
        case .newer(let version):
            if result != .available(version) { failure = nil }
            result = .available(version)
            lastChecked = now
        case .upToDate:
            failure = nil
            result = .upToDate
            lastChecked = now
        case .failed:
            if newVersion == nil { result = .failed }
        }
    }
}
