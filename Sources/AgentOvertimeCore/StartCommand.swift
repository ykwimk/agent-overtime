import CryptoKit
import Foundation

/// The one "start work" command: run `run` in `folder`, in a new Terminal window.
/// `run` is an array so no shell ever re-reads the user's text.
public struct StartCommand: Codable, Equatable {
    public var folder: String
    public var run: [String]

    public init(folder: String, run: [String]) {
        self.folder = folder
        self.run = run
    }

    public enum Problem: Error, Equatable {
        case emptyCommand, nulCharacter, folderNotAbsolute
    }

    /// `~` and `~/…` become the home folder. Done by the app because `~` inside single quotes is not expanded.
    public func resolved(home: String) -> StartCommand {
        StartCommand(folder: Self.expandTilde(folder, home: home), run: run.map { Self.expandTilde($0, home: home) })
    }

    /// What the user approved. Kept outside config.json, so a pasted config file still has to be confirmed once.
    public var fingerprint: String {
        let joined = ([folder] + run).joined(separator: "\u{0}")
        return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The `.command` file Terminal runs. Deletes itself first, then runs the arguments exactly as stored.
    public func script(home: String) throws -> String {
        let command = resolved(home: home)
        guard let program = command.run.first, !program.isEmpty else { throw Problem.emptyCommand }
        guard !([command.folder] + command.run).contains(where: { $0.contains("\u{0}") }) else { throw Problem.nulCharacter }
        guard command.folder.hasPrefix("/") else { throw Problem.folderNotAbsolute }
        return """
        #!/bin/sh
        rm -f -- "$0"
        cd -- \(Self.quote(command.folder)) || exit 1
        exec \(command.run.map(Self.quote).joined(separator: " "))

        """
    }

    /// Single-quotes one argument for /bin/sh. Inside single quotes nothing is special except the quote itself.
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func expandTilde(_ value: String, home: String) -> String {
        if value == "~" { return home }
        if value.hasPrefix("~/") { return home + value.dropFirst() }
        return value
    }

    /// Splits what the user typed into arguments: spaces separate, '…' and "…" group. Nothing is expanded.
    public static func parse(_ line: String) -> [String] {
        var args: [String] = []
        var current = ""
        var quote: Character?
        var inArgument = false
        for ch in line {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "'" || ch == "\"" {
                quote = ch
                inArgument = true
            } else if ch == " " || ch == "\t" {
                if inArgument { args.append(current) }
                current = ""
                inArgument = false
            } else {
                current.append(ch)
                inArgument = true
            }
        }
        if inArgument { args.append(current) }
        return args
    }

    /// Shows hidden and look-alike characters as ⟨U+XXXX⟩ so the confirmation screen cannot be fooled.
    public static func revealed(_ value: String) -> String {
        var out = ""
        for scalar in value.unicodeScalars {
            let oddSpace = scalar.properties.generalCategory == .spaceSeparator && scalar != " "
            if Sanitize.isHidden(scalar) || oddSpace {
                out += String(format: "⟨U+%04X⟩", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
