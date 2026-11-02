import XCTest

/// Every word the app shows comes in English and Korean: each string in the catalog has its Korean, and the plain
/// strings the app's code shows are all in the catalog.
final class LocalizationTests: XCTestCase {
    private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    func testEveryStringHasKorean() throws {
        let data = try Data(contentsOf: repo.appendingPathComponent("App/Localizable.xcstrings"))
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
        XCTAssertGreaterThan(strings.count, 100)
        for (key, entry) in strings where entry["shouldTranslate"] as? Bool != false {
            let localizations = entry["localizations"] as? [String: Any]
            XCTAssertNotNil(localizations?["ko"], "no Korean for \(key)")
        }

        // Text("…"), Button("…"), Label("…", …) and String(localized: "…") without interpolation.
        let pattern = try NSRegularExpression(
            pattern: #"(?:Text|Button|Label|String\(localized:)\(?\s*"((?:[^"\\]|\\.)*)""#)
        let app = repo.appendingPathComponent("App")
        let files = try FileManager.default.contentsOfDirectory(atPath: app.path).filter { $0.hasSuffix(".swift") }
        var checked = 0
        for file in files {
            let source = try String(contentsOf: app.appendingPathComponent(file), encoding: .utf8)
            for match in pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                guard let range = Range(match.range(at: 1), in: source) else { continue }
                let key = String(source[range])
                guard !key.contains("\\("), !key.isEmpty else { continue }
                XCTAssertNotNil(strings[key], "\(file): \"\(key)\" is not in the catalog")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 50)
    }
}

/// File names, task titles and the model show only in the side panel: no other view of the app reads them, so they
/// never reach the office floor, a tooltip, the menu, a notification or Start Work.
final class DetailPlacementTests: XCTestCase {
    func testOnlyTheSidePanelReadsDetails() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("App")
        var readers: [String] = []
        for file in try FileManager.default.contentsOfDirectory(atPath: app.path) where file.hasSuffix(".swift") {
            let source = try String(contentsOf: app.appendingPathComponent(file), encoding: .utf8)
            if source.contains(".detail(") || source.contains("detail(session") || source.contains("detail(teammate") {
                readers.append(file)
            }
        }
        XCTAssertEqual(readers, ["OfficeView.swift"])
    }
}
