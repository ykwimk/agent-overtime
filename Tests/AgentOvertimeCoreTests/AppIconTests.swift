import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// The app icon is drawn here, in code: a night office building with its lights on, on a 16×16 pixel grid.
/// `swift test` writes App/Assets.xcassets/AppIcon.appiconset/*.png (and captures/app-icon.png) from it,
/// so the PNGs in the repo can always be checked against this drawing. No outside image files.
final class AppIconTests: XCTestCase {
    private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// One character per pixel. `.` is the night sky of the tile.
    static let pixels = [
        "................",
        "..mm............",
        "..m.......*.....",
        "..mm..........*.",
        "................",
        "...##########...",
        "...#LL#DD#LL#...",
        "...#LL#DD#LL#...",
        "...##########...",
        "...#LL#LL#DD#...",
        "...#LL#LL#DD#...",
        "...##########...",
        "...#LL#DD#LL#...",
        "...#LL#DD#LL#...",
        "...####dd####...",
        "gggggggggggggggg",
    ]

    static let colors: [Character: UInt32] = [
        "#": 0x4B5A7A,  // wall
        "L": 0xFFD166,  // lit window
        "D": 0x2A3452,  // dark window
        "d": 0xC08A4A,  // door
        "m": 0xF2E8C9,  // moon
        "*": 0xC9D3EA,  // star
        "g": 0x141A30,  // ground
    ]
    static let sky: UInt32 = 0x1E2746

    static func render(size: Int) -> CGImage {
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        func color(_ hex: UInt32) -> CGColor {
            CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        // macOS icon grid: an 824-point rounded tile centred on a 1024-point canvas.
        let scale = CGFloat(size) / 1024
        let tile = CGRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
        let shape = CGPath(roundedRect: tile, cornerWidth: 185 * scale, cornerHeight: 185 * scale, transform: nil)
        context.addPath(shape)
        context.setFillColor(color(sky))
        context.fillPath()

        context.addPath(shape)
        context.clip()
        context.setShouldAntialias(false)
        let cell = tile.width / 16
        for (row, line) in pixels.enumerated() {
            for (column, character) in line.enumerated() {
                guard let hex = colors[character] else { continue }
                context.setFillColor(color(hex))
                // CoreGraphics counts rows from the bottom.
                context.fill(CGRect(x: tile.minX + CGFloat(column) * cell, y: tile.maxY - CGFloat(row + 1) * cell,
                                    width: cell + 0.5, height: cell + 0.5))
            }
        }
        return context.makeImage()!
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    func testDrawAppIcon() throws {
        XCTAssertTrue(Self.pixels.allSatisfy { $0.count == 16 }, "16×16 grid")
        XCTAssertEqual(Self.pixels.count, 16)

        let set = repo.appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset")
        for size in [16, 32, 64, 128, 256, 512, 1024] {
            try writePNG(Self.render(size: size), to: set.appendingPathComponent("icon_\(size).png"))
        }
        let captures = repo.appendingPathComponent("captures")
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        try writePNG(Self.render(size: 1024), to: captures.appendingPathComponent("app-icon.png"))

        // Every file the asset catalog names exists.
        let contents = try JSONSerialization.jsonObject(with: Data(contentsOf: set.appendingPathComponent("Contents.json"))) as? [String: Any]
        let names = (contents?["images"] as? [[String: Any]])?.compactMap { $0["filename"] as? String } ?? []
        XCTAssertEqual(names.count, 10)
        for name in names { XCTAssertTrue(FileManager.default.fileExists(atPath: set.appendingPathComponent(name).path), name) }
    }
}
