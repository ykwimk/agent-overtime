import SwiftUI

/// What a workstation shows. Drawn in code on a 30×30 grid; no image files.
enum Pose: Equatable {
    case working, waiting, resting, empty

    init(_ state: WorkState) {
        switch state {
        case .working: self = .working
        case .waiting: self = .waiting
        case .resting: self = .resting
        }
    }
}

/// One desk with a chair, a monitor seen from behind, and (unless empty) a person.
struct Workstation: View {
    let pose: Pose
    /// Picks skin, hair and shirt, so the same name always looks the same.
    let seed: String
    var scale: CGFloat = 3
    var frame = 0
    @Environment(\.colorScheme) private var scheme

    static let grid: CGFloat = 30

    var body: some View {
        Canvas { context, _ in
            PixelPainter(context: context, scale: scale, palette: Palette(scheme: scheme, seed: seed), frame: frame).draw(pose)
        }
        .frame(width: Self.grid * scale, height: Self.grid * scale)
        .accessibilityHidden(true)
    }
}

struct Palette {
    /// `ink` is for symbols above heads and follows light/dark; `face` (eyes, mouth) stays dark.
    let ink, face, deskTop, deskFront, deskLeg, chair, chairEdge, monitor, mug, bubble, alert, ledOn, ledWait: Color
    let skin, hair, shirt: Color

    init(scheme: ColorScheme, seed: String) {
        let dark = scheme == .dark
        func rgb(_ hex: UInt32) -> Color {
            Color(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
        }
        ink = rgb(dark ? 0xE6E8EC : 0x2B2F38)
        face = rgb(0x2B2F38)
        deskTop = rgb(dark ? 0x8C6E52 : 0xD6B48C)
        deskFront = rgb(dark ? 0x6E543E : 0xB48A62)
        deskLeg = rgb(dark ? 0x574230 : 0x8E6A48)
        chair = rgb(dark ? 0x454A56 : 0x5B6170)
        chairEdge = rgb(dark ? 0x353943 : 0x474C59)
        monitor = rgb(dark ? 0x1C1F26 : 0x444A57)
        mug = rgb(dark ? 0xB9B3A8 : 0xFFFFFF)
        bubble = rgb(0xFFFFFF)
        alert = rgb(dark ? 0xFF8F54 : 0xC24007)
        ledOn = rgb(0x3FB56A)
        ledWait = rgb(0xE8A33D)

        // FNV-1a, stable across launches (Swift's hashValue is not).
        var hash: UInt32 = 2_166_136_261
        for byte in seed.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        let skins: [UInt32] = [0xF1C9A5, 0xE0AC85, 0xB97A55, 0x8A5A3B]
        let hairs: [UInt32] = [0x2E2A28, 0x6B4A2B, 0xB8893E, 0x8A8F99, 0x4A3A5A]
        let shirts: [UInt32] = [0x5B8DEF, 0xE07A5F, 0x6FAF8E, 0xD9B45A, 0x9C89B8, 0x4FA3B8, 0xC9707F]
        skin = rgb(skins[Int(hash % 4)])
        hair = rgb(hairs[Int(hash / 4 % 5)])
        shirt = rgb(shirts[Int(hash / 20 % 7)])
    }
}

private struct PixelPainter {
    let context: GraphicsContext
    let scale: CGFloat
    let palette: Palette
    let frame: Int

    func px(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: Color) {
        let rect = CGRect(x: CGFloat(x) * scale, y: CGFloat(y) * scale, width: CGFloat(w) * scale, height: CGFloat(h) * scale)
        context.fill(Path(rect), with: .color(color))
    }

    func draw(_ pose: Pose) {
        let p = palette
        // Chair: pushed back and to the side when nobody is there.
        if pose == .empty {
            px(2, 12, 8, 9, p.chair)
            px(2, 12, 8, 1, p.chairEdge)
            px(5, 21, 2, 2, p.chairEdge)
        } else {
            px(6, 10, 11, 10, p.chair)
            px(6, 10, 11, 1, p.chairEdge)
        }

        switch pose {
        case .working: working()
        case .waiting: waiting()
        case .resting: resting()
        case .empty: break
        }

        // Desk, mug, and the back of the monitor with its status light.
        px(1, 20, 28, 2, p.deskTop)
        px(1, 22, 28, 5, p.deskFront)
        px(2, 27, 2, 3, p.deskLeg)
        px(26, 27, 2, 3, p.deskLeg)
        px(3, 18, 2, 2, p.mug)
        px(18, 11, 10, 8, p.monitor)
        px(22, 19, 2, 1, p.monitor)
        switch pose {
        case .working: px(26, 17, 1, 1, p.ledOn)
        case .waiting: px(26, 17, 1, 1, p.ledWait)
        case .resting, .empty: break
        }
    }

    private func head(top: Int) {
        let p = palette
        px(8, top + 1, 7, 6, p.skin)
        px(8, top, 7, 2, p.hair)
        px(8, top + 2, 1, 2, p.hair)
        px(14, top + 2, 1, 2, p.hair)
    }

    /// Seated at the desk, hands tapping, three dots above.
    private func working() {
        let p = palette
        head(top: 7)
        px(10, 11, 1, 1, p.face)
        px(12, 11, 1, 1, p.face)
        px(7, 14, 9, 6, p.shirt)
        px(6, 15, 1, 4, p.shirt)
        px(16, 15, 1, 4, p.shirt)
        let tap = frame % 2 == 0
        px(6, tap ? 19 : 18, 2, 1, p.skin)
        px(15, tap ? 18 : 19, 2, 1, p.skin)
        for i in 0..<3 where frame % 4 >= i || frame == 0 {
            px(8 + i * 3, 3, 2, 2, p.ink)
        }
    }

    /// Stood up, one hand raised, "!" bubble.
    private func waiting() {
        let p = palette
        head(top: 3)
        px(10, 7, 1, 1, p.face)
        px(12, 7, 1, 1, p.face)
        px(11, 9, 1, 1, p.face)
        px(7, 10, 9, 10, p.shirt)
        px(6, 11, 1, 6, p.shirt)
        let wave = frame % 2 == 0 ? 0 : 1
        px(16 + wave, 3, 1, 8, p.shirt)
        px(16 + wave, 1, 2, 2, p.skin)
        // bubble
        px(0, 0, 7, 8, p.ink)
        px(1, 1, 5, 6, p.bubble)
        px(6, 7, 1, 1, p.ink)
        px(3, 2, 1, 3, p.alert)
        px(3, 6, 1, 1, p.alert)
    }

    /// Leaning back, hands behind the head, eyes closed, a drifting "z".
    private func resting() {
        let p = palette
        px(5, 8, 3, 2, p.shirt)
        px(15, 8, 3, 2, p.shirt)
        px(6, 10, 1, 3, p.shirt)
        px(16, 10, 1, 3, p.shirt)
        head(top: 6)
        px(9, 10, 2, 1, p.face)
        px(12, 10, 2, 1, p.face)
        px(7, 13, 9, 7, p.shirt)
        // A 5×5 "z" with a clear diagonal, drifting up one pixel every other beat.
        let lift = frame % 4 < 2 ? 0 : 1
        let x = 18, y = 2 - lift
        px(x, y, 5, 1, p.ink)
        px(x + 3, y + 1, 1, 1, p.ink)
        px(x + 2, y + 2, 1, 1, p.ink)
        px(x + 1, y + 3, 1, 1, p.ink)
        px(x, y + 4, 5, 1, p.ink)
    }
}
