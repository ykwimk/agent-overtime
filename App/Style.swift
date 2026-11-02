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

    private static func dynamic(
        light: (CGFloat, CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat, CGFloat)
    ) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
                return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: c.3)
            })
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
        }
    }

    var word: Text {
        switch self {
        case .working: return Text("Working")
        case .waiting: return Text("Waiting")
        case .resting: return Text("Resting")
        }
    }

    /// The label under a character: "Working", "Waiting · 3 min", "Resting".
    func label(since: Date, now: Date) -> Text {
        switch self {
        case .working: return Text("Working")
        case .resting: return Text("Resting")
        case .waiting:
            let minutes = Int(now.timeIntervalSince(since) / 60)
            return minutes < 1 ? Text("Waiting") : Text("Waiting · \(minutes) min")
        }
    }

    var color: Color {
        switch self {
        case .working: return .primary
        case .waiting: return Style.waiting
        case .resting: return .secondary
        }
    }

    /// On a name tag plate, where the system's secondary grey would fall under 4.5:1.
    var tagColor: Color {
        switch self {
        case .working: return Style.tagText
        case .waiting: return Style.waiting
        case .resting: return Style.tagSecondary
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
