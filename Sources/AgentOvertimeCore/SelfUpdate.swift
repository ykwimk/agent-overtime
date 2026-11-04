import CryptoKit
import Foundation

/// Why Update stopped. What the user can do differs, so the words differ.
public enum UpdateFailure: Error, Equatable, Sendable {
    /// The files didn't arrive: trying again or fetching them by hand makes sense.
    case network
    /// The files arrived but didn't prove themselves. The release itself is in doubt: no retry, no download page.
    case unverified
    /// The new version is fine but couldn't be put in place.
    case install
}

/// A release's proof of origin. The private key isn't on GitHub, so a release changed through a stolen account fails
/// here, while a checksum from the same release would pass. The app hashes the file itself and checks this signature
/// before the disk image is opened.
public enum ReleaseSignature {
    /// The one key a release build trusts: Ed25519, 32 bytes.
    static let publicKey = "y54ntziWI+1og7T6drvVMMSyX8xRAX59vHg101T5bqk="
    private static let signatureSize = 64

    /// What is signed: one line of UTF-8 with no line break, tying the file to its version.
    static func line(_ version: ReleaseVersion, sha256: String) -> String {
        "agent-overtime \(version.number) \(sha256)"
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func isValid(signature: Data, of file: URL, version: ReleaseVersion, publicKey: Data) -> Bool {
        guard signature.count == signatureSize,
            let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
            let hash = try? sha256(of: file)
        else { return false }
        return key.isValidSignature(signature, for: Data(line(version, sha256: hash).utf8))
    }
}

/// Where this app sits, once proven safe to replace: a real folder this user owns, in a folder this user can write,
/// reached by no symbolic link. Only `AppLocation.ok` places, the two paths the plugin's hooks call.
public struct AppPlace: Equatable, Sendable {
    /// Beside the app, so the swap is a rename on one volume. The one name this feature ever deletes.
    static let copyName = ".AgentOvertime-update.app"

    public let bundle: String
    public let copy: String

    public init?(bundlePath: String, location: AppLocation) {
        guard location == .ok else { return nil }
        self.init(checking: bundlePath)
    }

    init?(checking bundlePath: String) {
        let folder = (bundlePath as NSString).deletingLastPathComponent
        var info = stat()
        guard lstat(bundlePath, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
            let resolved = realpath(folder, nil)
        else { return nil }
        defer { free(resolved) }
        guard String(cString: resolved) == folder, access(folder, W_OK) == 0 else { return nil }
        bundle = bundlePath
        copy = (folder as NSString).appendingPathComponent(Self.copyName)
    }

    /// Trades the copy and the app in one call: the app's path is never empty, and the same call undoes it. What was
    /// true at launch is checked again here.
    public func swap() -> Bool {
        guard AppPlace(checking: bundle) == self else { return false }
        return renamex_np(copy, bundle, UInt32(RENAME_SWAP | RENAME_NOFOLLOW_ANY)) == 0
    }

    /// Only ever this name, and only a real folder of this user's: also what the next launch clears away.
    public func removeCopy() {
        var info = stat()
        guard lstat(copy, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { return }
        try? FileManager.default.removeItem(atPath: copy)
    }
}

/// Everything before the swap: the two files, the signature, the disk image, and a checked copy beside the app. Nothing
/// inside the disk image ever runs: the new app's Info.plist is read as a file.
public struct SelfUpdate: Sendable {
    private static let identifier = "io.github.ykwimk.AgentOvertime"
    private static let toolLimit: TimeInterval = 60

    public let place: AppPlace
    private let publicKey: Data
    private let tempRoot: String
    private let configuration: UpdateCheck.Settings

    public init(place: AppPlace) {
        self.init(
            place: place, publicKey: Data(base64Encoded: ReleaseSignature.publicKey)!, tempRoot: Paths.userTempFolder,
            configuration: { UpdateCheck.downloadConfiguration })
    }

    init(place: AppPlace, publicKey: Data, tempRoot: String, configuration: @escaping UpdateCheck.Settings) {
        self.place = place
        self.publicKey = publicKey
        self.tempRoot = tempRoot
        self.configuration = configuration
    }

    /// nil when the copy is ready for `place.swap()`. On failure the app, its folder and the temporary folder are as
    /// they were.
    public func prepare(_ version: ReleaseVersion, current: ReleaseVersion) async -> UpdateFailure? {
        var template = Array((tempRoot as NSString).appendingPathComponent("AgentOvertime-update-XXXXXX").utf8CString)
        // Resolved: the temporary folder's usual path goes through a link, and the system names mount points without it.
        guard mkdtemp(&template) != nil, let resolved = realpath(template, nil) else { return .install }
        defer { free(resolved) }
        let temp = String(cString: resolved)
        let mountPoint = temp + "/m"

        var failure: UpdateFailure?
        do {
            try await fetchAndVerify(version, current: current, into: temp)
            try await copyApp(from: temp + "/update.dmg", mountPoint: mountPoint)
        } catch {
            failure = error as? UpdateFailure ?? .install
        }

        // Never delete under a mounted image: if it stays mounted the folder stays too.
        if Self.isMounted(mountPoint) {
            if !(await Self.tool("/usr/bin/hdiutil", ["detach", mountPoint])) {
                _ = await Self.tool("/usr/bin/hdiutil", ["detach", mountPoint, "-force"])
            }
        }
        if Self.isMounted(mountPoint) {
            failure = failure ?? .install
        } else {
            try? FileManager.default.removeItem(atPath: temp)
        }

        if failure == nil, !(await isGood(version: version, current: current)) { failure = .unverified }
        if failure != nil { place.removeCopy() }
        return failure
    }

    private func fetchAndVerify(_ version: ReleaseVersion, current: ReleaseVersion, into temp: String) async throws {
        let signature = URL(fileURLWithPath: temp + "/update.sig")
        let dmg = URL(fileURLWithPath: temp + "/update.dmg")
        // The small file first: a release without one isn't worth fetching.
        try await fetch(
            UpdateCheck.assetURL(version, signature: true), to: signature, limit: UpdateCheck.maxSignature,
            current: current, missingIsDoubtful: true)
        try await fetch(
            UpdateCheck.assetURL(version, signature: false), to: dmg, limit: UpdateCheck.maxDMG, current: current,
            missingIsDoubtful: false)
        guard let proof = try? Data(contentsOf: signature),
            ReleaseSignature.isValid(signature: proof, of: dmg, version: version, publicKey: publicKey)
        else { throw UpdateFailure.unverified }
    }

    private func fetch(
        _ url: URL, to file: URL, limit: Int64, current: ReleaseVersion, missingIsDoubtful: Bool
    ) async throws {
        do {
            try await UpdateCheck.download(
                url, to: file, limit: limit, current: current, configuration: configuration())
        } catch let failure as UpdateCheck.DownloadFailure {
            switch failure {
            case .tooLong: throw UpdateFailure.unverified
            case .status(300..<400): throw UpdateFailure.unverified
            case .status(404) where missingIsDoubtful: throw UpdateFailure.unverified
            case .status, .connection: throw UpdateFailure.network
            case .file: throw UpdateFailure.install
            }
        }
    }

    private func copyApp(from dmg: String, mountPoint: String) async throws {
        guard
            await Self.tool(
                "/usr/bin/hdiutil", ["attach", dmg, "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mountPoint])
        else { throw UpdateFailure.install }
        guard let app = Self.onlyApp(in: mountPoint) else { throw UpdateFailure.unverified }
        place.removeCopy()
        do {
            try FileManager.default.copyItem(atPath: app, toPath: place.copy)
        } catch {
            throw UpdateFailure.install
        }
    }

    /// The image holds one app: besides hidden files, one real folder of the right name, and no link.
    private static func onlyApp(in mountPoint: String) -> String? {
        let name = Paths.appName + ".app"
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: mountPoint) else { return nil }
        let path = (mountPoint as NSString).appendingPathComponent(name)
        var info = stat()
        guard items.filter({ !$0.hasPrefix(".") }) == [name], lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR
        else { return nil }
        return path
    }

    /// Checked on the copy that will be swapped in, not on the image: these catch a broken package. Who made it is the
    /// signature's job.
    private func isGood(version: ReleaseVersion, current: ReleaseVersion) async -> Bool {
        let copy = place.copy
        guard let data = FileManager.default.contents(atPath: copy + "/Contents/Info.plist"),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            plist["CFBundleIdentifier"] as? String == Self.identifier,
            plist["CFBundleExecutable"] as? String == Paths.appName,
            let number = plist["CFBundleShortVersionString"] as? String, ReleaseVersion(tag: "v" + number) == version,
            version > current,
            let minimum = plist["LSMinimumSystemVersion"] as? String, Self.runsHere(minimum),
            Self.isProgram(copy + "/Contents/MacOS/" + Paths.appName),
            Self.isProgram(copy + "/Contents/MacOS/" + Paths.helperName)
        else { return false }
        return await Self.tool("/usr/bin/codesign", ["--verify", "--deep", "--strict", copy])
    }

    private static func runsHere(_ minimum: String) -> Bool {
        let parts = minimum.split(separator: ".").map { Int($0) }
        guard (1...3).contains(parts.count), !parts.contains(nil) else { return false }
        let numbers = parts.compactMap { $0 } + [0, 0]
        return ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: numbers[0], minorVersion: numbers[1], patchVersion: numbers[2]))
    }

    private static func isProgram(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_mode & S_IXUSR != 0
    }

    private static func isMounted(_ path: String) -> Bool {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return false }
        let mountedOn = withUnsafeBytes(of: info.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return mountedOn == path
    }

    /// A system tool by absolute path, with arguments as an array, nothing on stdin and a time limit.
    private static func tool(_ path: String, _ arguments: [String]) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = {
                continuation.resume(returning: $0.terminationReason == .exit && $0.terminationStatus == 0)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: false)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + toolLimit) {
                if process.isRunning { process.terminate() }
            }
        }
    }
}
