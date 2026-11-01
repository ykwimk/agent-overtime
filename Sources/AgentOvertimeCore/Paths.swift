import Foundation

public enum Paths {
    public static let appName = "AgentOvertime"
    public static let helperName = "agent-overtime-hook"

    /// The real home folder, not $HOME (a hook may run with a changed environment).
    public static var home: String {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }

    public static func supportFolder(home: String = home) -> String {
        home + "/Library/Application Support/" + appName
    }

    /// Unix socket paths are limited to 103 bytes (man unix(4)); a very long home folder falls back to the
    /// per-user temporary folder, which only this user can open.
    public static func socket(home: String = home, tempFolder: String = userTempFolder) -> String {
        let primary = supportFolder(home: home) + "/events.sock"
        if primary.utf8.count <= 103 { return primary }
        return (tempFolder as NSString).appendingPathComponent("agent-overtime.sock")
    }

    public static var userTempFolder: String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 else { return NSTemporaryDirectory() }
        return String(cString: buffer)
    }
}

/// The plugin's hooks call the helper only at these two fixed paths, so the app must live there.
public enum AppLocation: Equatable {
    case ok
    /// Opened straight from Downloads or the disk image: macOS runs it from a random read-only path.
    case translocated
    case notInApplications

    public static func check(bundlePath: String, home: String) -> AppLocation {
        if bundlePath.contains("/AppTranslocation/") { return .translocated }
        let allowed = ["/Applications/\(Paths.appName).app", "\(home)/Applications/\(Paths.appName).app"]
        return allowed.contains(bundlePath) ? .ok : .notInApplications
    }
}

/// The command line the plugin's hooks.json runs. Paths are fixed and single-quoted; `exec` makes the helper's
/// parent the Claude Code process, and `exit 0` keeps a missing app from ever showing a hook error.
public enum HookCommand {
    public static var line: String {
        let system = "/Applications/\(Paths.appName).app/Contents/MacOS/\(Paths.helperName)"
        let user = "$HOME/Applications/\(Paths.appName).app/Contents/MacOS/\(Paths.helperName)"
        return "test -x '\(system)' && exec '\(system)'; test -x \"\(user)\" && exec \"\(user)\"; exit 0"
    }
}
