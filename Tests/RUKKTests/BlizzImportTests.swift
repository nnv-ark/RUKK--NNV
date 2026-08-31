import XCTest
@testable import RUKK

final class BlizzImportTests: XCTestCase {

    /// Dæmigert `_rukk.json` eins og BLIZZ-spegillinn skrifar (ISO-8601 dagsetningar).
    private let sampleJSON = """
    [
      {
        "id": "ev-1",
        "client": "KAA",
        "project": "Holtakot heilsárhús",
        "task": "Hönnun",
        "note": "Forsíðuhönnun",
        "durationMinutes": 150,
        "rate": 18500,
        "billed": false,
        "paid": false,
        "start": "2026-08-28T10:00:00Z"
      },
      {
        "id": "ev-2",
        "client": "KAA",
        "project": "Holtakot heilsárhús",
        "task": "Yfirferð",
        "note": "",
        "durationMinutes": 45,
        "rate": 18500,
        "billed": true,
        "paid": false,
        "start": "2026-08-29T13:30:00Z"
      },
      {
        "id": "ev-3",
        "client": "",
        "project": "Innra verk",
        "task": "",
        "note": "",
        "durationMinutes": 30,
        "rate": 0,
        "billed": false,
        "paid": false,
        "start": "2026-08-27T09:00:00Z"
      }
    ]
    """

    func testParseDecodesAllFields() {
        let entries = BlizzImporter.parse(Data(sampleJSON.utf8))
        XCTAssertEqual(entries.count, 3)

        // Raðað eftir upphafs tíma, elsta fyrst.
        XCTAssertEqual(entries.map(\.id), ["ev-3", "ev-1", "ev-2"])

        let e = entries[1]
        XCTAssertEqual(e.client, "KAA")
        XCTAssertEqual(e.project, "Holtakot heilsárhús")
        XCTAssertEqual(e.durationMinutes, 150)
        XCTAssertEqual(e.rate, Decimal(18500))
        XCTAssertFalse(e.billed)
        XCTAssertNotNil(e.start)
    }

    func testHoursAndLabels() {
        let entries = BlizzImporter.parse(Data(sampleJSON.utf8))
        let e = entries[1]
        XCTAssertEqual(e.hours, Decimal(2.5))
        XCTAssertEqual(e.projectLabel, "KAA — Holtakot heilsárhús")
        XCTAssertEqual(e.lineDescription, "Forsíðuhönnun")
        XCTAssertTrue(e.isUnbilled)
    }

    func testFallbackLabels() {
        let entries = BlizzImporter.parse(Data(sampleJSON.utf8))

        // Tóm athugasemd → verkþáttur.
        XCTAssertEqual(entries[2].lineDescription, "Yfirferð")

        // Enginn viðskiptavinur → projectLabel er bara verkefnið.
        XCTAssertEqual(entries[0].projectLabel, "Innra verk")
        // Tóm athugasemd og verkþáttur → verkefni.
        XCTAssertEqual(entries[0].lineDescription, "Innra verk")
    }

    func testParseGarbageReturnsEmpty() {
        XCTAssertTrue(BlizzImporter.parse(Data("ekki JSON".utf8)).isEmpty)
    }

    func testLoadEntriesWithoutFolderThrows() {
        let oldPath = UserDefaults.standard.string(forKey: BlizzImporter.folderKey)
        defer {
            if let oldPath { UserDefaults.standard.set(oldPath, forKey: BlizzImporter.folderKey) }
        }
        BlizzImporter.clearFolder()
        XCTAssertFalse(BlizzImporter.isConnected)
        XCTAssertThrowsError(try BlizzImporter.loadEntries()) { error in
            XCTAssertEqual(error as? BlizzImporter.ImportError, .fileMissing)
        }
    }

    /// Full lesferlið: tengd mappa → `BLIZZ Data/_rukk.json` → færslur.
    /// (Prófunarerindisbréf keyrir ósandkassaiserað svo hrein slóð dugar.)
    func testLoadEntriesFromConnectedFolder() throws {
        let oldPath = UserDefaults.standard.string(forKey: BlizzImporter.folderKey)
        defer {
            BlizzImporter.clearFolder()
            if let oldPath { UserDefaults.standard.set(oldPath, forKey: BlizzImporter.folderKey) }
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("blizz-mirror-\(UUID().uuidString)")
        let dataDir = root.appendingPathComponent("BLIZZ Data")
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try Data(sampleJSON.utf8).write(to: dataDir.appendingPathComponent("_rukk.json"))
        defer { try? FileManager.default.removeItem(at: root) }

        BlizzImporter.setFolder(root)
        XCTAssertTrue(BlizzImporter.isConnected)

        let entries = try BlizzImporter.loadEntries()
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.map(\.id), ["ev-3", "ev-1", "ev-2"])
    }
}
