import XCTest

@testable import AgentOvertimeCore

/// File names shortened and edits counted inside the helper, from the text alone.
final class DetailTests: XCTestCase {
    let folder = "/Users/me/my-project"

    func testInsideTheFolderAtMostTheLastTwoParts() {
        XCTAssertEqual(Detail.shortPath(folder + "/src/app.ts", in: folder), "src/app.ts")
        XCTAssertEqual(Detail.shortPath(folder + "/notes.md", in: folder), "notes.md")
        XCTAssertEqual(Detail.shortPath(folder + "/src/ui/button.css", in: folder), "…/ui/button.css")
        XCTAssertEqual(Detail.shortPath(folder + "//src///ui/kit/button.css", in: folder + "/"), "…/kit/button.css")
        XCTAssertEqual(Detail.shortPath("/etc/hosts", in: folder), "hosts", "outside: the name alone")
        XCTAssertNil(Detail.shortPath("src/app.ts", in: folder), "not absolute")
        XCTAssertNil(Detail.shortPath("/", in: folder))
    }

    /// The six cases to check: `..` parts, a folder of one part or none, a folder whose name starts another's,
    /// hidden characters and a long name, and the folder itself. None shows the folder's path or a home folder.
    func testNeverTheFullPathOrAnAccountName() {
        let cases: [(path: String, folder: String, shown: String)] = [
            ("/Users/me/p/../../x", "/Users/me/p", "x"),
            ("/Users/me/secret/file.txt", "/", "file.txt"),
            ("/Users/me/secret/file.txt", "/Users", "file.txt"),
            ("/a/proj2/f", "/a/proj", "f"),
            ("/a/proj/sub/../../proj2/f", "/a/proj", "f"),
            (folder, folder, "my-project"),
            (folder + "/ev\u{202E}il\n.txt", folder, "evil.txt"),
        ]
        for (path, base, shown) in cases {
            let result = Detail.shortPath(path, in: base)
            XCTAssertEqual(result, shown, path)
            for leaked in ["/Users", "me/", "secret", "proj/"] { XCTAssertFalse(result?.contains(leaked) ?? false) }
        }
        let long = Detail.shortPath(folder + "/" + String(repeating: "a", count: 300), in: folder)
        XCTAssertEqual(long?.count, Detail.file)
        XCTAssertEqual(long?.hasSuffix("…"), true)
    }

    func testLinesAnEditAddsAndRemoves() {
        XCTAssertTrue(Detail.lineChange(old: "a\nb\nc\n", new: "a\nX\nc\n") == (1, 1), "context lines left out")
        XCTAssertTrue(Detail.lineChange(old: "a\nb\n", new: "a\nb\nc\nd\n") == (2, 0))
        XCTAssertTrue(Detail.lineChange(old: "a\nb\nc", new: "a\nc") == (0, 1))
        XCTAssertTrue(Detail.lineChange(old: "same", new: "same") == (0, 0))
        XCTAssertTrue(Detail.lineChange(old: "", new: "one\ntwo") == (2, 0))
        XCTAssertTrue(Detail.lineChange(old: "x", new: "y") == (1, 1))
        XCTAssertEqual(Detail.lines("a\nb\nc\n"), 3)
        XCTAssertEqual(Detail.lines("a\nb"), 2)
        XCTAssertEqual(Detail.lines(""), 0)
        XCTAssertEqual(Detail.lines(String(repeating: "\n", count: 2_000_000)), Detail.maxLines, "capped")
    }

    /// Near the 8 MiB input limit, counting stays well inside the helper's 0.5 s.
    func testAHugeEditIsCountedQuickly() {
        let half = String(repeating: "let x = 1\n", count: 400_000)  // 4 MB
        let (old, new) = (half + "old\n" + half, half + "new\n" + half)
        let started = Date()
        let change = Detail.lineChange(old: old, new: new)
        XCTAssertTrue(change == (1, 1), "\(change)")
        XCTAssertEqual(Detail.lines(old), 800_001)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    }
}
