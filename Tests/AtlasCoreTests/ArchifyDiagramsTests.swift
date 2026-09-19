import XCTest
@testable import AtlasCore

/// The project-to-diagram join is a name match, which is exactly the kind of
/// rule that quietly starts pointing at the wrong file.
final class ArchifyDiagramsTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("archify-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        for name in ["atlas", "machina", "hermes-sovereign", "mythos-mobile", "atlas.visual-check"] {
            try "<html></html>".write(to: folder.appendingPathComponent(name + ".html"),
                                      atomically: true, encoding: .utf8)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testMatchesOnExactName() {
        XCTAssertEqual(ArchifyDiagrams.diagram(for: "ATLAS", in: folder)?.lastPathComponent, "atlas.html")
        XCTAssertEqual(ArchifyDiagrams.diagram(for: "MACHINA", in: folder)?.lastPathComponent, "machina.html")
    }

    /// The project is called "Hermes"; the diagram is "hermes-sovereign".
    func testMatchesOnPrefixWhenTheDiagramIsMoreSpecific() {
        XCTAssertEqual(ArchifyDiagrams.diagram(for: "Hermes", in: folder)?.lastPathComponent,
                       "hermes-sovereign.html")
    }

    /// A display name with a space has to reach a hyphenated filename.
    func testSpacesBecomeHyphens() {
        XCTAssertEqual(ArchifyDiagrams.diagram(for: "MYTHOS Mobile", in: folder)?.lastPathComponent,
                       "mythos-mobile.html")
    }

    /// The failure that matters: a sibling project must not inherit another's
    /// diagram just because the names share a prefix.
    func testDoesNotClaimASiblingsDiagram() {
        XCTAssertNil(ArchifyDiagrams.diagram(for: "MYTHOS Web", in: folder))
        XCTAssertNil(ArchifyDiagrams.diagram(for: "MYTHOS CODE STRUCTURE", in: folder))
    }

    /// A very short name would prefix-match almost anything.
    func testShortNamesDoNotPrefixMatch() {
        XCTAssertNil(ArchifyDiagrams.diagram(for: "at", in: folder))
        XCTAssertNil(ArchifyDiagrams.diagram(for: "", in: folder))
    }

    func testProjectsWithoutADiagramGetNothing() {
        XCTAssertNil(ArchifyDiagrams.diagram(for: "Crown Pizza & Burgers", in: folder))
    }

    /// archify writes a contact sheet beside each diagram; it is not a diagram.
    func testVisualCheckArtefactsAreNotOffered() {
        let names = ArchifyDiagrams.all(in: folder).map(\.name)
        XCTAssertFalse(names.contains { $0.hasSuffix(".visual-check") })
        XCTAssertEqual(names, ["atlas", "hermes-sovereign", "machina", "mythos-mobile"])
    }

    func testMissingFolderIsNotAnError() {
        let absent = folder.appendingPathComponent("nope", isDirectory: true)
        XCTAssertNil(ArchifyDiagrams.diagram(for: "ATLAS", in: absent))
        XCTAssertTrue(ArchifyDiagrams.all(in: absent).isEmpty)
    }
}
