import SwiftUI

/// One desk island: the folder's name, its sessions, and their subagents beside them.
struct DeskView: View {
    let desk: Desk
    let now: Date
    let frame: Int

    static let width: CGFloat = 226
    private static let visibleMates = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: desk.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(desk.isOff ? .secondary : .primary)
                Spacer(minLength: 4)
                if desk.isOff { Text("Off duty").font(.callout).foregroundStyle(.secondary) }
            }

            HStack(alignment: .top, spacing: 8) {
                if desk.isOff {
                    Workstation(pose: .empty, seed: desk.name, frame: frame)
                } else {
                    ForEach(Array(desk.sessions.enumerated()), id: \.element.id) { index, session in
                        VStack(alignment: .leading, spacing: 2) {
                            Workstation(pose: Pose(session.state), seed: desk.name + "\(index)", frame: frame)
                            if index > 0 {
                                Text(verbatim: "\(desk.name) \(index + 1)").font(.caption).lineLimit(1).truncationMode(
                                    .middle)
                            }
                            session.state.label(since: session.since, now: now)
                                .font(.callout)
                                .foregroundStyle(session.state.color)
                                .lineLimit(1)
                        }
                        .frame(width: Workstation.grid * 3, alignment: .leading)
                    }
                }
            }

            let mates = desk.teammates
            if !mates.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(mates.prefix(Self.visibleMates)) { mate in
                        VStack(alignment: .leading, spacing: 1) {
                            Workstation(pose: Pose(mate.state), seed: mate.name ?? "helper", scale: 2, frame: frame)
                            mate.displayName.font(.caption.weight(.medium)).lineLimit(1).truncationMode(.tail)
                            mate.state.word.font(.caption).foregroundStyle(mate.state.color).lineLimit(1)
                        }
                        .frame(width: Workstation.grid * 2, alignment: .leading)
                    }
                    if mates.count > Self.visibleMates {
                        Text("+\(mates.count - Self.visibleMates)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .frame(minWidth: Self.width, maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Style.floor))
        .help(summary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary)
        .focusable()
    }

    /// "web-shop, Waiting, 3 min, teammate researcher Working" for VoiceOver and the hover tooltip.
    private var summary: Text {
        var text = Text(verbatim: desk.name)
        if desk.isOff { return text + Text(verbatim: ", ") + Text("Off duty") }
        for (index, session) in desk.sessions.enumerated() {
            text = text + Text(verbatim: ", ")
            if index > 0 { text = text + Text("session \(index + 1)") + Text(verbatim: ", ") }
            text = text + session.state.word
            let minutes = Int(now.timeIntervalSince(session.since) / 60)
            if minutes >= 1 { text = text + Text(verbatim: ", ") + Text("\(minutes) min") }
        }
        for mate in desk.teammates {
            text =
                text + Text(verbatim: ", ") + Text("teammate") + Text(verbatim: " ") + mate.displayName
                + Text(verbatim: " ") + mate.state.word
        }
        return text
    }
}
