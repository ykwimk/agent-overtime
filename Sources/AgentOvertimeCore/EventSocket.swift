import Foundation

/// Sends one event line to the app. Gives up quietly: the hook must never slow Claude Code down.
public enum EventClient {
    @discardableResult
    public static func send(_ line: Data, to path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        guard var address = UnixAddress(path) else { return false }
        guard address.withSockaddr({ connect(fd, $0, $1) }) == 0 else { return false }
        // One short line fits the socket buffer, so a single non-blocking write either goes or is dropped.
        return line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } == line.count
    }

    /// Whether an app is listening at `path`. Connecting and closing sends nothing, and the listener drops it.
    public static func isListening(at path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard var address = UnixAddress(path) else { return false }
        return address.withSockaddr({ connect(fd, $0, $1) }) == 0
    }
}

/// Listens on a unix socket that only this user can open, and hands each valid event to `onEvent`
/// on a background thread. Received lines only ever change the picture; nothing in them is executed.
public final class EventServer {
    public enum Failure: Error, Equatable {
        case folder(Int32)
        case notASocket
        case socket(Int32)
        case pathTooLong
    }

    public let path: String
    private let onEvent: (HookEvent) -> Void
    private var fd: Int32 = -1

    public init(path: String, onEvent: @escaping (HookEvent) -> Void) {
        self.path = path
        self.onEvent = onEvent
    }

    deinit { stop() }

    public func start() throws {
        guard var address = UnixAddress(path) else { throw Failure.pathTooLong }
        try Self.prepareFolder((path as NSString).deletingLastPathComponent)

        var info = stat()
        if lstat(path, &info) == 0 {
            // Only ever remove our own stale socket, never a file or link someone put there.
            guard info.st_mode & S_IFMT == S_IFSOCK else { throw Failure.notASocket }
            unlink(path)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.socket(errno) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let oldMask = umask(0o077)
        let bound = address.withSockaddr { bind(fd, $0, $1) }
        umask(oldMask)
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
            let error = errno
            close(fd)
            throw Failure.socket(error)
        }
        self.fd = fd
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "AgentOvertime.events"
        thread.start()
    }

    public func stop() {
        guard fd >= 0 else { return }
        close(fd)
        fd = -1
        var info = stat()
        if lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK { unlink(path) }
    }

    /// Makes the folder 0700 and checks it is a real folder owned by this user.
    static func prepareFolder(_ folder: String) throws {
        if mkdir(folder, 0o700) != 0, errno != EEXIST { throw Failure.folder(errno) }
        var info = stat()
        guard lstat(folder, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            throw Failure.folder(EPERM)
        }
        guard chmod(folder, 0o700) == 0 else { throw Failure.folder(errno) }
    }

    private func acceptLoop(_ listener: Int32) {
        while true {
            let connection = accept(listener, nil, nil)
            if connection < 0 {
                if errno == EINTR { continue }
                return  // listener closed by stop()
            }
            if let event = Self.readEvent(connection) { onEvent(event) }
            close(connection)
        }
    }

    private static func readEvent(_ connection: Int32) -> HookEvent? {
        // LOCAL_PEERCRED: the 0600 file already blocks other users; this checks again per connection.
        var cred = xucred()
        var size = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(connection, SOL_LOCAL, LOCAL_PEERCRED, &cred, &size) == 0,
            cred.cr_version == XUCRED_VERSION, cred.cr_uid == getuid()
        else { return nil }

        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while data.count <= Limits.line {
            let n = read(connection, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
            if buffer[..<n].contains(0x0A) { break }
        }
        guard data.count <= Limits.line, let end = data.firstIndex(of: 0x0A) ?? (data.isEmpty ? nil : data.endIndex)
        else {
            return nil
        }
        return HookEvent.fromWire(data[data.startIndex..<end])
    }
}

/// sockaddr_un for a path, or nil when the path does not fit.
struct UnixAddress {
    private var storage = sockaddr_un()

    init?(_ path: String) {
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: storage.sun_path) else { return nil }
        storage.sun_family = sa_family_t(AF_UNIX)
        storage.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &storage.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
    }

    mutating func withSockaddr<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, length) }
        }
    }
}
