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

/// The app's only network request: one GET asking GitHub for the latest release, of which only the tag is read.
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

    /// The release's page. A link built from checked numbers, so nothing received ends up in a URL.
    public static func releaseURL(_ version: ReleaseVersion) -> URL {
        URL(string: "https://github.com/\(Release.repository)/releases/tag/\(version.tag)")!
    }

    static func request(current: ReleaseVersion) -> URLRequest {
        var request = URLRequest(url: latest)
        request.httpShouldHandleCookies = false
        request.setValue("\(Paths.appName)/\(current.number)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
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

    public private(set) var isOn: Bool
    /// This run's last answer: nil until there is one.
    public private(set) var result: Result?
    /// When GitHub last answered, kept between runs.
    public private(set) var lastChecked: Date?
    private var lastTry: Date?
    private var isAsking = false

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
        if !on, isAsking {
            isAsking = false
            lastTry = nil
        }
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
            result = .available(version)
            lastChecked = now
        case .upToDate:
            result = .upToDate
            lastChecked = now
        case .failed:
            if newVersion == nil { result = .failed }
        }
    }
}
