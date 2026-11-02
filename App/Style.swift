import SwiftUI

/// Colour sits on status only: waiting gets the one accent, everything else is ink and grey.
enum Style {
    static let waiting = Color(
        nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 1.0, green: 0.56, blue: 0.33, alpha: 1)
                : NSColor(srgbRed: 0.76, green: 0.25, blue: 0.03, alpha: 1)
        })
    static let floor = Color(
        nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.165, green: 0.172, blue: 0.192, alpha: 1)
                : NSColor(srgbRed: 0.953, green: 0.945, blue: 0.925, alpha: 1)
        })
    static let title = Font.system(size: 20, weight: .semibold)

    /// Name tag plates follow light and dark; the room behind them does not (it follows the clock).
    static let tagPlate = dynamic(light: (1, 1, 1, 0.94), dark: (0.11, 0.11, 0.13, 0.92))
    static let tagText = dynamic(light: (0.11, 0.11, 0.12, 1), dark: (1, 1, 1, 1))
    static let tagSecondary = dynamic(light: (0.33, 0.33, 0.35, 1), dark: (0.72, 0.72, 0.74, 1))

    /// The side panel's state badge: a soft fill with strong text of the same hue, the waiting yellow of the room's
    /// "!" bubble. Quiet has no fill, only a grey border. 4.5:1 or more, light and dark (a test measures it).
    static func badge(_ state: WorkState) -> (fill: NSColor, text: NSColor, border: NSColor) {
        switch state {
        case .working:
            return (
                ns(light: (0.906, 0.941, 0.996, 1), dark: (0.129, 0.200, 0.310, 1)),
                ns(light: (0.102, 0.310, 0.561, 1), dark: (0.659, 0.788, 1, 1)), .clear
            )
        case .waiting:
            return (
                ns(light: (1, 0.953, 0.776, 1), dark: (0.271, 0.220, 0.059, 1)),
                ns(light: (0.420, 0.290, 0, 1), dark: (1, 0.824, 0.247, 1)), .clear
            )
        case .resting:
            return (
                ns(light: (0.937, 0.937, 0.945, 1), dark: (0.200, 0.200, 0.220, 1)),
                ns(light: (0.290, 0.290, 0.310, 1), dark: (0.850, 0.850, 0.870, 1)), .clear
            )
        case .quiet:
            return (
                .clear, ns(light: (0.330, 0.330, 0.350, 1), dark: (0.780, 0.780, 0.800, 1)),
                ns(light: (0.780, 0.780, 0.800, 1), dark: (0.400, 0.400, 0.430, 1))
            )
        }
    }

    private static func dynamic(
        light: (CGFloat, CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat, CGFloat)
    ) -> Color {
        Color(nsColor: ns(light: light, dark: dark))
    }

    private static func ns(
        light: (CGFloat, CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat, CGFloat)
    ) -> NSColor {
        NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: c.3)
        }
    }
}

extension WorkState {
    /// "Working" / "Waiting" / "Resting" as one word, for summaries and VoiceOver.
    /// The same word as text for VoiceOver to say.
    var spoken: String {
        switch self {
        case .working: return String(localized: "Working")
        case .waiting: return String(localized: "Waiting")
        case .resting: return String(localized: "Resting")
        case .quiet: return String(localized: "Quiet")
        }
    }

    var word: Text {
        switch self {
        case .working: return Text("Working")
        case .waiting: return Text("Waiting")
        case .resting: return Text("Resting")
        case .quiet: return Text("Quiet")
        }
    }

    /// The room bubble's mark, beside the word on the panel's badge; none for Quiet.
    var mark: String? {
        switch self {
        case .working: return "…"
        case .waiting: return "!"
        case .resting: return "z"
        case .quiet: return nil
        }
    }

    /// The label under a character: "Working", "Waiting · 3 min", "Resting", "Quiet".
    func label(since: Date, now: Date) -> Text {
        switch self {
        case .waiting:
            let minutes = Int(now.timeIntervalSince(since) / 60)
            return minutes < 1 ? Text("Waiting") : Text("Waiting · \(minutes) min")
        case .working, .resting, .quiet:
            return word
        }
    }

    var color: Color {
        switch self {
        case .working: return .primary
        case .waiting: return Style.waiting
        case .resting, .quiet: return .secondary
        }
    }

    /// On a name tag plate, where the system's secondary grey would fall under 4.5:1.
    var tagColor: Color {
        switch self {
        case .working: return Style.tagText
        case .waiting: return Style.waiting
        case .resting, .quiet: return Style.tagSecondary
        }
    }
}

extension HookEvent.ToolKind {
    /// What someone working is doing now, in one of these fixed phrases: only these words ever show, never a tool's
    /// name or anything received.
    var phrase: Text { Text(LocalizedStringKey(phraseKey)) }

    /// The same phrase for VoiceOver to say.
    var spoken: String { String(localized: String.LocalizationValue(phraseKey)) }

    /// Each key is in the string catalog (a test checks).
    var phraseKey: String {
        switch self {
        case .read: return "Reading files"
        case .find: return "Finding files"
        case .grep: return "Searching code"
        case .lsp: return "Looking at code structure"
        case .edit: return "Editing files"
        case .write: return "Writing files"
        case .command: return "Running a command"
        case .monitor: return "Watching a command"
        case .web: return "Searching the web"
        case .fetch: return "Reading a web page"
        case .team: return "Calling teammates"
        case .talk: return "Messaging a teammate"
        case .tasks: return "Organizing tasks"
        case .skill: return "Using a skill"
        case .other: return "Using another tool"
        }
    }
}

extension Teammate {
    /// "Explore", or "Explore 2" while another Explore works too; its nickname in place of its name if it has one.
    var displayName: Text {
        let base = (nickname ?? name).map { Text(verbatim: $0) } ?? Text("Helper")
        return labelNumber > 1 ? base + Text(verbatim: " \(labelNumber)") : base
    }

    /// The same name as plain text, to go inside a sentence.
    var label: String {
        let base = nickname ?? name ?? String(localized: "Helper")
        return labelNumber > 1 ? "\(base) \(labelNumber)" : base
    }

    /// The name it has without a nickname.
    var autoName: Text {
        let base = name.map { Text(verbatim: $0) } ?? Text("Helper")
        return number > 1 ? base + Text(verbatim: " \(number)") : base
    }
}

/// A row that behaves like a menu item inside the menu bar window.
struct MenuRow: View {
    let title: LocalizedStringKey
    var shortcut: String?
    let action: () -> Void
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        // Keyboard focus gets the same highlight as the mouse.
        let lit = hovering || focused
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let shortcut {
                    Text(verbatim: shortcut).foregroundStyle(lit ? Color.white.opacity(0.85) : .secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 5).fill(lit ? Color.accentColor.opacity(0.85) : .clear))
            .foregroundStyle(lit ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .focused($focused)
        .onHover { hovering = $0 }
        .padding(.horizontal, 5)
    }
}
