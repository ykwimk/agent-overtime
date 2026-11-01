import AppKit

/// The sheets in Resources/Art (LPC Revised for the room, MetroCity for people; see CREDITS.txt there), cut
/// into cells on first use.
final class ArtStore {
    static let shared = ArtStore()

    private let folder: URL?
    private var sheets: [String: CGImage] = [:]
    private var cells: [String: CGImage] = [:]
    private var pictures: [String: CGImage] = [:]

    /// The screen's own colour space and pixel order (premultiplied BGRA). The office picture and its cells are
    /// kept in them, so colours are matched once per cell instead of once per frame when the window shows it.
    static let screenSpace = NSScreen.main?.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
    static let screenFormat = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    init(bundle: Bundle = .main) {
        folder = bundle.resourceURL?.appendingPathComponent("Art")
    }

    /// A cell of a sheet, enlarged `scale` times without smoothing. The office keeps its cells at its own
    /// density, so drawing one copies pixels one to one instead of scaling every frame.
    func cell(_ path: String, _ x: Int, _ y: Int, _ width: Int, _ height: Int, scale: Int = 1) -> CGImage? {
        let key = "\(path)#\(x),\(y),\(width),\(height)x\(scale)"
        if let cell = cells[key] { return cell }
        guard let sheet = sheet(path), var cell = sheet.cropping(to: CGRect(x: x, y: y, width: width, height: height))
        else { return nil }
        if scale > 1 {
            guard
                let context = CGContext(
                    data: nil, width: width * scale, height: height * scale, bitsPerComponent: 8, bytesPerRow: 0,
                    space: ArtStore.screenSpace,
                    bitmapInfo: ArtStore.screenFormat)
            else { return nil }
            context.interpolationQuality = .none
            context.draw(cell, in: CGRect(x: 0, y: 0, width: width * scale, height: height * scale))
            guard let large = context.makeImage() else { return nil }
            cell = large
        }
        cells[key] = cell
        return cell
    }

    /// Pictures drawn once and reused (the empty room, the night view through a window). A few at most:
    /// resizing the window makes a new room size each time.
    func picture(_ key: String, draw: () -> CGImage?) -> CGImage? {
        if let picture = pictures[key] { return picture }
        if pictures.count > 32 { pictures.removeAll() }
        let picture = draw()
        pictures[key] = picture
        return picture
    }

    private func sheet(_ path: String) -> CGImage? {
        if let sheet = sheets[path] { return sheet }
        guard let url = folder?.appendingPathComponent(path),
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let sheet = path.hasPrefix("MetroCity/") ? Self.recolored(image) ?? image : image
        sheets[path] = sheet
        return sheet
    }

    /// A MetroCity sheet with every opaque pixel passed through `nearRoom`, once, in memory.
    private static func recolored(_ image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pixels = context.data?.bindMemory(to: UInt8.self, capacity: width * height * 4) else { return nil }
        // Semi-transparent pixels (the shadow) stay as they are.
        for i in stride(from: 0, to: width * height * 4, by: 4) where pixels[i + 3] == 255 {
            (pixels[i], pixels[i + 1], pixels[i + 2]) = nearRoom(pixels[i], pixels[i + 1], pixels[i + 2])
        }
        return context.makeImage()
    }

    /// MetroCity people drawn beside LPC Revised furniture: colours a little less saturated and less contrasty,
    /// like LPC's muted palette, and near-black outlines lifted one step toward LPC's dark plum-brown.
    static func nearRoom(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> (UInt8, UInt8, UInt8) {
        let gray = 0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)
        func channel(_ value: UInt8, _ outline: Double) -> UInt8 {
            var v = Double(value) + (gray - Double(value)) * 0.12
            v = 10 + v * 0.93
            if gray < 40 { v += (outline - v) * 0.6 }
            return UInt8(min(255, max(0, v.rounded())))
        }
        return (channel(r, 0x3B), channel(g, 0x2A), channel(b, 0x33))
    }
}

/// One of the office workers, made of MetroCity layers: a body in one skin tone, clothes, hair. Every sheet has
/// 32-pixel cells, one row per variant and 24 columns: 6 frames each facing down, right, up and right again.
struct Look: Equatable {
    /// A row of one sheet in Art/MetroCity.
    struct Layer: Equatable {
        let sheet: String
        let row: Int
    }

    /// Row of the body sheet (skin tone).
    let skin: Int
    let clothes: Layer
    let hair: Layer

    static let body = "MetroCity/CharacterModel/Character Model.png"
    static let shadow = "MetroCity/CharacterModel/Shadow.png"
    private static let hairs = "MetroCity/Hair/Hairs.png"
    private static let hair2 = "MetroCity/MetroCity 2.0/Hair.png"
    private static let suit = "MetroCity/MetroCity 2.0/Suit.png"
    private static let shirts = "MetroCity/MetroCity 2.0/Suit1.png"

    private init(_ skin: Int, _ clothes: (String, Int), _ hair: (String, Int)) {
        self.skin = skin
        self.clothes = Layer(sheet: clothes.0, row: clothes.1)
        self.hair = Layer(sheet: hair.0, row: hair.1)
    }

    /// Seated people show only the back of the head, so every look has its own hair: different shapes and colours
    /// (black, dark brown, red, ginger, grey), only two of them blond. The hair band with a ponytail is left out:
    /// from behind it reads as a striped cap.
    static let all: [Look] = [
        Look(0, (suit, 2), (hairs, 7)),
        Look(5, (suit, 2), (hairs, 0)),
        Look(3, (shirts, 0), (hairs, 6)),
        Look(2, (shirts, 2), (hair2, 0)),
        Look(4, ("MetroCity/Outfits/Outfit5.png", 0), (hairs, 3)),
        Look(1, (shirts, 4), (hairs, 5)),
        Look(5, ("MetroCity/Outfits/Outfit6.png", 0), (hairs, 1)),
        Look(3, (shirts, 1), (hair2, 2)),
        Look(2, ("MetroCity/Outfits/Outfit1.png", 0), (hairs, 2)),
    ]

    /// The same name always gets the same person. The salt is one that gives everyone in the example office, and
    /// Explore, Plan, general-purpose and the default helper with the same number or the same name, different hair.
    static func pick(_ seed: String) -> Look { all[Int(stableHash("120 " + seed) % UInt32(all.count))] }

    /// FNV-1a: the same across launches, unlike hashValue.
    static func stableHash(_ text: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in text.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return hash
    }

    /// Drawing order, bottom first.
    var layers: [Layer] { [Layer(sheet: Self.body, row: skin), clothes, hair] }
}

/// What stands on a desk beside the laptop. A name always gets the same one, picked like `Look.pick`: a session
/// by its folder's name, a teammate by its own name.
enum Prop: CaseIterable {
    case lamp, shade, flowers, laptop, none

    static func pick(_ seed: String) -> Prop {
        allCases[Int(Look.stableHash("prop " + seed) % UInt32(allCases.count))]
    }
}

/// The symbol in a speech bubble above a head.
enum Mark {
    case dots, bang, zzz

    init(_ state: WorkState) {
        switch state {
        case .working: self = .dots
        case .waiting: self = .bang
        case .resting: self = .zzz
        }
    }
}

/// Someone on the way in or out, already placed for this moment. No bubble while walking: the state is on the
/// name tag of the desk they walk to, and a bubble passing a seated "!" would blur whose it is.
struct Walker {
    enum Facing {
        case up, left, down, right

        /// The first of its six walking frames on a MetroCity sheet; left is right, mirrored.
        var column: Int {
            switch self {
            case .down: 0
            case .left, .right: 6
            case .up: 12
            }
        }
    }
    let look: Look
    /// Feet, in art pixels.
    let x: Int
    let y: Int
    let facing: Facing
    let step: Int

    /// What the walker and the shadow at their feet cover, in art pixels: one 32-pixel cell at 1.5.
    var box: CGRect { CGRect(x: x - 24, y: y - 45, width: 48, height: 48) }
}

/// Everything one picture of the office needs. Sizes are art pixels.
struct OfficeScene {
    var layout: RoomLayout
    var height: Int
    var pods: [Pod]
    var darkness: Double
    var frame: Int
    var now: Date
    var walkers: [Walker] = []
    /// People still walking in: their desks look empty until they arrive.
    var away: Set<String> = []
    var doorOpen = false
    var calendar = Calendar.current

    /// Who walks to and from a seat. Nobody walks for a seat someone went home from.
    static func id(_ seat: Seat) -> String? {
        switch seat {
        case .session(let session, _): return "p:" + session.id
        case .teammate(let mate, _): return "m:" + mate.id
        case .off: return nil
        }
    }

    /// The same name always gets the same person, and a second "Explore" looks different from the first.
    static func look(_ seat: Seat) -> Look? {
        switch seat {
        case .session(let session, _): return Look.pick(session.name)
        case .teammate(let mate, _): return Look.pick("\(mate.name ?? "helper") \(mate.number)")
        case .off: return nil
        }
    }

    static func state(_ seat: Seat) -> WorkState? {
        switch seat {
        case .session(let session, _): return session.state
        case .teammate(let mate, _): return mate.state
        case .off: return nil
        }
    }

    /// A session's prop goes by its folder's name (without the number), and stays on its desk after it went home.
    static func prop(_ seat: Seat) -> Prop {
        switch seat {
        case .session(let session, _):
            let suffix = session.number > 1 ? " \(session.number)".count : 0
            return Prop.pick(String(session.name.dropLast(suffix)))
        case .teammate(let mate, _):
            return Prop.pick(mate.name ?? "helper")
        case .off(_, let folder):
            let last = (folder as NSString).lastPathComponent
            return Prop.pick(last.isEmpty ? folder : last)
        }
    }
}

/// Draws the office into one bitmap, in art-pixel coordinates at `density` bitmap pixels per art pixel, so
/// the view shows one bitmap pixel per point. People are drawn at 1.5 art pixels per pixel, which still
/// lands on whole bitmap pixels.
struct OfficeRenderer {
    static let density = RoomLayout.pointsPerPixel
    /// Art pixels per MetroCity pixel: people about as tall as the LPC ones were, on whole bitmap pixels.
    static let personPixel: CGFloat = 1.5

    private enum Sheet {
        static let floor = "Structure/Floor/Wood Floor A.png"
        static let wall = "Structure/Walls/Painted Walls.png"
        static let desk = "Objects/Furniture/Desk, Office.png"
        static let chair = "Objects/Furniture/Seating/Chair, Office.png"
        static let laptop = "Objects/Small Items/Laptop.png"
        static let lamp = "Objects/Small Items/Lighting, Table.png"
        static let planter = "Objects/Furniture/Planter.png"
        static let cooler = "Objects/Furniture/Water Cooler.png"
        static let copier = "Objects/Furniture/Copy Machine.png"
        static let cabinet = "Objects/Furniture/Cabinet.png"
    }

    private let art = ArtStore.shared

    /// The whole office, or only the part inside `crop` (whole art pixels), drawn exactly as it is there in the
    /// whole picture.
    func render(_ scene: OfficeScene, crop: CGRect? = nil) -> CGImage? {
        Self.picture(width: scene.layout.width, height: scene.height, density: Self.density, crop: crop, art: art) {
            $0.draw(scene)
        }
    }

    /// A new bitmap `density` times the art size, painted in top-left art-pixel coordinates. Pictures reused
    /// inside the office (the empty room, glows, night views) stay at 1 and are scaled up without smoothing.
    private static func picture(
        width: Int, height: Int, density: Int = 1, crop: CGRect? = nil, art: ArtStore,
        _ paint: (inout Canvas) -> Void
    ) -> CGImage? {
        let area = crop ?? CGRect(x: 0, y: 0, width: width, height: height)
        guard width > 0, height > 0, area.width > 0, area.height > 0,
            let context = CGContext(
                data: nil, width: Int(area.width) * density, height: Int(area.height) * density, bitsPerComponent: 8,
                bytesPerRow: 0, space: ArtStore.screenSpace, bitmapInfo: ArtStore.screenFormat)
        else { return nil }
        context.scaleBy(x: CGFloat(density), y: CGFloat(density))
        // The canvas still paints the whole office; the bitmap keeps only `area` of it.
        context.translateBy(x: -area.minX, y: area.maxY - CGFloat(height))
        context.interpolationQuality = .none
        context.setShouldAntialias(false)
        var canvas = Canvas(context: context, height: height, art: art)
        paint(&canvas)
        return context.makeImage()
    }

    /// The glass of each window on the back wall, and whether the bookcase still fits beside them.
    private static func wallPlan(width: Int) -> (glass: [CGRect], shelf: Bool) {
        let shelf = width - 112 - 144 >= 76
        var glass: [CGRect] = []
        var x = 144
        while x + 76 <= width - (shelf ? 112 : 44) {
            glass.append(CGRect(x: x + 2, y: 19, width: 72, height: 36))
            x += 92
        }
        return (glass, shelf)
    }

    /// Drawing helpers in top-left pixel coordinates, plus what has to wait for the night pass.
    private struct Canvas {
        let context: CGContext
        let height: Int
        let art: ArtStore
        var marks: [(Mark, Int, Int)] = []
        /// Centres of the night light: a pool at every seat someone works at, a bulb in each lamp, a laptop's glow.
        var pools: [(x: Int, y: Int)] = []
        var bulbs: [(x: Int, y: Int)] = []
        var screens: [(x: Int, y: Int)] = []
        /// Lamps drawn again, lit, over the night shade: sheet cell, place, mirrored.
        var litLamps: [(sx: Int, x: Int, y: Int, mirrored: Bool)] = []
        /// Bitmap pixels per MetroCity pixel, and art pixels per bitmap pixel.
        static let personScale = Int(OfficeRenderer.personPixel * CGFloat(OfficeRenderer.density))
        static let bitmapPixel = 1 / CGFloat(OfficeRenderer.density)

        init(context: CGContext, height: Int, art: ArtStore) {
            self.context = context
            self.height = height
            self.art = art
        }

        // MARK: primitives

        func image(_ image: CGImage?, _ x: Int, _ y: Int, mirrored: Bool = false) {
            self.image(image, CGFloat(x), CGFloat(y), mirrored: mirrored)
        }

        /// `pixel` is how many art pixels one pixel of the image covers.
        func image(_ image: CGImage?, _ x: CGFloat, _ y: CGFloat, pixel: CGFloat = 1, mirrored: Bool = false) {
            guard let image else { return }
            let w = CGFloat(image.width) * pixel
            let h = CGFloat(image.height) * pixel
            let rect = CGRect(x: x, y: CGFloat(height) - y - h, width: w, height: h)
            guard mirrored else { return context.draw(image, in: rect) }
            context.saveGState()
            context.translateBy(x: rect.minX + rect.maxX, y: 0)
            context.scaleBy(x: -1, y: 1)
            context.draw(image, in: rect)
            context.restoreGState()
        }

        func sprite(
            _ sheet: String, _ sx: Int, _ sy: Int, _ w: Int, _ h: Int, _ x: Int, _ y: Int, mirrored: Bool = false
        ) {
            let density = OfficeRenderer.density
            image(
                art.cell(sheet, sx, sy, w, h, scale: density), CGFloat(x), CGFloat(y), pixel: 1 / CGFloat(density),
                mirrored: mirrored)
        }

        func fill(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ hex: UInt32, _ alpha: CGFloat = 1) {
            context.setFillColor(Self.color(hex, alpha))
            context.fill(CGRect(x: x, y: height - y - h, width: w, height: h))
        }

        static func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
            CGColor(
                srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        }

        static func gradient(_ hex: UInt32, _ alpha: CGFloat) -> CGGradient? {
            CGGradient(
                colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                colors: [color(hex, alpha), color(hex, alpha * 0.35), color(hex, 0)] as CFArray, locations: [0, 0.4, 1])
        }

        /// A picture kept at the office's own density, so stamping it copies pixels one to one.
        func stamp(_ picture: CGImage?, _ x: Int, _ y: Int) {
            image(picture, CGFloat(x), CGFloat(y), pixel: 1 / CGFloat(OfficeRenderer.density))
        }

        /// A soft round light, drawn once per colour and strength and then stamped where it shines.
        func glow(_ hex: UInt32, _ alpha: CGFloat, radius: Int) -> CGImage? {
            art.picture("glow \(hex) \(Int(alpha * 100)) \(radius)") { [art] in
                OfficeRenderer.picture(
                    width: radius * 2, height: radius * 2, density: OfficeRenderer.density, art: art
                ) { canvas in
                    guard let gradient = Self.gradient(hex, alpha) else { return }
                    let center = CGPoint(x: radius, y: radius)
                    canvas.context.drawRadialGradient(
                        gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: CGFloat(radius),
                        options: [])
                }
            }
        }

        /// A one-pixel line, for clock hands and whiteboard scribbles.
        func line(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ hex: UInt32) {
            let steps = max(1, Int(max(abs(x1 - x0), abs(y1 - y0)).rounded()))
            for i in 0...steps {
                let t = Double(i) / Double(steps)
                fill(Int((x0 + (x1 - x0) * t).rounded()), Int((y0 + (y1 - y0) * t).rounded()), 1, 1, hex)
            }
        }

        // MARK: the room

        mutating func draw(_ scene: OfficeScene) {
            let width = scene.layout.width
            let height = self.height
            let plan = OfficeRenderer.wallPlan(width: width)
            let room = art.picture("room \(width)x\(height) open:\(scene.doorOpen)") { [art] in
                OfficeRenderer.picture(width: width, height: height, density: OfficeRenderer.density, art: art) {
                    room in
                    room.floor(width: width)
                    room.wall(width: width, plan: plan)
                    room.door(open: scene.doorOpen)
                }
            }
            stamp(room, 0, 0)
            clock(center: (123, 21), scene.now, scene.calendar)
            plants(scene)
            // Back to front: someone walking behind an island's far seats is drawn before the island.
            var walkers = scene.walkers.sorted { $0.y < $1.y }[...]
            for pod in scene.pods {
                let origin = scene.layout.origin(of: pod.slot)
                while let walker = walkers.first, walker.y < origin.y + RoomLayout.farDesk {
                    self.walker(walker)
                    walkers.removeFirst()
                }
                self.pod(pod, origin: origin, scene: scene)
            }
            for walker in walkers { self.walker(walker) }
            night(scene, glass: plan.glass)
            for (mark, x, top) in marks { bubble(mark, x, top) }
        }

        private func walker(_ walker: Walker) {
            // The feet are 30 sheet pixels down the cell; the pack's shadow cell sits under them.
            let x = walker.box.minX
            let y = walker.box.minY
            image(art.cell(Look.shadow, 0, 0, 32, 32, scale: Self.personScale), x, y, pixel: Self.bitmapPixel)
            person(walker.look, column: walker.facing.column + walker.step % 6, x, y, mirrored: walker.facing == .left)
        }

        private func floor(width: Int) {
            for y in stride(from: RoomLayout.wall, to: height, by: 96) {
                for x in stride(from: 0, to: width, by: 32) { sprite(Sheet.floor, 96, 0, 32, 96, x, y) }
            }
        }

        private func wall(width: Int, plan: (glass: [CGRect], shelf: Bool)) {
            for x in stride(from: 0, to: width, by: 32) {
                sprite(Sheet.wall, 224, 128 - RoomLayout.wall, 32, RoomLayout.wall, x, 0)
            }
            whiteboard(50, 14)
            for glass in plan.glass { window(Int(glass.minX) - 2, 8, 76, 50) }
            if plan.shelf { sprite(Sheet.cabinet, 64, 96, 64, 80, width - 108, RoomLayout.wall - 74) }
            sprite(Sheet.cooler, 32, 0, 32, 64, width - 40, RoomLayout.wall - 58)
        }

        /// A plant in the gap every other row leaves at its end, a tile clear of the islands, in rows with an
        /// island.
        private func plants(_ scene: OfficeScene) {
            let layout = scene.layout
            for row in Set(scene.pods.map { $0.slot / layout.columns }) {
                let end = RoomLayout.lane + layout.columns * (RoomLayout.islandWidth + RoomLayout.gap)
                let x = row % 2 == 1 ? RoomLayout.lane : end
                sprite(Sheet.planter, 128, 32, 32, 64, x, RoomLayout.firstRow + row * RoomLayout.rowPitch + 44)
            }
        }

        // MARK: islands

        /// One island, back to front: across the desks the chairs, the people facing the room (the pack's front
        /// view, cut at the chest; the far desks hide the rest), the far desks and what stands on them; then the
        /// near desks, their laptops and props, and the people with their backs to the room.
        private mutating func pod(_ pod: Pod, origin: (x: Int, y: Int), scene: OfficeScene) {
            let (x0, y0) = origin
            let far = y0 + RoomLayout.farDesk
            let near = y0 + RoomLayout.nearDesk
            // Who is at each seat right now: people still walking in are not there yet.
            let here = pod.seats.map { seat -> (look: Look, state: WorkState)? in
                guard let seat, let id = OfficeScene.id(seat), !scene.away.contains(id),
                    let look = OfficeScene.look(seat), let state = OfficeScene.state(seat)
                else { return nil }
                return (look, state)
            }
            let wentHome = pod.seats.map { seat -> Bool in
                if case .off? = seat { return true }
                return false
            }

            for seat in [1, 3] {
                let cx = x0 + RoomLayout.personX(seat)
                let top = far - 28
                // A chair someone went home from is pushed back from the desk.
                if wentHome[seat] {
                    sprite(Sheet.chair, 0, 40, 32, 48, cx - 13, top + 3)
                } else {
                    sprite(Sheet.chair, 0, 40, 32, 48, cx - 16, top + 11)
                }
                if let person = here[seat] {
                    let nod = person.state == .resting && scene.frame % 4 >= 2 ? OfficeRenderer.personPixel : 0
                    self.person(person.look, column: 0, rows: 28, CGFloat(cx - 24), CGFloat(top) + nod)
                }
            }
            for seat in [1, 3] {
                sprite(Sheet.desk, 67, 80, RoomLayout.deskWidth, 16, x0 + RoomLayout.deskX(seat), far)
            }
            let lit = scene.darkness > 0
            for seat in [1, 3] {
                let cx = x0 + RoomLayout.personX(seat)
                // The back of the open laptop (the closed lid, standing), its logo lit while the screen is on.
                if let person = here[seat] {
                    sprite(Sheet.laptop, person.state == .resting ? 0 : 32, 96, 32, 32, cx - 15, far - 6)
                    if person.state != .resting { screens.append((cx, far + 4)) }
                    pools.append((cx - 3, far - 4))
                } else if wentHome[seat] {
                    sprite(Sheet.laptop, 0, 96, 32, 32, cx - 15, far - 4)
                }
                if let occupant = pod.seats[seat] {
                    let x = x0 + RoomLayout.deskX(seat)
                    prop(OfficeScene.prop(occupant), x: x, base: far + 6, across: true, lit: lit && here[seat] != nil)
                }
            }

            for seat in [0, 2] {
                sprite(Sheet.desk, 67, 72, RoomLayout.deskWidth, 56, x0 + RoomLayout.deskX(seat), near)
            }
            for seat in [0, 2] {
                let dx = x0 + RoomLayout.deskX(seat)
                // Laptop: closed where someone went home, dark while resting, on (and typing) while working.
                if wentHome[seat] {
                    sprite(Sheet.laptop, 0, 96, 32, 32, dx + 2, near - 6)
                } else if let person = here[seat] {
                    sprite(Sheet.laptop, person.state == .resting ? 0 : 32, 0, 32, 32, dx + 2, near - 8)
                    if person.state != .resting { screens.append((dx + 18, near + 2)) }
                    if person.state == .working { typing(dx + 2, near - 8, frame: scene.frame + seat) }
                    pools.append((dx + 44, near + 21))
                }
                if let occupant = pod.seats[seat] {
                    prop(
                        OfficeScene.prop(occupant), x: dx, base: near + 17, across: false, lit: lit && here[seat] != nil
                    )
                }
            }
            for seat in [0, 2] {
                let cx = x0 + RoomLayout.personX(seat)
                if let person = here[seat] {
                    sit(person.look, cx: cx, top: near, nod: person.state == .resting && scene.frame % 4 >= 2)
                } else if wentHome[seat] {
                    sprite(Sheet.chair, 0, 40, 32, 48, cx - 13, near + 33)
                } else {
                    sprite(Sheet.chair, 0, 40, 32, 48, cx - 16, near + 26)
                }
            }

            // Everyone stays seated; the bubble tells the states apart. The "!" hops while waiting; with Reduce
            // Motion the frame stays 0, so it holds still. Across the desks the bubble sits beside the head, so
            // the name tag above it stays clear.
            for seat in 0..<Island.size {
                guard let person = here[seat] else { continue }
                let hop = person.state == .waiting && scene.frame % 2 == 1 ? 2 : 0
                let cx = x0 + RoomLayout.personX(seat)
                if RoomLayout.isAcross(seat) {
                    marks.append((Mark(person.state), cx + 15, far - 11 - hop))
                } else {
                    marks.append((Mark(person.state), cx, near + 8 - hop))
                }
            }
        }

        /// A desk prop: on a near desk right of the person, across the desks left of the person. A lamp is off by
        /// day and where nobody works; at night it is drawn again, lit, over the dark.
        private mutating func prop(_ prop: Prop, x dx: Int, base: Int, across: Bool, lit: Bool) {
            switch prop {
            case .lamp:
                let x = across ? dx : dx + 34
                sprite(Sheet.lamp, 224, 32, 32, 32, x, base - 22, mirrored: !across)
                if lit {
                    litLamps.append((192, x, base - 22, !across))
                    bulbs.append(across ? (x + 17, base - 17) : (x + 12, base - 10))
                }
            case .shade:
                let x = across ? dx + 1 : dx + 38
                sprite(Sheet.lamp, 160, 32, 32, 32, x, base - 28)
                if lit {
                    litLamps.append((128, x, base - 28, false))
                    bulbs.append((x + 12, base - 18))
                }
            case .flowers:
                sprite(Sheet.planter, 128, 0, 32, 32, across ? dx - 1 : dx + 34, base - 31)
            case .laptop:
                if across {
                    sprite(Sheet.laptop, 64, 96, 32, 32, dx - 4, base - 12)
                } else {
                    sprite(Sheet.laptop, 64, 0, 32, 32, dx + 36, base - 25)
                }
            case .none:
                break
            }
        }

        /// The pack has no sitting pose: the back of a standing person, cut under the shoulders (sheet row 24),
        /// behind the chair's backrest. Shoulders (row 20) sit 4 art pixels below the top of the backrest.
        private func sit(_ look: Look, cx: Int, top: Int, nod: Bool) {
            person(
                look, column: 12, rows: 24, CGFloat(cx) - 24, CGFloat(top) + 2 + (nod ? OfficeRenderer.personPixel : 0))
            sprite(Sheet.chair, 0, 0, 32, 32, cx - 16, top + 28)
        }

        /// The top `rows` of one cell of every layer of a person, at `x`, `y` in art pixels.
        private func person(
            _ look: Look, column: Int, rows: Int = 32, _ x: CGFloat, _ y: CGFloat, mirrored: Bool = false
        ) {
            for layer in look.layers {
                image(
                    art.cell(layer.sheet, column * 32, layer.row * 32, 32, rows, scale: Self.personScale), x, y,
                    pixel: Self.bitmapPixel, mirrored: mirrored)
            }
        }

        /// A few short lines appearing on the laptop screen: typing, without drawing hands.
        private func typing(_ x: Int, _ y: Int, frame: Int) {
            let lengths = [7, 4, 9, 5, 8, 3]
            let shown = frame % 4
            for row in 0..<shown {
                fill(x + 10, y + 11 + row * 2, lengths[(frame / 4 + row) % lengths.count], 1, 0xD8ECFF, 0.9)
            }
        }

        // MARK: drawn in code (the pack has no office window, plain door, whiteboard or wall clock)

        /// A wide office window with a thin metal frame and half-open blinds.
        private func window(_ x: Int, _ y: Int, _ w: Int, _ h: Int) {
            fill(x - 1, y - 1, w + 2, h + 3, 0x3E434D)
            fill(x, y, w, h, 0x7D848F)
            let glass = CGRect(x: x + 2, y: y + 11, width: w - 4, height: h - 14)
            for row in 0..<Int(glass.height) {
                let t = Double(row) / glass.height
                let hex = Self.mix(0x9ACDEB, 0xD7EEF8, t)
                fill(Int(glass.minX), Int(glass.minY) + row, Int(glass.width), 1, hex)
            }
            // Far-off buildings, pale in the haze.
            var bx = Int(glass.minX)
            let heights = [9, 14, 7, 17, 11, 6, 13, 9]
            var i = x / 7
            while bx < Int(glass.maxX) {
                let bw = 6 + (i % 3) * 2
                let bh = heights[i % heights.count]
                fill(bx, Int(glass.maxY) - bh, min(bw, Int(glass.maxX) - bx), bh, 0xB4CAD8)
                bx += bw + 1
                i += 1
            }
            // Reflection.
            for k in 0..<10 { fill(x + 12 + k, Int(glass.maxY) - 4 - k * 2, 2, 2, 0xFFFFFF, 0.35) }
            for k in 0..<6 { fill(x + 24 + k, Int(glass.maxY) - 4 - k * 2, 1, 2, 0xFFFFFF, 0.3) }
            // Blinds pulled half down.
            for row in 0..<9 { fill(x + 2, y + 2 + row, w - 4, 1, row % 2 == 0 ? 0xEDEAE1 : 0xCFC9BA) }
            fill(x + w / 2, y + 11, 1, 6, 0xCFC9BA)
            // Mullions and sill.
            for m in 1..<3 {
                let mx = x + w * m / 3 - 1
                fill(mx, y + 11, 2, h - 12, 0x5E6570)
                fill(mx, y + 11, 1, h - 12, 0x98A0AB)
            }
            fill(x - 3, y + h, w + 6, 2, 0xE2DED4)
            fill(x - 3, y + h + 2, w + 6, 1, 0x8C867A)
        }

        /// A plain office door with a narrow glass panel. It stands open while someone walks through.
        private func door(open: Bool) {
            let x = 8
            let y = 38
            let w = 30
            let h = RoomLayout.wall - y
            fill(x, y, w, h, 0x5E6570)
            fill(x + 1, y + 1, w - 2, 1, 0x98A0AB)
            if open {
                fill(x + 2, y + 2, w - 4, h - 2, 0x1B1820)
                fill(x + 2, y + 2, 6, h - 2, 0xA9A397)
                fill(x + 7, y + 2, 1, h - 2, 0x6E685D)
                fill(x + 8, y + h - 3, w - 10, 3, 0x2A2530)
            } else {
                fill(x + 2, y + 2, w - 4, h - 2, 0xCBC5B7)
                fill(x + 2, y + 2, 1, h - 2, 0xE2DDD2)
                fill(x + w - 3, y + 2, 1, h - 2, 0xA59F92)
                fill(x + 7, y + 8, 6, 24, 0x6C7480)
                fill(x + 8, y + 9, 4, 22, 0xA8CFE3)
                fill(x + 8, y + 9, 1, 22, 0xD8EEF8)
                fill(x + w - 8, y + 30, 4, 2, 0x3E434D)
                fill(x + 2, y + h - 4, w - 4, 4, 0xB3AD9F)
            }
        }

        private func whiteboard(_ x: Int, _ y: Int) {
            let w = 56
            let h = 32
            fill(x, y, w, h, 0x8E95A0)
            fill(x + 1, y + 1, w - 2, h - 2, 0xF4F5F2)
            fill(x + 1, y + h - 2, w - 2, 1, 0xD9DBD8)
            // A small chart, a checklist and a note.
            line(Double(x + 5), Double(y + 22), Double(x + 12), Double(y + 15), 0x3D6FD1)
            line(Double(x + 12), Double(y + 15), Double(x + 17), Double(y + 19), 0x3D6FD1)
            line(Double(x + 17), Double(y + 19), Double(x + 25), Double(y + 8), 0x3D6FD1)
            fill(x + 5, y + 25, 21, 1, 0x3A3F47)
            for (row, length) in [(6, 16), (12, 11), (18, 14)] {
                fill(x + 30, y + row, 2, 2, 0xD04A3A)
                fill(x + 34, y + row + 1, length, 1, 0x3A3F47)
            }
            fill(x + 30, y + 24, 20, 1, 0x2E9E62)
            fill(x - 1, y + h, w + 2, 2, 0x6C727C)
            fill(x + 8, y + h - 1, 5, 1, 0xD04A3A)
            fill(x + 15, y + h - 1, 5, 1, 0x3D6FD1)
        }

        /// A wall clock showing this Mac's time.
        private func clock(center: (Int, Int), _ now: Date, _ calendar: Calendar) {
            let (cx, cy) = center
            let rim: [(Int, Int)] = [(-2, -6), (-4, -5), (-5, -4), (-6, -2)]
            fill(cx - 6, cy - 2, 13, 5, 0x3B3F47)
            fill(cx - 2, cy - 6, 5, 13, 0x3B3F47)
            for (dx, dy) in rim {
                let w = -dx * 2 + 1
                fill(cx + dx, cy + dy, w, 1, 0x3B3F47)
                fill(cx + dx, cy - dy, w, 1, 0x3B3F47)
                fill(cx + dy, cy + dx, 1, w, 0x3B3F47)
                fill(cx - dy, cy + dx, 1, w, 0x3B3F47)
            }
            fill(cx - 4, cy - 2, 9, 5, 0xF4F1E8)
            fill(cx - 2, cy - 4, 5, 9, 0xF4F1E8)
            fill(cx - 3, cy - 3, 7, 7, 0xF4F1E8)
            for (dx, dy) in [(0, -4), (4, 0), (0, 4), (-4, 0)] { fill(cx + dx, cy + dy, 1, 1, 0x8E95A0) }
            let parts = calendar.dateComponents([.hour, .minute], from: now)
            let minute = Double(parts.minute ?? 0)
            let hour = Double((parts.hour ?? 0) % 12) + minute / 60
            let m = minute / 60 * 2 * .pi
            let hr = hour / 12 * 2 * .pi
            line(Double(cx), Double(cy), Double(cx) + sin(m) * 4, Double(cy) - cos(m) * 4, 0x3B3F47)
            line(Double(cx), Double(cy), Double(cx) + sin(hr) * 2.6, Double(cy) - cos(hr) * 2.6, 0xC24A3A)
        }

        /// A pixel speech bubble (13 × 10) with a symbol, its tail pointing at the head below.
        private func bubble(_ mark: Mark, _ cx: Int, _ top: Int) {
            let w = 13
            let h = 10
            let x = cx - w / 2
            let y = top - h - 4
            fill(x, y + 1, w, h - 2, 0x2B2233)
            fill(x + 1, y, w - 2, h, 0x2B2233)
            fill(x + 1, y + 1, w - 2, h - 2, mark == .bang ? 0xFFD23F : 0xFFFFFF)
            fill(x + 5, y + h, 3, 1, 0x2B2233)
            fill(x + 6, y + h + 1, 1, 1, 0x2B2233)
            let ink: UInt32 = 0x2B2233
            switch mark {
            case .dots:
                for dx in [3, 6, 9] { fill(x + dx, y + 5, 1, 1, ink) }
            case .bang:
                fill(x + 6, y + 2, 1, 4, ink)
                fill(x + 6, y + 7, 1, 1, ink)
            case .zzz:
                fill(x + 4, y + 2, 5, 1, ink)
                fill(x + 7, y + 3, 1, 1, ink)
                fill(x + 6, y + 4, 1, 1, ink)
                fill(x + 5, y + 5, 1, 1, ink)
                fill(x + 4, y + 6, 5, 1, ink)
            }
        }

        // MARK: night

        /// The room dims, the windows show the city at night, and only seats with someone at them glow.
        private func night(_ scene: OfficeScene, glass: [CGRect]) {
            let d = CGFloat(scene.darkness)
            guard d > 0 else { return }
            // The room dims, but less in the pool under each lit lamp. People and furniture there are lit alike
            // and keep about half their daytime colours, so the lamp shows who sits there.
            let width = scene.layout.width
            let height = self.height
            let pools = self.pools.map { CGPoint(x: $0.x, y: height - $0.y) }
            let key = pools.map { "\(Int($0.x)),\(Int($0.y))" }.joined(separator: " ")
            let shade = art.picture("shade \(width)x\(height) \(Int(d * 100)) \(key)") { [art] in
                OfficeRenderer.picture(width: width, height: height, density: OfficeRenderer.density, art: art) {
                    canvas in
                    canvas.fill(0, 0, width, height, Self.mix(0xFFFFFF, 0x262C58, Double(d)))
                    let lit = Self.mix(0xFFFFFF, 0x262C58, Double(d) * 0.45)
                    guard
                        let gradient = CGGradient(
                            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                            colors: [Self.color(lit), Self.color(lit, 0.8), Self.color(lit, 0)] as CFArray,
                            locations: [0, 0.45, 1])
                    else { return }
                    for pool in pools {
                        canvas.context.drawRadialGradient(
                            gradient, startCenter: pool, startRadius: 0, endCenter: pool, endRadius: 46, options: [])
                    }
                }
            }
            context.setBlendMode(.multiply)
            stamp(shade, 0, 0)
            context.setBlendMode(.normal)

            context.setAlpha(d)
            for (index, pane) in glass.enumerated() {
                let view = art.picture("night \(index)") { [art] in
                    OfficeRenderer.picture(
                        width: Int(pane.width), height: Int(pane.height), density: OfficeRenderer.density, art: art
                    ) {
                        $0.nightView(CGRect(origin: .zero, size: pane.size), seed: index)
                    }
                }
                stamp(view, Int(pane.minX), Int(pane.minY))
            }
            context.setAlpha(1)

            context.setBlendMode(.plusLighter)
            let screenLight = glow(0x7FB2FF, 0.55 * d, radius: 22)
            let pool = glow(0xFFB15C, 0.5 * d, radius: 46)
            let bulb = glow(0xFFE2A8, 0.6 * d, radius: 12)
            for screen in screens { stamp(screenLight, screen.x - 22, screen.y - 22) }
            for center in self.pools { stamp(pool, center.x - 46, center.y - 46) }
            for center in bulbs { stamp(bulb, center.x - 12, center.y - 12) }
            context.setBlendMode(.normal)
            context.setAlpha(d)
            for lamp in litLamps { sprite(Sheet.lamp, lamp.sx, 32, 32, 32, lamp.x, lamp.y, mirrored: lamp.mirrored) }
            context.setAlpha(1)
        }

        /// Dark sky and a few lit windows in the buildings across the street: someone else works late too.
        private func nightView(_ glass: CGRect, seed: Int) {
            let x = Int(glass.minX)
            let y = Int(glass.minY)
            let w = Int(glass.width)
            let h = Int(glass.height)
            for row in 0..<h { fill(x, y + row, w, 1, Self.mix(0x0B1026, 0x1E2850, Double(row) / Double(h))) }
            let heights = [18, 26, 14, 30, 22, 12, 27, 17]
            var bx = x
            var i = seed * 3
            while bx < x + w {
                let bw = min(8 + (i % 3) * 3, x + w - bx)
                let bh = min(heights[i % heights.count], h)
                fill(bx, y + h - bh, bw, bh, 0x080B1A)
                var wy = y + h - bh + 3
                while wy < y + h - 2 {
                    var wx = bx + 2
                    while wx < bx + bw - 1 {
                        if (wx * 7 + wy * 13 + seed * 5) % 11 == 0 { fill(wx, wy, 1, 1, 0xFFD27A) }
                        wx += 2
                    }
                    wy += 3
                }
                bx += bw + 1
                i += 1
            }
            fill(x + w - 9, y + 4, 2, 2, 0xF2E8C9)
            fill(x + 6, y + 6, 1, 1, 0xC9D3EA)
            fill(x + w / 2, y + 3, 1, 1, 0xC9D3EA)
        }

        static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
            func channel(_ shift: UInt32) -> UInt32 {
                let ca = Double(a >> shift & 0xFF)
                let cb = Double(b >> shift & 0xFF)
                return UInt32((ca + (cb - ca) * t).rounded()) << shift
            }
            return channel(16) | channel(8) | channel(0)
        }
    }
}
